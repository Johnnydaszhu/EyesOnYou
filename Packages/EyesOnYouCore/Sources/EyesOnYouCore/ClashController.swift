import Foundation

/// Clash / mihomo external-controller integration.
///
/// Clash-family clients expose a local REST API (`external-controller`, usually
/// 127.0.0.1:9090) whose `/connections` endpoint reports, for every live
/// connection, the owning process and the exit it took (node name or DIRECT).
/// That is *measured* per-app route truth — strictly better than the socket
/// heuristics — so when a controller is reachable EyesOnYou uses it as route
/// evidence. Shadowrocket has no such API; these types simply stay idle then.
public struct ClashControllerEndpoint: Equatable, Sendable {
    public var baseURL: URL
    public var secret: String?

    public init(baseURL: URL, secret: String? = nil) {
        self.baseURL = baseURL
        self.secret = secret
    }
}

// MARK: - Config discovery

public enum ClashConfigParser {
    /// Locations the Clash family actually uses, relative to `$HOME`.
    public static func candidateConfigPaths(home: URL) -> [URL] {
        [
            ".config/mihomo/config.yaml",
            ".config/clash.meta/config.yaml",
            ".config/clash/config.yaml",
            ".config/clash-verge/config.yaml"
        ].map { home.appendingPathComponent($0) }
    }

    /// Extract `external-controller` / `secret` from a Clash YAML without a YAML
    /// dependency: both are top-level scalar lines in every real-world config.
    public static func endpoint(fromYAML yaml: String) -> ClashControllerEndpoint? {
        var controller: String?
        var secret: String?
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            // Top-level keys only — indented lines belong to nested sections.
            guard let first = line.first, first != " ", first != "\t", first != "#" else { continue }
            if let value = scalarValue(line: line, key: "external-controller") {
                controller = value
            } else if let value = scalarValue(line: line, key: "secret") {
                secret = value
            }
        }
        guard var controller, !controller.isEmpty else { return nil }
        // "0.0.0.0:9090" and ":9090" both mean loopback for a local client.
        if controller.hasPrefix(":") { controller = "127.0.0.1\(controller)" }
        controller = controller.replacingOccurrences(of: "0.0.0.0:", with: "127.0.0.1:")
        guard let url = URL(string: "http://\(controller)"), url.port != nil else { return nil }
        return ClashControllerEndpoint(baseURL: url, secret: secret?.isEmpty == true ? nil : secret)
    }

    private static func scalarValue(line: String, key: String) -> String? {
        guard line.hasPrefix("\(key):") else { return nil }
        var value = String(line.dropFirst(key.count + 1))
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        value = value.trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value
    }

    /// First endpoint found across the candidate config files on disk.
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClashControllerEndpoint? {
        for url in candidateConfigPaths(home: home) {
            guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let endpoint = endpoint(fromYAML: yaml) { return endpoint }
        }
        return nil
    }
}

// MARK: - /connections payload

public struct ClashConnectionMetadata: Decodable, Equatable, Sendable {
    public var network: String?
    public var host: String?
    public var destinationIP: String?
    public var destinationPort: String?
    /// mihomo: absolute executable path of the client process (macOS).
    public var processPath: String?
    /// mihomo: executable name only.
    public var process: String?
}

public struct ClashConnection: Decodable, Equatable, Sendable {
    public var id: String
    public var upload: UInt64
    public var download: UInt64
    /// Exit first: `["DIRECT"]`, or `["node", "group", …]` when proxied.
    public var chains: [String]
    public var rule: String?
    public var metadata: ClashConnectionMetadata

    /// The route this connection actually took.
    public enum Route: Equatable, Sendable {
        case direct
        case proxied(node: String)
        case rejected
    }

    public var route: Route {
        switch chains.first {
        case nil, "DIRECT": return .direct
        case "REJECT", "REJECT-DROP": return .rejected
        case .some(let node): return .proxied(node: node)
        }
    }
}

public struct ClashConnectionsSnapshot: Decodable, Equatable, Sendable {
    public var downloadTotal: UInt64?
    public var uploadTotal: UInt64?
    public var connections: [ClashConnection]?
}

// MARK: - Client

public struct ClashControllerClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public var endpoint: ClashControllerEndpoint
    private let transport: Transport

    public init(endpoint: ClashControllerEndpoint, transport: Transport? = nil) {
        self.endpoint = endpoint
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    public func connections() async throws -> ClashConnectionsSnapshot {
        let data = try await get("connections")
        return try JSONDecoder().decode(ClashConnectionsSnapshot.self, from: data)
    }

    /// Cheap reachability probe (also validates the secret).
    public func isReachable() async -> Bool {
        (try? await get("version")) != nil
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(
            url: endpoint.baseURL.appendingPathComponent(path),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 2
        )
        if let secret = endpoint.secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Route evidence rollup

/// Measured per-executable route mix from one `/connections` sample.
public struct ClashRouteEvidence: Equatable, Sendable {
    public struct Counts: Equatable, Sendable {
        public var proxied: Int
        public var direct: Int

        public init(proxied: Int = 0, direct: Int = 0) {
            self.proxied = proxied
            self.direct = direct
        }

        /// Definite route only when the evidence is one-sided; a mixed app stays
        /// undecided rather than being rounded to whichever side is bigger.
        public var definiteRoute: ClashConnection.Route? {
            if proxied > 0, direct == 0 { return .proxied(node: "") }
            if direct > 0, proxied == 0 { return .direct }
            return nil
        }
    }

    public var totalConnections: Int
    public var proxiedConnections: Int
    public var directConnections: Int
    public var rejectedConnections: Int
    /// Keyed by executable path when the controller reports one, else by name.
    public var byProcess: [String: Counts]

    public init(
        totalConnections: Int = 0,
        proxiedConnections: Int = 0,
        directConnections: Int = 0,
        rejectedConnections: Int = 0,
        byProcess: [String: Counts] = [:]
    ) {
        self.totalConnections = totalConnections
        self.proxiedConnections = proxiedConnections
        self.directConnections = directConnections
        self.rejectedConnections = rejectedConnections
        self.byProcess = byProcess
    }

    public static func build(from snapshot: ClashConnectionsSnapshot) -> ClashRouteEvidence {
        var evidence = ClashRouteEvidence()
        for connection in snapshot.connections ?? [] {
            evidence.totalConnections += 1
            let processKey = connection.metadata.processPath.flatMap { $0.isEmpty ? nil : $0 }
                ?? connection.metadata.process.flatMap { $0.isEmpty ? nil : $0 }
            switch connection.route {
            case .proxied:
                evidence.proxiedConnections += 1
                if let processKey {
                    evidence.byProcess[processKey, default: Counts()].proxied += 1
                }
            case .direct:
                evidence.directConnections += 1
                if let processKey {
                    evidence.byProcess[processKey, default: Counts()].direct += 1
                }
            case .rejected:
                evidence.rejectedConnections += 1
            }
        }
        return evidence
    }
}
