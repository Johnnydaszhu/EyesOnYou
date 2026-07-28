import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// Whether macOS exposed a usable system-proxy configuration.
public enum SystemProxyConfigurationState: String, Equatable, Sendable {
    /// The settings API could not be read on this process / platform.
    case unavailable
    /// No HTTP, HTTPS, SOCKS, PAC, or auto-discovery path is enabled.
    case disabled
    /// At least one enabled path has enough information to be used.
    case enabled
    /// A path is switched on but its host, port, or PAC URL is missing.
    case invalid
}

/// Snapshot of macOS system HTTP / HTTPS / SOCKS / PAC proxy settings
/// (what Shadowrocket / Surge / Clash set when “系统代理” is on).
public struct SystemProxySnapshot: Equatable, Sendable {
    /// False only when the OS settings API itself could not be read.
    public var sourceAvailable: Bool
    public var httpEnabled: Bool
    public var httpsEnabled: Bool
    public var socksEnabled: Bool
    public var autoConfigEnabled: Bool
    public var autoDiscoveryEnabled: Bool

    public var httpHost: String?
    public var httpPort: Int?
    public var httpsHost: String?
    public var httpsPort: Int?
    public var socksHost: String?
    public var socksPort: Int?
    public var autoConfigURL: String?

    public init(
        sourceAvailable: Bool = true,
        httpEnabled: Bool = false,
        httpsEnabled: Bool = false,
        socksEnabled: Bool = false,
        autoConfigEnabled: Bool = false,
        autoDiscoveryEnabled: Bool = false,
        httpHost: String? = nil,
        httpPort: Int? = nil,
        httpsHost: String? = nil,
        httpsPort: Int? = nil,
        socksHost: String? = nil,
        socksPort: Int? = nil,
        autoConfigURL: String? = nil
    ) {
        self.sourceAvailable = sourceAvailable
        self.httpEnabled = httpEnabled
        self.httpsEnabled = httpsEnabled
        self.socksEnabled = socksEnabled
        self.autoConfigEnabled = autoConfigEnabled
        self.autoDiscoveryEnabled = autoDiscoveryEnabled
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.autoConfigURL = autoConfigURL
    }

    public static let inactive = SystemProxySnapshot()
    public static let unavailable = SystemProxySnapshot(sourceAvailable: false)

    /// Readable, validated proxy state for UI and routing decisions.
    public var configurationState: SystemProxyConfigurationState {
        guard sourceAvailable else { return .unavailable }
        guard hasEnabledPath else { return .disabled }
        return hasUsablePath ? .enabled : .invalid
    }

    /// True only when at least one enabled path is usable.
    public var isEnabled: Bool {
        configurationState == .enabled
    }

    /// Short endpoint label for UI (SOCKS preferred, then HTTPS, then HTTP, then PAC).
    public var primaryEndpointLabel: String? {
        if socksEnabled, let hostPort = hostPort(host: socksHost, port: socksPort) {
            return "socks5://\(hostPort)"
        }
        if httpsEnabled, let hostPort = hostPort(host: httpsHost, port: httpsPort) {
            return "https://\(hostPort)"
        }
        if httpEnabled, let hostPort = hostPort(host: httpHost, port: httpPort) {
            return "http://\(hostPort)"
        }
        if autoConfigEnabled, let url = autoConfigURL, !url.isEmpty {
            return url
        }
        if autoDiscoveryEnabled {
            return "WPAD"
        }
        return nil
    }

    /// Host:port only (no scheme) — preferred for the proxy-routing card footer.
    public var primaryHostPort: String? {
        if socksEnabled, let value = hostPort(host: socksHost, port: socksPort) {
            return value
        }
        if httpsEnabled, let value = hostPort(host: httpsHost, port: httpsPort) {
            return value
        }
        if httpEnabled, let value = hostPort(host: httpHost, port: httpPort) {
            return value
        }
        return nil
    }

    private var hasEnabledPath: Bool {
        httpEnabled || httpsEnabled || socksEnabled || autoConfigEnabled || autoDiscoveryEnabled
    }

    private var hasUsablePath: Bool {
        (httpEnabled && hostPort(host: httpHost, port: httpPort) != nil)
            || (httpsEnabled && hostPort(host: httpsHost, port: httpsPort) != nil)
            || (socksEnabled && hostPort(host: socksHost, port: socksPort) != nil)
            || (autoConfigEnabled && autoConfigURL != nil)
            || autoDiscoveryEnabled
    }

    private func hostPort(host: String?, port: Int?) -> String? {
        guard let host, !host.isEmpty, let port, (1...65_535).contains(port) else {
            return nil
        }
        return "\(host):\(port)"
    }
}

/// Reads macOS system proxy configuration (not EyesOnYou’s own selective proxy).
public enum SystemProxyReader {
    /// Live settings from the OS (Shadowrocket / system prefs / etc.).
    public static func current() -> SystemProxySnapshot {
        #if canImport(CFNetwork)
        guard let unmanaged = CFNetworkCopySystemProxySettings() else {
            return .unavailable
        }
        let cf = unmanaged.takeRetainedValue()
        guard let settings = cf as? [String: Any] else {
            return .unavailable
        }
        return snapshot(from: settings)
        #else
        return .unavailable
        #endif
    }

    /// Pure parser for tests / injected dictionaries.
    public static func snapshot(from settings: [String: Any]) -> SystemProxySnapshot {
        let httpEnabled = boolValue(settings["HTTPEnable"])
        let httpsEnabled = boolValue(settings["HTTPSEnable"])
        let socksEnabled = boolValue(settings["SOCKSEnable"])
        let pacEnabled = boolValue(settings["ProxyAutoConfigEnable"])
        let autoDiscoveryEnabled = boolValue(settings["ProxyAutoDiscoveryEnable"])

        return SystemProxySnapshot(
            httpEnabled: httpEnabled,
            httpsEnabled: httpsEnabled,
            socksEnabled: socksEnabled,
            autoConfigEnabled: pacEnabled,
            autoDiscoveryEnabled: autoDiscoveryEnabled,
            httpHost: stringValue(settings["HTTPProxy"]),
            httpPort: intValue(settings["HTTPPort"]),
            httpsHost: stringValue(settings["HTTPSProxy"]),
            httpsPort: intValue(settings["HTTPSPort"]),
            socksHost: stringValue(settings["SOCKSProxy"]),
            socksPort: intValue(settings["SOCKSPort"]),
            autoConfigURL: stringValue(settings["ProxyAutoConfigURLString"])
        )
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let i = raw as? Int { return i != 0 }
        return false
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String, let i = Int(s) { return i }
        return nil
    }

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}
