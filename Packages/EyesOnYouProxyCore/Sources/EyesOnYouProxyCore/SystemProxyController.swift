import Foundation
import EyesOnYouCore

/// Captured web/secure proxy settings for one network service, so they can be
/// restored exactly — including after a crash.
public struct ServiceProxyState: Codable, Equatable, Sendable {
    public var service: String
    public var webEnabled: Bool
    public var webHost: String
    public var webPort: Int
    public var secureEnabled: Bool
    public var secureHost: String
    public var securePort: Int

    public init(
        service: String,
        webEnabled: Bool, webHost: String, webPort: Int,
        secureEnabled: Bool, secureHost: String, securePort: Int
    ) {
        self.service = service
        self.webEnabled = webEnabled
        self.webHost = webHost
        self.webPort = webPort
        self.secureEnabled = secureEnabled
        self.secureHost = secureHost
        self.securePort = securePort
    }

    /// The proxy this service pointed at before takeover, if any — the upstream the
    /// enforcement proxy should chain to so existing tunneling keeps working.
    public var existingUpstream: ProxyUpstream? {
        // Prefer the HTTPS proxy (covers CONNECT); fall back to the HTTP one.
        if secureEnabled, !secureHost.isEmpty, let port = UInt16(exactly: securePort) {
            return ProxyUpstream(kind: .http, host: secureHost, port: port)
        }
        if webEnabled, !webHost.isEmpty, let port = UInt16(exactly: webPort) {
            return ProxyUpstream(kind: .http, host: webHost, port: port)
        }
        return nil
    }
}

/// A snapshot of every service's proxy settings before EyesOnYou took over.
public struct SystemProxyBackup: Codable, Equatable, Sendable {
    public var savedAt: Date
    public var services: [ServiceProxyState]

    public init(savedAt: Date, services: [ServiceProxyState]) {
        self.savedAt = savedAt
        self.services = services
    }

    /// Best upstream across services (first one that had a proxy configured).
    public var upstream: ProxyUpstream? {
        services.lazy.compactMap { $0.existingUpstream }.first
    }
}

/// Points the macOS system proxy at our local enforcement proxy, remembers what was
/// there before, and puts it all back.
///
/// This is the one component that mutates system network settings, so it is built to
/// be reversible above all else:
/// - the prior state is written to disk *before* any change (crash recovery),
/// - restore is idempotent and safe to run on next launch,
/// - it only ever touches the web + secure web proxy host/port/enabled — never DNS,
///   SOCKS, PAC, or anything it did not set.
///
/// It shells out to `networksetup`, which is the supported per-user interface; the
/// runner is injectable so the parsing and orchestration are testable without
/// touching the machine.
public final class SystemProxyController: @unchecked Sendable {
    public typealias Runner = @Sendable (_ args: [String]) -> (status: Int32, output: String)

    private let run: Runner
    private let backupURL: URL
    private let fileManager: FileManager

    public init(
        backupURL: URL,
        fileManager: FileManager = .default,
        runner: @escaping Runner = SystemProxyController.networksetup
    ) {
        self.backupURL = backupURL
        self.fileManager = fileManager
        self.run = runner
    }

    // MARK: - Public API

    /// Capture current proxy settings, persist them, then route web + secure proxy
    /// through `127.0.0.1:port` on every enabled service.
    ///
    /// - Returns: the backup (whose `upstream` the caller feeds to the proxy rules).
    /// - Throws: if no backup could be written — takeover without a saved restore
    ///   point is refused, so the user can never be left stranded.
    @discardableResult
    public func takeOver(localPort: UInt16) throws -> SystemProxyBackup {
        let services = enabledServices()
        let backup = SystemProxyBackup(
            savedAt: Date(),
            services: services.map { captureState(service: $0) }
        )
        try persist(backup)

        for service in services {
            apply(service: service, host: "127.0.0.1", port: Int(localPort))
        }
        return backup
    }

    /// Restore proxy settings from the on-disk backup, if one exists, then delete it.
    ///
    /// Called on user toggle-off and on launch (to recover from a prior crash while
    /// enforcement was active). A missing backup is a no-op success.
    @discardableResult
    public func restoreIfNeeded() -> Bool {
        guard let backup = loadBackup() else { return false }
        for state in backup.services {
            restore(state)
        }
        try? fileManager.removeItem(at: backupURL)
        return true
    }

    /// True when a backup exists — i.e. enforcement was active and may need recovery.
    public var hasPendingBackup: Bool {
        fileManager.fileExists(atPath: backupURL.path)
    }

    public func loadBackup() -> SystemProxyBackup? {
        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SystemProxyBackup.self, from: data)
    }

    // MARK: - Service enumeration

    /// Enabled services only (a `*` prefix in `-listallnetworkservices` = disabled).
    public func enabledServices() -> [String] {
        let (_, output) = run(["-listallnetworkservices"])
        return Self.parseServices(output)
    }

    static func parseServices(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            // First line is an explanatory header; disabled services start with '*'.
            .filter { !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
    }

    // MARK: - Capture / apply / restore per service

    /// Read one service's current web/secure proxy settings.
    public func captureState(service: String) -> ServiceProxyState {
        let web = Self.parseProxyOutput(run(["-getwebproxy", service]).output)
        let secure = Self.parseProxyOutput(run(["-getsecurewebproxy", service]).output)
        return ServiceProxyState(
            service: service,
            webEnabled: web.enabled, webHost: web.host, webPort: web.port,
            secureEnabled: secure.enabled, secureHost: secure.host, securePort: secure.port
        )
    }

    private func apply(service: String, host: String, port: Int) {
        _ = run(["-setwebproxy", service, host, String(port)])
        _ = run(["-setsecurewebproxy", service, host, String(port)])
        // -setwebproxy enables it, but be explicit so intent survives a partial run.
        _ = run(["-setwebproxystate", service, "on"])
        _ = run(["-setsecurewebproxystate", service, "on"])
    }

    private func restore(_ state: ServiceProxyState) {
        if state.webEnabled, !state.webHost.isEmpty {
            _ = run(["-setwebproxy", state.service, state.webHost, String(state.webPort)])
            _ = run(["-setwebproxystate", state.service, "on"])
        } else {
            _ = run(["-setwebproxystate", state.service, "off"])
        }
        if state.secureEnabled, !state.secureHost.isEmpty {
            _ = run(["-setsecurewebproxy", state.service, state.secureHost, String(state.securePort)])
            _ = run(["-setsecurewebproxystate", state.service, "on"])
        } else {
            _ = run(["-setsecurewebproxystate", state.service, "off"])
        }
    }

    // MARK: - Parsing

    struct ProxyReading: Equatable {
        var enabled: Bool
        var host: String
        var port: Int
    }

    /// Parse the `Enabled:/Server:/Port:` block `-getwebproxy` prints.
    static func parseProxyOutput(_ output: String) -> ProxyReading {
        var enabled = false
        var host = ""
        var port = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": enabled = parts[1].lowercased() == "yes"
            case "Server": host = parts[1]
            case "Port": port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return ProxyReading(enabled: enabled, host: host, port: port)
    }

    // MARK: - IO

    private func persist(_ backup: SystemProxyBackup) throws {
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: backupURL, options: .atomic)
    }

    /// Default runner: invoke `/usr/sbin/networksetup`.
    public static func networksetup(_ args: [String]) -> (status: Int32, output: String) {
        networksetup(
            args,
            executableURL: URL(fileURLWithPath: "/usr/sbin/networksetup"),
            timeout: 5
        )
    }

    static func networksetup(
        _ args: [String],
        executableURL: URL,
        timeout: TimeInterval
    ) -> (status: Int32, output: String) {
        guard let result = BoundedProcess.run(
            executableURL: executableURL,
            arguments: args,
            timeout: timeout,
            mergeStderrIntoStdout: true
        ) else {
            return (-1, "unable to launch \(executableURL.path)")
        }
        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        guard !result.timedOut else {
            return (-1, output.isEmpty ? "networksetup timed out" : output)
        }
        return (result.terminationStatus, output)
    }
}
