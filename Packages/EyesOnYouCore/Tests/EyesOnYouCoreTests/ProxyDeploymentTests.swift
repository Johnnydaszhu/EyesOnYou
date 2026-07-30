import XCTest
@testable import EyesOnYouCore

final class ProxyDeploymentTests: XCTestCase {
    private func merged(_ settings: [String: Any]) -> SystemProxySnapshot {
        SystemProxyReader.snapshot(from: settings)
    }

    private let shadowrocketMerged: [String: Any] = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 1082,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1082
    ]

    func testVPNProvidedProxyWinsClassification() {
        // Shadowrocket live shape: NE publishes State-layer proxies + fake-IP DNS.
        let snapshot = ProxyDeploymentClassifier.classify(
            merged: merged(shadowrocketMerged),
            setupLayerHasFixedProxy: false,
            serviceLayerHasFixedProxy: true,
            tunnelActive: true,
            fakeIPDNS: true
        )
        XCTAssertEqual(snapshot.mode, .vpnProvidedProxy)
        XCTAssertEqual(snapshot.endpoint, "https://127.0.0.1:1082")
        XCTAssertTrue(snapshot.fakeIPDNS)
    }

    func testSystemProxyModeWhenOnlySetupLayerCarriesIt() {
        // Clash "system proxy" mode (or EyesOnYou's own takeover).
        let snapshot = ProxyDeploymentClassifier.classify(
            merged: merged(shadowrocketMerged),
            setupLayerHasFixedProxy: true,
            serviceLayerHasFixedProxy: false,
            tunnelActive: false,
            fakeIPDNS: false
        )
        XCTAssertEqual(snapshot.mode, .systemProxy)
    }

    func testTunnelOnlyAndNone() {
        let tun = ProxyDeploymentClassifier.classify(
            merged: merged([:]),
            setupLayerHasFixedProxy: false,
            serviceLayerHasFixedProxy: false,
            tunnelActive: true,
            fakeIPDNS: true
        )
        XCTAssertEqual(tun.mode, .tunnelOnly)
        XCTAssertNil(tun.endpoint)

        let idle = ProxyDeploymentClassifier.classify(
            merged: merged([:]),
            setupLayerHasFixedProxy: false,
            serviceLayerHasFixedProxy: false,
            tunnelActive: false,
            fakeIPDNS: false
        )
        XCTAssertEqual(idle.mode, .none)
    }

    func testPACBeatsFixedEndpoints() {
        var settings = shadowrocketMerged
        settings["ProxyAutoConfigEnable"] = 1
        settings["ProxyAutoConfigURLString"] = "http://127.0.0.1:1089/proxy.pac"
        let snapshot = ProxyDeploymentClassifier.classify(
            merged: merged(settings),
            setupLayerHasFixedProxy: true,
            serviceLayerHasFixedProxy: false,
            tunnelActive: false,
            fakeIPDNS: false
        )
        XCTAssertEqual(snapshot.mode, .pac)
        XCTAssertEqual(snapshot.endpoint, "http://127.0.0.1:1089/proxy.pac")
    }

    func testHasFixedProxyReadsDynamicStoreShapes() {
        // Real State-layer dictionary shape (NSNumber flags).
        XCTAssertTrue(ProxyDeploymentClassifier.hasFixedProxy([
            "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "127.0.0.1", "HTTPPort": NSNumber(value: 1082)
        ]))
        XCTAssertTrue(ProxyDeploymentClassifier.hasFixedProxy(["SOCKSEnable": 1]))
        XCTAssertFalse(ProxyDeploymentClassifier.hasFixedProxy([
            "HTTPEnable": NSNumber(value: 0), "FTPPassive": NSNumber(value: 1)
        ]))
        XCTAssertFalse(ProxyDeploymentClassifier.hasFixedProxy([:]))
    }

    func testFakeIPResolverRange() {
        XCTAssertTrue(ProxyDeploymentClassifier.isFakeIPResolver(["198.18.0.2"]))
        XCTAssertTrue(ProxyDeploymentClassifier.isFakeIPResolver(["1.1.1.1", "198.19.255.1"]))
        XCTAssertFalse(ProxyDeploymentClassifier.isFakeIPResolver(["198.20.0.1", "119.29.29.29"]))
        XCTAssertFalse(ProxyDeploymentClassifier.isFakeIPResolver([]))
    }
}
