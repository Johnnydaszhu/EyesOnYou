import Foundation

/// One process with active TCP sockets (from `lsof` / injected text).
public struct SocketProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var command: String
    /// Client → local system-proxy port.
    public var viaProxyConnections: Int
    /// Direct sockets that never enter the local proxy port.
    public var directConnections: Int
    /// Distinct remote hosts (capped), for site hints.
    public var remoteHosts: [String]
    public var isProxyProcess: Bool

    public init(
        pid: Int32,
        command: String,
        viaProxyConnections: Int = 0,
        directConnections: Int = 0,
        remoteHosts: [String] = [],
        isProxyProcess: Bool = false
    ) {
        self.pid = pid
        self.command = command
        self.viaProxyConnections = viaProxyConnections
        self.directConnections = directConnections
        self.remoteHosts = remoteHosts
        self.isProxyProcess = isProxyProcess
    }

    public var weightedConnections: Int {
        viaProxyConnections + directConnections
    }
}

/// Aggregated socket sample used for host-side app / route fallback.
public struct ActiveSocketSnapshot: Equatable, Sendable {
    public var processes: [SocketProcessSample]
    /// Local-proxy process egress matching DIRECT rules (e.g. bilibili).
    public var proxyDirectEgress: Int
    /// Local-proxy process egress that did not match DIRECT rules (proxy-node / 翻墙).
    public var proxyRemoteEgress: Int
    /// Dominant non-DIRECT remote IP of the local proxy process (node / uplink).
    public var primaryProxyNodeIP: String?
    /// Distinct DIRECT proxy-egress destinations (resolved hostname preferred over IP).
    public var proxyDirectHosts: [String]
    /// Distinct non-DIRECT proxy-egress destinations (excludes the primary node IP).
    public var proxyRemoteHosts: [String]
    /// Effective local proxy listen ports used for attribution.
    public var proxyPorts: [Int]
    /// True when a local proxy client process was identified.
    public var hasLocalProxyClient: Bool

    public init(
        processes: [SocketProcessSample] = [],
        proxyDirectEgress: Int = 0,
        proxyRemoteEgress: Int = 0,
        primaryProxyNodeIP: String? = nil,
        proxyDirectHosts: [String] = [],
        proxyRemoteHosts: [String] = [],
        proxyPorts: [Int] = [],
        hasLocalProxyClient: Bool = false
    ) {
        self.processes = processes
        self.proxyDirectEgress = proxyDirectEgress
        self.proxyRemoteEgress = proxyRemoteEgress
        self.primaryProxyNodeIP = primaryProxyNodeIP
        self.proxyDirectHosts = proxyDirectHosts
        self.proxyRemoteHosts = proxyRemoteHosts
        self.proxyPorts = proxyPorts
        self.hasLocalProxyClient = hasLocalProxyClient
    }
}

/// Samples processes that currently hold ESTABLISHED TCP sockets.
public enum ActiveAppSocketSampler {
    /// Common Clash / Surge / Shadowrocket listen ports — assist discovery only; never assert product name.
    public static let commonLocalProxyPorts: Set<Int> = [
        7890, 7891, 7892, 7893, 1080, 1082, 1086, 1087, 6152, 6153, 8888, 8080, 2080, 9090
    ]

    public struct ConnectionLine: Equatable, Sendable {
        public var command: String
        public var pid: Int32
        public var localHost: String
        public var localPort: Int
        public var remoteHost: String
        public var remotePort: Int
    }

    /// Run `/usr/sbin/lsof` for ESTABLISHED TCP and attribute weights.
    public static func sampleTCPEstablished(
        proxyPort: Int? = nil,
        directIndex: DirectDestinationIndex = .empty,
        resolvedHosts: [String: String] = [:]
    ) -> ActiveSocketSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:ESTABLISHED"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ActiveSocketSnapshot()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || !data.isEmpty else {
            return ActiveSocketSnapshot()
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return summarize(
            parse(lsofOutput: text),
            proxyPort: proxyPort,
            directIndex: directIndex,
            resolvedHosts: resolvedHosts
        )
    }

    public static func parse(lsofOutput: String) -> [ConnectionLine] {
        var lines: [ConnectionLine] = []
        for raw in lsofOutput.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("COMMAND") { continue }
            guard let parsed = parseLine(line) else { continue }
            lines.append(parsed)
        }
        return lines
    }

    /// Resolve local proxy listen ports from an explicit hint plus loopback dial/listen pairs.
    ///
    /// Both sides of an ESTABLISHED loopback socket have a `localPort`. Only treat a port as the
    /// proxy listen port when clients dial it (`remotePort`) or it is a well-known listen port on
    /// the accept side — never promote ephemeral client localPorts into `proxyPorts`.
    public static func resolveProxyPorts(
        _ connections: [ConnectionLine],
        hintPort: Int? = nil
    ) -> Set<Int> {
        var ports = Set<Int>()
        if let hintPort, hintPort > 0 {
            ports.insert(hintPort)
        }

        var dialed: [Int: Int] = [:]
        var localLoopback: [Int: Int] = [:]
        for conn in connections where isLoopback(conn.remoteHost) {
            dialed[conn.remotePort, default: 0] += 1
            localLoopback[conn.localPort, default: 0] += 1
        }

        // Clients dialing a well-known / hinted port → that port is the proxy entry.
        for (port, hits) in dialed where hits > 0 {
            if ports.contains(port) || commonLocalProxyPorts.contains(port) {
                ports.insert(port)
            }
        }
        // Accept-only on a well-known port (TUN / enhanced mode, few HTTP clients).
        for (port, hits) in localLoopback where hits > 0 {
            if commonLocalProxyPorts.contains(port) {
                ports.insert(port)
            }
        }
        return ports
    }

    public static func summarize(
        _ connections: [ConnectionLine],
        proxyPort: Int?,
        directIndex: DirectDestinationIndex = .empty,
        resolvedHosts: [String: String] = [:]
    ) -> ActiveSocketSnapshot {
        let proxyPorts = resolveProxyPorts(connections, hintPort: proxyPort)
        let proxyPIDs: Set<Int32> = {
            guard !proxyPorts.isEmpty else { return [] }
            return Set(connections.filter { proxyPorts.contains($0.localPort) }.map(\.pid))
        }()

        struct Acc {
            var command: String
            var viaProxy: Int
            var direct: Int
            var hosts: [String]
            var isProxy: Bool
        }
        var byPID: [Int32: Acc] = [:]
        var proxyDirectEgress = 0
        var proxyRemoteEgress = 0
        var remoteEgressCounts: [String: Int] = [:]
        var proxyDirectHosts: [String] = []
        var proxyRemoteHosts: [String] = []

        for conn in connections {
            let isLoopbackRemote = isLoopback(conn.remoteHost)

            // Proxy accept side: localPort in proxyPorts — skip (client counted instead).
            if proxyPorts.contains(conn.localPort) {
                // Still mark the accepting PID as a proxy process even if it has no egress yet.
                var acc = byPID[conn.pid] ?? Acc(
                    command: conn.command,
                    viaProxy: 0,
                    direct: 0,
                    hosts: [],
                    isProxy: true
                )
                acc.command = conn.command
                acc.isProxy = true
                byPID[conn.pid] = acc
                continue
            }

            // Proxy process egress: classify via DIRECT index.
            if proxyPIDs.contains(conn.pid), !isLoopbackRemote {
                let resolved = resolvedHosts[conn.remoteHost] ?? conn.remoteHost
                let displayHost = preferredDestinationLabel(
                    ipOrHost: conn.remoteHost,
                    resolved: resolvedHosts[conn.remoteHost]
                )
                if directIndex.matches(hostOrIP: conn.remoteHost)
                    || directIndex.matches(hostOrIP: resolved) {
                    proxyDirectEgress += 1
                    appendHost(displayHost, into: &proxyDirectHosts)
                } else {
                    proxyRemoteEgress += 1
                    remoteEgressCounts[conn.remoteHost, default: 0] += 1
                    appendHost(displayHost, into: &proxyRemoteHosts)
                }
                var acc = byPID[conn.pid] ?? Acc(
                    command: conn.command,
                    viaProxy: 0,
                    direct: 0,
                    hosts: [],
                    isProxy: true
                )
                acc.command = conn.command
                acc.isProxy = true
                appendHost(displayHost, into: &acc.hosts)
                byPID[conn.pid] = acc
                continue
            }

            // A socket to a fake-IP placeholder (198.18/15) terminates at the local
            // proxy's TUN interface — the address only exists because the proxy's DNS
            // handed it out. That is per-app proof the app entered the proxy, even
            // when it never dialed the loopback port.
            let isFakeIPViaProxy = !isLoopbackRemote
                && RemoteDestination.isProxyPlaceholderAddress(conn.remoteHost)
            let isClientToProxy =
                (isLoopbackRemote && proxyPorts.contains(conn.remotePort)) || isFakeIPViaProxy
            let isDirectInternet = !isLoopbackRemote && !isFakeIPViaProxy

            guard isClientToProxy || isDirectInternet else { continue }

            var acc = byPID[conn.pid] ?? Acc(
                command: conn.command,
                viaProxy: 0,
                direct: 0,
                hosts: [],
                isProxy: false
            )
            acc.command = conn.command
            if isClientToProxy {
                acc.viaProxy += 1
            } else {
                acc.direct += 1
                // Prefer a resolved hostname; a bare peer IP is a poor destination
                // label, and a proxy placeholder address is no label at all.
                if let label = RemoteDestination.label(
                    host: conn.remoteHost,
                    resolved: resolvedHosts[conn.remoteHost]
                ) {
                    appendHost(label, into: &acc.hosts)
                }
            }
            byPID[conn.pid] = acc
        }

        let processes = byPID.map { pid, acc in
            SocketProcessSample(
                pid: pid,
                command: acc.command,
                viaProxyConnections: acc.viaProxy,
                directConnections: acc.direct,
                remoteHosts: acc.hosts,
                isProxyProcess: acc.isProxy
            )
        }
        .filter { $0.weightedConnections > 0 || $0.isProxyProcess }
        .sorted { lhs, rhs in
            if lhs.weightedConnections != rhs.weightedConnections {
                return lhs.weightedConnections > rhs.weightedConnections
            }
            return lhs.pid < rhs.pid
        }

        let primaryNode = dominantRemoteIP(remoteEgressCounts)
        // Primary proxy-node IP is an uplink, not a website the user browsed.
        let remoteSites = proxyRemoteHosts.filter { host in
            guard let primaryNode else { return true }
            return host != primaryNode && host != (resolvedHosts[primaryNode] ?? primaryNode)
        }

        let hasClient = !proxyPIDs.isEmpty
            || proxyDirectEgress + proxyRemoteEgress > 0
            // Fake-IP TUN mode: clients hold via-proxy sockets even when no loopback
            // listener was identified.
            || processes.contains(where: { $0.viaProxyConnections > 0 })
        return ActiveSocketSnapshot(
            processes: processes,
            proxyDirectEgress: proxyDirectEgress,
            proxyRemoteEgress: proxyRemoteEgress,
            primaryProxyNodeIP: primaryNode,
            proxyDirectHosts: proxyDirectHosts,
            proxyRemoteHosts: remoteSites,
            proxyPorts: proxyPorts.sorted(),
            hasLocalProxyClient: hasClient
        )
    }

    /// Most frequent remote IP; ties break lexicographically for stability.
    private static func dominantRemoteIP(_ counts: [String: Int]) -> String? {
        guard !counts.isEmpty else { return nil }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key
    }

    // MARK: - Parsing

    private static func preferredDestinationLabel(ipOrHost: String, resolved: String?) -> String {
        RemoteDestination.label(host: ipOrHost, resolved: resolved)
            ?? DestinationKey.unknown
    }

    private static func appendHost(_ host: String, into hosts: inout [String]) {
        guard !host.isEmpty, !isLoopback(host), !hosts.contains(host), hosts.count < 8 else { return }
        hosts.append(host)
    }

    private static func parseLine(_ line: String) -> ConnectionLine? {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 9 else { return nil }
        guard let pid = Int32(parts[1]) else { return nil }
        let command = parts[0]
        let name = parts[8...]
            .joined(separator: " ")
            .replacingOccurrences(of: " (ESTABLISHED)", with: "")
            .replacingOccurrences(of: "(ESTABLISHED)", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let arrow = name.range(of: "->") else { return nil }
        let localPart = String(name[..<arrow.lowerBound])
        let remotePart = String(name[arrow.upperBound...])
        guard
            let local = splitHostPort(localPart),
            let remote = splitHostPort(remotePart)
        else { return nil }

        return ConnectionLine(
            command: command,
            pid: pid,
            localHost: local.host,
            localPort: local.port,
            remoteHost: remote.host,
            remotePort: remote.port
        )
    }

    private static func splitHostPort(_ value: String) -> (host: String, port: Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        guard let port = Int(trimmed[trimmed.index(after: colon)...]) else { return nil }
        return (host, port)
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}
