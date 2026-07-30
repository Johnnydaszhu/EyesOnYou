import XCTest
@testable import EyesOnYouCore

final class RouteMixBuilderTests: XCTestCase {
    func testNoBytesAndInheritedRouteDoesNotInventProxyTraffic() {
        let mix = RouteMixBuilder.make(
            routes: RouteDirectionalTotals(),
            selectedRoute: .inherit,
            blockedFallback: 0,
            activeRules: 3
        )

        XCTAssertEqual(mix.directPercent, 0)
        XCTAssertEqual(mix.systemProxyPercent, 0)
        XCTAssertEqual(mix.customProxyPercent, 0)
        XCTAssertEqual(mix.unknownPercent, 0)
        XCTAssertEqual(mix.activeRules, 3)
    }

    func testMeasuredBytesDetermineMixIncludingUnknown() {
        let mix = RouteMixBuilder.make(
            routes: RouteDirectionalTotals(
                direct: TrafficTotals(bytesDown: 40),
                systemProxy: TrafficTotals(bytesDown: 30),
                customProxy: TrafficTotals(bytesDown: 20),
                unknown: TrafficTotals(bytesDown: 10, flowsBlocked: 2)
            ),
            selectedRoute: .systemProxy,
            blockedFallback: 9,
            activeRules: 4
        )

        XCTAssertEqual(mix.directPercent, 40)
        XCTAssertEqual(mix.systemProxyPercent, 30)
        XCTAssertEqual(mix.customProxyPercent, 20)
        XCTAssertEqual(mix.unknownPercent, 10)
        XCTAssertEqual(mix.blockedCount, 2)
    }

    func testExplicitSelectedRouteCanBeShownWithoutBytes() {
        let direct = RouteMixBuilder.make(
            routes: RouteDirectionalTotals(),
            selectedRoute: .direct,
            blockedFallback: 0,
            activeRules: 0
        )
        let system = RouteMixBuilder.make(
            routes: RouteDirectionalTotals(),
            selectedRoute: .systemProxy,
            blockedFallback: 0,
            activeRules: 0
        )

        XCTAssertEqual(direct.directPercent, 100)
        XCTAssertEqual(system.systemProxyPercent, 100)
    }
}
