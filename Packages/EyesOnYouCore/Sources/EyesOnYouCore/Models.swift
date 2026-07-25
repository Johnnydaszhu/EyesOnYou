import Foundation

// MARK: - App Identity

/// Stable long-term app identity: Team ID + signing identifier.
public struct AppIdentityKey: Hashable, Codable, Sendable {
    public let teamIdentifier: String?
    public let signingIdentifier: String

    public init(teamIdentifier: String?, signingIdentifier: String) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }

    /// Canonical storage key used in SQLite and maps.
    public var storageKey: String {
        let team = teamIdentifier ?? ""
        return "\(team)|\(signingIdentifier)"
    }
}

public struct AppBuildIdentity: Hashable, Codable, Sendable {
    public let app: AppIdentityKey
    public let codeDirectoryHash: Data?
    public let bundleVersion: String?

    public init(app: AppIdentityKey, codeDirectoryHash: Data?, bundleVersion: String?) {
        self.app = app
        self.codeDirectoryHash = codeDirectoryHash
        self.bundleVersion = bundleVersion
    }
}

// MARK: - Flow enums

public enum TransportProtocol: UInt8, Codable, Sendable, CaseIterable {
    case any = 0
    case tcp = 1
    case udp = 2
    case other = 255
}

public enum FlowDirection: UInt8, Codable, Sendable {
    case outbound = 1
    case inbound = 2
}

public enum FirewallAction: UInt8, Codable, Sendable, CaseIterable {
    case inherit = 0
    case observe = 1
    case allow = 2
    case block = 3
}

/// Route decision dimension (independent of firewall allow/block).
public enum RouteAction: Hashable, Codable, Sendable {
    case inherit
    case direct
    case systemProxy
    case proxy(profileID: UUID)

    /// `.inherit` is the default state: no EyesOnYou rule, so macOS decides — which
    /// is "follow system", not "bypass the proxy".
    public var displayName: String {
        switch self {
        case .inherit: return "Follow System"
        case .direct: return "Direct"
        case .systemProxy: return "System"
        case .proxy: return "Proxy"
        }
    }

    /// UI-facing short label matching mockup chips.
    public var chipLabel: String {
        switch self {
        case .inherit: return "Follow"
        case .direct: return "Direct"
        case .systemProxy: return "System"
        case .proxy: return "SOCKS5"
        }
    }
}

public enum RouteKind: UInt8, Codable, Sendable, CaseIterable {
    case direct = 0
    case systemProxy = 1
    case customProxy = 2
    case blocked = 3
    case unknown = 255

    public init(action: RouteAction) {
        switch action {
        case .inherit, .direct: self = .direct
        case .systemProxy: self = .systemProxy
        case .proxy: self = .customProxy
        }
    }
}

// MARK: - Flow descriptor (pure value type — no NE objects)

public struct FlowDescriptor: Hashable, Sendable {
    public let id: UUID
    public let app: AppIdentityKey
    public let direction: FlowDirection
    public let transport: TransportProtocol
    public let remoteHostname: String?
    public let remoteAddress: String?
    public let remotePort: UInt16?
    public let openedAt: Date

    public init(
        id: UUID = UUID(),
        app: AppIdentityKey,
        direction: FlowDirection = .outbound,
        transport: TransportProtocol = .tcp,
        remoteHostname: String? = nil,
        remoteAddress: String? = nil,
        remotePort: UInt16? = nil,
        openedAt: Date = Date()
    ) {
        self.id = id
        self.app = app
        self.direction = direction
        self.transport = transport
        self.remoteHostname = remoteHostname
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.openedAt = openedAt
    }
}

public struct FirewallDecision: Sendable, Equatable {
    public let action: FirewallAction
    public let matchedRuleID: UUID?

    public init(action: FirewallAction, matchedRuleID: UUID?) {
        self.action = action
        self.matchedRuleID = matchedRuleID
    }
}

public struct RouteDecision: Sendable, Equatable {
    public let action: RouteAction
    public let matchedRuleID: UUID?

    public init(action: RouteAction, matchedRuleID: UUID?) {
        self.action = action
        self.matchedRuleID = matchedRuleID
    }
}

// MARK: - Telemetry value types

public struct TrafficTotals: Sendable, Equatable {
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var flowsOpened: UInt64
    public var flowsClosed: UInt64
    public var flowsBlocked: UInt64

    public init(
        bytesUp: UInt64 = 0,
        bytesDown: UInt64 = 0,
        flowsOpened: UInt64 = 0,
        flowsClosed: UInt64 = 0,
        flowsBlocked: UInt64 = 0
    ) {
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.flowsOpened = flowsOpened
        self.flowsClosed = flowsClosed
        self.flowsBlocked = flowsBlocked
    }

    public var totalBytes: UInt64 { bytesUp &+ bytesDown }

    public mutating func merge(_ other: TrafficTotals) {
        bytesUp &+= other.bytesUp
        bytesDown &+= other.bytesDown
        flowsOpened &+= other.flowsOpened
        flowsClosed &+= other.flowsClosed
        flowsBlocked &+= other.flowsBlocked
    }

    public static func + (lhs: TrafficTotals, rhs: TrafficTotals) -> TrafficTotals {
        var result = lhs
        result.merge(rhs)
        return result
    }
}

public struct AppTrafficSnapshot: Sendable, Identifiable, Equatable {
    public var id: String { app.storageKey }
    public let app: AppIdentityKey
    public let displayName: String
    public let totals: TrafficTotals
    public let rateUpBps: Double
    public let rateDownBps: Double
    public let activeConnections: Int
    public let route: RouteAction
    public let firewallStatus: FirewallAction
    /// True for browser-like apps that should expand into per-site rows.
    public let isBrowser: Bool
    /// Per-site (hostname) breakdown; populated for browsers (and any app when requested).
    public let sites: [SiteTrafficSnapshot]

    public init(
        app: AppIdentityKey,
        displayName: String,
        totals: TrafficTotals,
        rateUpBps: Double = 0,
        rateDownBps: Double = 0,
        activeConnections: Int = 0,
        route: RouteAction = .direct,
        firewallStatus: FirewallAction = .allow,
        isBrowser: Bool = false,
        sites: [SiteTrafficSnapshot] = []
    ) {
        self.app = app
        self.displayName = displayName
        self.totals = totals
        self.rateUpBps = rateUpBps
        self.rateDownBps = rateDownBps
        self.activeConnections = activeConnections
        self.route = route
        self.firewallStatus = firewallStatus
        self.isBrowser = isBrowser
        self.sites = sites
    }
}

/// What a drill-down child row represents under an app.
public enum DrillSegmentKind: String, Sendable, Codable, Equatable {
    /// Browser website / hostname (no full URL path without MITM).
    case website
    /// IDE / editor workspace project.
    case project
    /// ChatGPT / Claude conversation or named workspace.
    case session
    /// Generic destination bucket.
    case destination
}

/// One breakdown slice of an app's traffic (site / project / session).
/// EyesOnYou does not MITM TLS; websites are hostnames, projects/sessions are labeled destinations.
public struct SiteTrafficSnapshot: Sendable, Identifiable, Equatable {
    public var id: String { destinationKey }
    public let destinationKey: String
    /// Display title (hostname, project name, or session title).
    public let hostname: String
    public let totals: TrafficTotals
    public let activeConnections: Int
    public let kind: DrillSegmentKind

    public init(
        destinationKey: String,
        hostname: String,
        totals: TrafficTotals,
        activeConnections: Int = 0,
        kind: DrillSegmentKind = .destination
    ) {
        self.destinationKey = destinationKey
        self.hostname = hostname
        self.totals = totals
        self.activeConnections = activeConnections
        self.kind = kind
    }
}

/// Known browser / browser-helper signing IDs (expandable site breakdown).
public enum BrowserIdentity {
    private static let browserSigningIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Canary",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser", // Arc
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.apple.WebKit.Networking", // WebKit networking process attributed traffic
    ]

    public static func isBrowser(_ app: AppIdentityKey) -> Bool {
        let canonical = ProcessAppIdentity.canonicalSigningID(app.signingIdentifier)
        if browserSigningIDs.contains(canonical) || browserSigningIDs.contains(app.signingIdentifier) {
            return true
        }
        let id = canonical.lowercased()
        return id.contains("chrome") || id.contains("firefox") || id.contains("safari")
            || id.contains("edgemac") || id.contains("brave") || id.hasSuffix(".browser")
    }
}

/// Apps that support nested drill-down (websites, projects, chat sessions).
public enum DrillableIdentity {
    public static func segmentKind(for app: AppIdentityKey) -> DrillSegmentKind {
        let id = app.signingIdentifier.lowercased()
        if BrowserIdentity.isBrowser(app) { return .website }
        // IDE / agent apps: drill children are local workspace folders (see WorkspaceDiscovery).
        if id.contains("vscode")
            || (id.contains("code") && id.contains("microsoft"))
            || id == "com.microsoft.vscode"
            || id.contains("cursor")
            || id.contains("todesktop")
            || id.contains("xcode")
            || id.contains("codex")
            || id.contains("openai")
            || id.contains("chatgpt")
            || id.contains("claude")
            || id.contains("anthropic") {
            return .project
        }
        if id.contains("copilot") {
            return .session
        }
        return .destination
    }

    public static func isDrillable(_ app: AppIdentityKey) -> Bool {
        BrowserIdentity.isBrowser(app)
            || segmentKind(for: app) == .project
            || segmentKind(for: app) == .session
    }

    /// Human-facing label for child rows under an app.
    public static func childLabelKey(for app: AppIdentityKey) -> String {
        switch segmentKind(for: app) {
        case .website: return "drill.websites"
        case .project: return "drill.projects"
        case .session: return "drill.sessions"
        case .destination: return "drill.destinations"
        }
    }
}

/// Normalize a remote host into a stable destination key for bucketing.
public enum DestinationKey {
    public static let unknown = "unknown"

    /// Aggregate path segments for traffic that went through a local proxy client.
    ///
    /// A client socket ends at the proxy, so the real site is invisible without
    /// payload capture — but the proxy's egress tells us *how* the bytes left:
    /// via the proxy node (翻墙) or straight out under a DIRECT rule (e.g. bilibili).
    /// These keys make that split visible instead of lumping everything as unknown.
    public static let viaProxyNode = "path:proxy"
    public static let directByRule = "path:direct"

    /// Foreground window title (`window:AppModel.swift — EyesOnYou`), for apps whose
    /// only machine-readable "what am I working on" signal is the window itself.
    public static let windowPrefix = "window:"

    private static let labeledPrefixes = [
        "project:", "session:", "chat:", "workspace:", "path:", "window:"
    ]

    public static func make(hostname: String?, address: String?) -> String {
        if let hostname, !hostname.isEmpty {
            if let labeled = makeLabeled(hostname) {
                return labeled
            }
            var h = hostname.lowercased()
            if h.hasSuffix(".") { h.removeLast() }
            return h
        }
        if let address, !address.isEmpty {
            return address.lowercased()
        }
        return unknown
    }

    public static func make(from flow: FlowDescriptor) -> String {
        make(hostname: flow.remoteHostname, address: flow.remoteAddress)
    }

    /// `project:<Name>` / `session:<Title>` — keep title casing, normalize prefix.
    public static func makeLabeled(prefix: String, title: String) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPrefix = trimmedPrefix.hasSuffix(":") ? trimmedPrefix : "\(trimmedPrefix):"
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedPrefix + trimmedTitle
    }

    private static func makeLabeled(_ raw: String) -> String? {
        let lower = raw.lowercased()
        for prefix in labeledPrefixes where lower.hasPrefix(prefix) {
            let title = String(raw.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return prefix + "unknown" }
            // Keep project/session title casing for UI; macOS paths are effectively unique ignoring case.
            return prefix + title
        }
        return nil
    }
}

public struct LiveConnection: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let app: AppIdentityKey
    public let displayName: String
    public let host: String
    public let protocolLabel: String
    public let route: RouteAction
    public let firewall: FirewallAction
    public let timestamp: Date
    public let bytesUp: UInt64
    public let bytesDown: UInt64

    public init(
        id: UUID = UUID(),
        app: AppIdentityKey,
        displayName: String,
        host: String,
        protocolLabel: String = "HTTPS",
        route: RouteAction = .direct,
        firewall: FirewallAction = .allow,
        timestamp: Date = Date(),
        bytesUp: UInt64 = 0,
        bytesDown: UInt64 = 0
    ) {
        self.id = id
        self.app = app
        self.displayName = displayName
        self.host = host
        self.protocolLabel = protocolLabel
        self.route = route
        self.firewall = firewall
        self.timestamp = timestamp
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
    }
}

public struct RouteMix: Sendable, Equatable {
    public var directPercent: Double
    public var systemProxyPercent: Double
    public var customProxyPercent: Double
    public var blockedCount: UInt64
    public var activeRules: Int

    public init(
        directPercent: Double = 0,
        systemProxyPercent: Double = 0,
        customProxyPercent: Double = 0,
        blockedCount: UInt64 = 0,
        activeRules: Int = 0
    ) {
        self.directPercent = directPercent
        self.systemProxyPercent = systemProxyPercent
        self.customProxyPercent = customProxyPercent
        self.blockedCount = blockedCount
        self.activeRules = activeRules
    }
}

// MARK: - Byte / rate formatting helpers

public enum ByteFormat {
    public static func string(for bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) \(units[unitIndex])"
        }
        if value >= 100 {
            return String(format: "%.0f %@", value, units[unitIndex])
        }
        if value >= 10 {
            return String(format: "%.1f %@", value, units[unitIndex])
        }
        return String(format: "%.2f %@", value, units[unitIndex])
    }

    /// Formats a transfer rate from bytes/sec as **MB/s** (mebibytes, 1024²).
    /// Falls back to KB/s or B/s when the rate is small so the UI stays readable.
    public static func rateMBps(bytesPerSecond: Double) -> String {
        let absRate = max(0, bytesPerSecond)
        if absRate >= 1024 * 1024 {
            let mb = absRate / (1024 * 1024)
            if mb >= 100 {
                return String(format: "%.0f MB/s", mb)
            }
            if mb >= 10 {
                return String(format: "%.1f MB/s", mb)
            }
            return String(format: "%.2f MB/s", mb)
        }
        if absRate >= 1024 {
            let kb = absRate / 1024
            if kb >= 100 {
                return String(format: "%.0f KB/s", kb)
            }
            return String(format: "%.1f KB/s", kb)
        }
        return String(format: "%.0f B/s", absRate)
    }

    /// - Important: Prefer ``rateMBps(bytesPerSecond:)``. Kept as a thin alias for older call sites.
    public static func rateMbps(bytesPerSecond: Double) -> String {
        rateMBps(bytesPerSecond: bytesPerSecond)
    }
}
