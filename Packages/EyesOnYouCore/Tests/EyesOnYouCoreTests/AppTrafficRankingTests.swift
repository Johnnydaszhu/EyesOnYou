import XCTest
@testable import EyesOnYouCore

final class AppTrafficRankingTests: XCTestCase {
    private let chrome = AppIdentityKey(
        teamIdentifier: "EQHXZ8M8AV",
        signingIdentifier: "com.google.Chrome"
    )
    private let safari = AppIdentityKey(
        teamIdentifier: "APPLE",
        signingIdentifier: "com.apple.Safari"
    )

    func testTrafficLeaderOverridesAnExistingFavoriteFirstOrder() {
        let favorite = AppTrafficSnapshot(
            app: safari,
            displayName: "Safari",
            totals: TrafficTotals(bytesDown: 1_000)
        )
        let leader = AppTrafficSnapshot(
            app: chrome,
            displayName: "Chrome",
            totals: TrafficTotals(bytesDown: 10_000)
        )

        let ordered = AppTrafficRanking.prioritizingLeader(
            [favorite, leader],
            leader: AppTrafficRanking.leader(in: [favorite, leader]),
            app: \.app
        )

        XCTAssertEqual(ordered.map(\.app), [chrome, safari])
    }

    func testTrafficLeaderChangesWithRefreshedTotals() {
        let first = [
            AppTrafficSnapshot(
                app: chrome,
                displayName: "Chrome",
                totals: TrafficTotals(bytesDown: 10_000)
            ),
            AppTrafficSnapshot(
                app: safari,
                displayName: "Safari",
                totals: TrafficTotals(bytesDown: 9_000)
            ),
        ]
        let refreshed = [
            first[0],
            AppTrafficSnapshot(
                app: safari,
                displayName: "Safari",
                totals: TrafficTotals(bytesDown: 11_000)
            ),
        ]

        XCTAssertEqual(AppTrafficRanking.leader(in: first), chrome)
        XCTAssertEqual(AppTrafficRanking.leader(in: refreshed), safari)
    }

    func testTrafficLeaderTieUsesStableAppIdentity() {
        let equalTraffic = TrafficTotals(bytesUp: 500, bytesDown: 500)
        let snapshots = [
            AppTrafficSnapshot(app: safari, displayName: "Safari", totals: equalTraffic),
            AppTrafficSnapshot(app: chrome, displayName: "Chrome", totals: equalTraffic),
        ]
        let expected = [chrome, safari].min { $0.storageKey < $1.storageKey }

        XCTAssertEqual(AppTrafficRanking.leader(in: snapshots), expected)
        XCTAssertNil(
            AppTrafficRanking.leader(
                in: snapshots.map {
                    AppTrafficSnapshot(
                        app: $0.app,
                        displayName: $0.displayName,
                        totals: TrafficTotals()
                    )
                }
            )
        )
    }
}
