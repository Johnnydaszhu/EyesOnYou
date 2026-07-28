import XCTest
@testable import EyesOnYouCore

final class SystemProxyReaderTests: XCTestCase {
    func testInactiveWhenAllFlagsOff() {
        let snap = SystemProxyReader.snapshot(from: [
            "HTTPEnable": 0,
            "HTTPSEnable": 0,
            "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0
        ])
        XCTAssertFalse(snap.isEnabled)
        XCTAssertEqual(snap.configurationState, .disabled)
        XCTAssertNil(snap.primaryEndpointLabel)
    }

    func testSocksPreferredEndpoint() {
        let snap = SystemProxyReader.snapshot(from: [
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 1087,
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": 1080
        ])
        XCTAssertTrue(snap.isEnabled)
        XCTAssertEqual(snap.configurationState, .enabled)
        XCTAssertTrue(snap.socksEnabled)
        XCTAssertEqual(snap.primaryEndpointLabel, "socks5://127.0.0.1:1080")
    }

    func testPACOnly() {
        let snap = SystemProxyReader.snapshot(from: [
            "ProxyAutoConfigEnable": true,
            "ProxyAutoConfigURLString": "http://127.0.0.1:6152/pac"
        ])
        XCTAssertTrue(snap.isEnabled)
        XCTAssertEqual(snap.primaryEndpointLabel, "http://127.0.0.1:6152/pac")
    }

    func testEnabledFlagWithoutEndpointIsInvalid() {
        let snap = SystemProxyReader.snapshot(from: [
            "HTTPEnable": 1
        ])
        XCTAssertFalse(snap.isEnabled)
        XCTAssertEqual(snap.configurationState, .invalid)
        XCTAssertNil(snap.primaryEndpointLabel)
    }

    func testEndpointSchemeMatchesTheUsablePath() {
        let snap = SystemProxyReader.snapshot(from: [
            "SOCKSEnable": 1,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 1082
        ])
        XCTAssertEqual(snap.configurationState, .enabled)
        XCTAssertEqual(snap.primaryEndpointLabel, "https://127.0.0.1:1082")
    }

    func testAutoDiscoveryIsRecognized() {
        let snap = SystemProxyReader.snapshot(from: [
            "ProxyAutoDiscoveryEnable": 1
        ])
        XCTAssertTrue(snap.isEnabled)
        XCTAssertEqual(snap.configurationState, .enabled)
        XCTAssertEqual(snap.primaryEndpointLabel, "WPAD")
    }

    func testUnavailableIsDifferentFromDisabled() {
        XCTAssertFalse(SystemProxySnapshot.unavailable.isEnabled)
        XCTAssertEqual(SystemProxySnapshot.unavailable.configurationState, .unavailable)
        XCTAssertEqual(SystemProxySnapshot.inactive.configurationState, .disabled)
    }
}
