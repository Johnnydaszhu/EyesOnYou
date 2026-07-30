import XCTest
import EyesOnYouCore
@testable import EyesOnYouProxyCore

/// Shadowing detection and merged-config upstream fallback — the NetworkExtension
/// VPN scenario where `networksetup` says takeover succeeded but the merged proxy
/// config (what apps actually read) still points at the VPN's proxy.
final class SystemProxyShadowingTests: XCTestCase {

    // MARK: - verifyTakeover

    private func merged(_ settings: [String: Any]) -> SystemProxySnapshot {
        SystemProxyReader.snapshot(from: settings)
    }

    func testActiveWhenMergedConfigPointsAtLocalProxy() {
        let snapshot = merged([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9099,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 9099
        ])
        XCTAssertEqual(
            SystemProxyController.verifyTakeover(localPort: 9099, merged: snapshot),
            .active
        )
    }

    func testShadowedWhenVPNProxyWinsInMergedConfig() {
        // Live repro: takeover wrote 127.0.0.1:9099 at the networksetup layer, but
        // Shadowrocket's NE-provided settings ride on the primary service and win.
        let snapshot = merged([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 1082,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1082
        ])
        XCTAssertEqual(
            SystemProxyController.verifyTakeover(localPort: 9099, merged: snapshot),
            .shadowed(observed: "https://127.0.0.1:1082")
        )
    }

    func testShadowedOnPartialMatch() {
        // HTTPS (which carries CONNECT, i.e. most traffic) still points elsewhere.
        let snapshot = merged([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9099,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1082
        ])
        XCTAssertEqual(
            SystemProxyController.verifyTakeover(localPort: 9099, merged: snapshot),
            .shadowed(observed: "https://127.0.0.1:1082")
        )
    }

    func testActiveEvenWhenAForeignSOCKSPathRemainsEnabled() {
        // CFNetwork prefers the HTTP/HTTPS proxies for web traffic, so a leftover
        // SOCKS entry does not shadow HTTP(S) enforcement.
        let snapshot = merged([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9099,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 9099,
            "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1086
        ])
        XCTAssertEqual(
            SystemProxyController.verifyTakeover(localPort: 9099, merged: snapshot),
            .active
        )
    }

    func testShadowedByPACConfiguration() {
        let snapshot = merged([
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://127.0.0.1:1089/proxy.pac"
        ])
        XCTAssertEqual(
            SystemProxyController.verifyTakeover(localPort: 9099, merged: snapshot),
            .shadowed(observed: "http://127.0.0.1:1089/proxy.pac")
        )
    }

    func testNotAppliedWhenMergedConfigHasNoProxy() {
        XCTAssertEqual(
            SystemProxyController.verifyTakeover(localPort: 9099, merged: merged([:])),
            .notApplied
        )
    }

    func testNotAppliedWhenMergedConfigUnreadable() {
        XCTAssertEqual(
            SystemProxyController.verifyTakeover(localPort: 9099, merged: .unavailable),
            .notApplied
        )
    }

    // MARK: - fixedUpstream (merged-config fallback for inherit-flows)

    func testFixedUpstreamPrefersSOCKSThenHTTPSThenHTTP() {
        let all = merged([
            "HTTPEnable": 1, "HTTPProxy": "h", "HTTPPort": 1,
            "HTTPSEnable": 1, "HTTPSProxy": "s", "HTTPSPort": 2,
            "SOCKSEnable": 1, "SOCKSProxy": "k", "SOCKSPort": 3
        ])
        XCTAssertEqual(all.fixedUpstream, ProxyUpstream(kind: .socks5, host: "k", port: 3))

        let webOnly = merged([
            "HTTPEnable": 1, "HTTPProxy": "h", "HTTPPort": 1,
            "HTTPSEnable": 1, "HTTPSProxy": "s", "HTTPSPort": 2
        ])
        XCTAssertEqual(webOnly.fixedUpstream, ProxyUpstream(kind: .http, host: "s", port: 2))

        let httpOnly = merged(["HTTPEnable": 1, "HTTPProxy": "h", "HTTPPort": 1])
        XCTAssertEqual(httpOnly.fixedUpstream, ProxyUpstream(kind: .http, host: "h", port: 1))
    }

    func testFixedUpstreamIsNilForPACOnlyAndDisabledConfigs() {
        let pacOnly = merged([
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://example/proxy.pac"
        ])
        XCTAssertNil(pacOnly.fixedUpstream, "PAC needs per-URL evaluation — no fixed upstream")
        XCTAssertNil(merged([:]).fixedUpstream)
        XCTAssertNil(SystemProxySnapshot.unavailable.fixedUpstream)
    }

    func testMergedFallbackSuppliesUpstreamWhenNetworksetupLayerIsEmpty() {
        // The NE-VPN scenario end to end: networksetup shows no proxy (so the
        // takeover backup carries no upstream), while the merged config apps read
        // holds the VPN's endpoint. The resolution `backup.upstream ?? merged
        // fallback` must chain inherit-flows to the VPN.
        let backup = SystemProxyBackup(savedAt: Date(), services: [
            ServiceProxyState(
                service: "Wi-Fi",
                webEnabled: false, webHost: "", webPort: 0,
                secureEnabled: false, secureHost: "", securePort: 0
            )
        ])
        XCTAssertNil(backup.upstream)

        let mergedBeforeTakeover = merged([
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 1082,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1082
        ])
        let resolved = backup.upstream ?? mergedBeforeTakeover.fixedUpstream
        XCTAssertEqual(resolved, ProxyUpstream(kind: .http, host: "127.0.0.1", port: 1082))
    }
}
