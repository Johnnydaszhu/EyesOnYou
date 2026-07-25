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
}
