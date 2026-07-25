import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// Snapshot of macOS system HTTP / HTTPS / SOCKS / PAC proxy settings
/// (what Shadowrocket / Surge / Clash set when “系统代理” is on).
public struct SystemProxySnapshot: Equatable, Sendable {
    public var httpEnabled: Bool
    public var httpsEnabled: Bool
    public var socksEnabled: Bool
    public var autoConfigEnabled: Bool

    public var httpHost: String?
    public var httpPort: Int?
    public var httpsHost: String?
    public var httpsPort: Int?
    public var socksHost: String?
    public var socksPort: Int?
    public var autoConfigURL: String?

    public init(
        httpEnabled: Bool = false,
        httpsEnabled: Bool = false,
        socksEnabled: Bool = false,
        autoConfigEnabled: Bool = false,
        httpHost: String? = nil,
        httpPort: Int? = nil,
        httpsHost: String? = nil,
        httpsPort: Int? = nil,
        socksHost: String? = nil,
        socksPort: Int? = nil,
        autoConfigURL: String? = nil
    ) {
        self.httpEnabled = httpEnabled
        self.httpsEnabled = httpsEnabled
        self.socksEnabled = socksEnabled
        self.autoConfigEnabled = autoConfigEnabled
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
        self.socksHost = socksHost
        self.socksPort = socksPort
        self.autoConfigURL = autoConfigURL
    }

    public static let inactive = SystemProxySnapshot()

    /// True when any system-level proxy path is active.
    public var isEnabled: Bool {
        httpEnabled || httpsEnabled || socksEnabled || autoConfigEnabled
    }

    /// Short endpoint label for UI (SOCKS preferred, then HTTPS, then HTTP, then PAC).
    public var primaryEndpointLabel: String? {
        if let hostPort = primaryHostPort {
            if socksEnabled { return "socks5://\(hostPort)" }
            if httpsEnabled { return "https://\(hostPort)" }
            if httpEnabled { return "http://\(hostPort)" }
        }
        if autoConfigEnabled, let url = autoConfigURL, !url.isEmpty {
            return url
        }
        return nil
    }

    /// Host:port only (no scheme) — preferred for the proxy-routing card footer.
    public var primaryHostPort: String? {
        if socksEnabled, let host = socksHost, let port = socksPort {
            return "\(host):\(port)"
        }
        if httpsEnabled, let host = httpsHost, let port = httpsPort {
            return "\(host):\(port)"
        }
        if httpEnabled, let host = httpHost, let port = httpPort {
            return "\(host):\(port)"
        }
        return nil
    }
}

/// Reads macOS system proxy configuration (not EyesOnYou’s own selective proxy).
public enum SystemProxyReader {
    /// Live settings from the OS (Shadowrocket / system prefs / etc.).
    public static func current() -> SystemProxySnapshot {
        #if canImport(CFNetwork)
        guard let unmanaged = CFNetworkCopySystemProxySettings() else {
            return .inactive
        }
        let cf = unmanaged.takeRetainedValue()
        guard let settings = cf as? [String: Any] else {
            return .inactive
        }
        return snapshot(from: settings)
        #else
        return .inactive
        #endif
    }

    /// Pure parser for tests / injected dictionaries.
    public static func snapshot(from settings: [String: Any]) -> SystemProxySnapshot {
        let httpEnabled = boolValue(settings["HTTPEnable"])
        let httpsEnabled = boolValue(settings["HTTPSEnable"])
        let socksEnabled = boolValue(settings["SOCKSEnable"])
        let pacEnabled = boolValue(settings["ProxyAutoConfigEnable"])

        return SystemProxySnapshot(
            httpEnabled: httpEnabled,
            httpsEnabled: httpsEnabled,
            socksEnabled: socksEnabled,
            autoConfigEnabled: pacEnabled,
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
