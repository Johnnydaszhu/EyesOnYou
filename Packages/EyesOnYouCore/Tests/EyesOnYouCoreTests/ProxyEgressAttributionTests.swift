import XCTest
@testable import EyesOnYouCore

final class ProxyEgressAttributionTests: XCTestCase {
    func testMultipleAppsAndMixedRoutesRequireUnknownPerApp() {
        XCTAssertTrue(
            ProxyEgressAttribution.requiresUnknownPerApp(
                clientCount: 3,
                directEgress: 4,
                proxyEgress: 30,
                unknownEgress: 2
            )
        )
    }

    func testSingleAppCanOwnMixedEgress() {
        XCTAssertFalse(
            ProxyEgressAttribution.requiresUnknownPerApp(
                clientCount: 1,
                directEgress: 4,
                proxyEgress: 30,
                unknownEgress: 2
            )
        )
    }

    func testMultipleAppsWithOneConfirmedRouteRemainAttributable() {
        XCTAssertFalse(
            ProxyEgressAttribution.requiresUnknownPerApp(
                clientCount: 4,
                directEgress: 0,
                proxyEgress: 30,
                unknownEgress: 0
            )
        )
    }
}
