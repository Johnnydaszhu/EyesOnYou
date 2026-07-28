import Foundation
import EyesOnYouCore
import EyesOnYouRuleEngine

/// Where a proxied flow should be sent.
public struct ProxyUpstream: Equatable, Codable, Sendable {
    public enum Kind: String, Equatable, Codable, Sendable {
        case http
        case socks5
    }

    public var kind: Kind
    public var host: String
    public var port: UInt16

    public init(kind: Kind, host: String, port: UInt16) {
        self.kind = kind
        self.host = host
        self.port = port
    }
}

/// Why an explicit force-proxy rule cannot be fulfilled.
///
/// An explicit route must never silently become direct traffic. The local proxy
/// returns a failure for these actions so callers can surface the broken setup.
public enum ProxyUnavailableReason: Equatable, Sendable {
    case systemProxyMissing
    case profileMissing(UUID)
}

/// Decision for one inbound proxy connection.
public enum ProxyFlowAction: Equatable, Sendable {
    case block
    case direct
    case upstream(ProxyUpstream)
    case unavailable(ProxyUnavailableReason)
}

/// Immutable rule snapshot the proxy server consults per connection.
///
/// Built on the main actor whenever policy changes, then read from the server's
/// queue — so the hot path never touches `@Published` state or locks in the store.
public struct LocalProxyRules: Sendable {
    public let snapshot: RuleSnapshot
    /// The proxy that owned the system-proxy slot before EyesOnYou took it over
    /// (e.g. Shadowrocket). `nil` when there was none.
    public let systemUpstream: ProxyUpstream?
    /// Per-profile upstreams for `.proxy(profileID)` routes.
    public let profileUpstreams: [UUID: ProxyUpstream]

    public init(
        snapshot: RuleSnapshot,
        systemUpstream: ProxyUpstream?,
        profileUpstreams: [UUID: ProxyUpstream]
    ) {
        self.snapshot = snapshot
        self.systemUpstream = systemUpstream
        self.profileUpstreams = profileUpstreams
    }

    public init(
        snapshot: RuleSnapshot,
        systemUpstream: ProxyUpstream?,
        profiles: [ProxyProfile]
    ) {
        self.snapshot = snapshot
        self.systemUpstream = systemUpstream
        var map: [UUID: ProxyUpstream] = [:]
        for profile in profiles where profile.enabled {
            map[profile.id] = ProxyUpstream(
                kind: profile.kind == .socks5 ? .socks5 : .http,
                host: profile.host,
                port: profile.port
            )
        }
        self.profileUpstreams = map
    }

    /// Resolve what to do with a flow from `app` to `host:port`.
    ///
    /// Route semantics with EyesOnYou holding the system-proxy slot:
    /// - `.direct`      → dial the origin ourselves (true bypass)
    /// - `.systemProxy` → the proxy that *was* the system proxy (upstream)
    /// - `.proxy(id)`   → that exact profile
    /// - `.inherit`     → what the system would have done before we took the slot:
    ///                    upstream when one existed, else direct. Fail-open.
    ///
    /// Missing upstreams fail closed for explicit force-proxy routes. Otherwise the
    /// UI could promise "Force Proxy" while the traffic silently escaped directly.
    public func action(for app: AppIdentityKey, host: String, port: UInt16) -> ProxyFlowAction {
        let flow = FlowDescriptor(app: app, remoteHostname: host, remotePort: port)
        if snapshot.evaluateFirewall(flow).action == .block {
            return .block
        }
        switch snapshot.evaluateRoute(flow).action {
        case .direct:
            return .direct
        case .systemProxy:
            return systemUpstream.map { .upstream($0) } ?? .unavailable(.systemProxyMissing)
        case .inherit:
            return systemUpstream.map { .upstream($0) } ?? .direct
        case .proxy(let profileID):
            if let upstream = profileUpstreams[profileID] {
                return .upstream(upstream)
            }
            return .unavailable(.profileMissing(profileID))
        }
    }
}

/// Thread-safe holder the server reads and the app updates on policy changes.
public final class LocalProxyRulesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: LocalProxyRules

    public init(_ rules: LocalProxyRules) {
        self.rules = rules
    }

    public var current: LocalProxyRules {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    public func update(_ newRules: LocalProxyRules) {
        lock.lock()
        rules = newRules
        lock.unlock()
    }
}
