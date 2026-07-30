import Foundation
import EyesOnYouCore

/// What the merged proxy configuration (`scutil --proxy` — the dictionary apps
/// actually resolve against) says about our takeover.
///
/// `networksetup` writes only one layer of that configuration. A NetworkExtension
/// VPN (Shadowrocket, Surge, …) can publish its own proxy settings on the primary
/// service, and those win in the merge — so a takeover can succeed at the
/// `networksetup` layer and still be invisible to every app.
public enum SystemProxyTakeoverVerification: Equatable, Sendable {
    /// Apps resolve HTTP and HTTPS to our local proxy.
    case active
    /// Another configuration layer overrides ours; `observed` is the endpoint
    /// apps are actually using (nil when it could not be described).
    case shadowed(observed: String?)
    /// The merged config shows no enabled proxy at all — the takeover never landed.
    case notApplied
}

extension SystemProxyController {
    /// Compare the merged proxy config against the local enforcement proxy.
    /// Pure — callers pass `SystemProxyReader.current()` (or a fixture in tests).
    public static func verifyTakeover(
        localPort: UInt16,
        merged: SystemProxySnapshot
    ) -> SystemProxyTakeoverVerification {
        guard merged.sourceAvailable else { return .notApplied }
        let httpMatches = merged.httpEnabled
            && merged.httpHost == "127.0.0.1"
            && merged.httpPort == Int(localPort)
        let httpsMatches = merged.httpsEnabled
            && merged.httpsHost == "127.0.0.1"
            && merged.httpsPort == Int(localPort)
        if httpMatches && httpsMatches {
            return .active
        }
        // Any other enabled path means apps are being pointed somewhere else.
        if merged.configurationState == .enabled || merged.configurationState == .invalid {
            return .shadowed(observed: merged.primaryEndpointLabel)
        }
        return .notApplied
    }
}

extension SystemProxySnapshot {
    /// Fixed upstream usable by the local enforcement proxy. PAC and WPAD are
    /// intentionally omitted: forwarding to them requires evaluating a URL-specific
    /// script, so an explicit force-proxy rule must report unavailable instead.
    public var fixedUpstream: ProxyUpstream? {
        guard configurationState == .enabled else { return nil }
        if socksEnabled,
           let host = socksHost,
           let port = socksPort.flatMap(UInt16.init(exactly:)) {
            return ProxyUpstream(kind: .socks5, host: host, port: port)
        }
        if httpsEnabled,
           let host = httpsHost,
           let port = httpsPort.flatMap(UInt16.init(exactly:)) {
            return ProxyUpstream(kind: .http, host: host, port: port)
        }
        if httpEnabled,
           let host = httpHost,
           let port = httpPort.flatMap(UInt16.init(exactly:)) {
            return ProxyUpstream(kind: .http, host: host, port: port)
        }
        return nil
    }
}
