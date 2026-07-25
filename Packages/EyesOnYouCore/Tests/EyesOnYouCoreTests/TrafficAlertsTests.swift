import XCTest
@testable import EyesOnYouCore

final class TrafficAlertEngineTests: XCTestCase {
    private let chrome = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.google.Chrome")
    private let slack = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.slack")
    private let gb = TrafficAlertThresholds.gigabyte
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(
        total: UInt64 = 0,
        daily: [AppIdentityKey: UInt64] = [:],
        cumulative: [AppIdentityKey: UInt64] = [:],
        burst: [AppIdentityKey: UInt64] = [:],
        at: Date? = nil
    ) -> TrafficAlertInput {
        TrafficAlertInput(
            now: at ?? now,
            dailyTotalBytes: total,
            dailyByApp: daily,
            cumulativeByApp: cumulative,
            burstByApp: burst,
            displayNames: [chrome: "Google Chrome", slack: "Slack"]
        )
    }

    func testDailyTotalFiresOnceThenStaysQuiet() {
        let engine = TrafficAlertEngine()
        let thresholds = TrafficAlertThresholds(dailyTotalBytes: 10 * gb, dailyAppBytes: 0,
                                                cumulativeAppBytes: 0, burstBytes: 0)

        XCTAssertTrue(engine.evaluate(input(total: 9 * gb), thresholds: thresholds).isEmpty)

        let fired = engine.evaluate(input(total: 11 * gb), thresholds: thresholds)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.kind, .dailyTotal)
        XCTAssertEqual(fired.first?.bytes, 11 * gb)

        // Evaluated every second in production — it must not keep notifying.
        XCTAssertTrue(engine.evaluate(input(total: 20 * gb), thresholds: thresholds).isEmpty)
    }

    func testDailyBudgetReArmsTheNextDay() {
        let engine = TrafficAlertEngine()
        let thresholds = TrafficAlertThresholds(dailyTotalBytes: 10 * gb, dailyAppBytes: 0,
                                                cumulativeAppBytes: 0, burstBytes: 0)
        XCTAssertEqual(engine.evaluate(input(total: 11 * gb), thresholds: thresholds).count, 1)

        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertEqual(
            engine.evaluate(input(total: 11 * gb, at: tomorrow), thresholds: thresholds).count, 1,
            "a new day is a new budget"
        )
    }

    func testPerAppDailyIdentifiesTheApp() {
        let engine = TrafficAlertEngine()
        let thresholds = TrafficAlertThresholds(dailyTotalBytes: 0, dailyAppBytes: 10 * gb,
                                                cumulativeAppBytes: 0, burstBytes: 0)
        let fired = engine.evaluate(
            input(daily: [chrome: 12 * gb, slack: 1 * gb]),
            thresholds: thresholds
        )
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.app, chrome)
        XCTAssertEqual(fired.first?.displayName, "Google Chrome")
    }

    func testCumulativeReArmsAtEachMultiple() {
        let engine = TrafficAlertEngine()
        let thresholds = TrafficAlertThresholds(dailyTotalBytes: 0, dailyAppBytes: 0,
                                                cumulativeAppBytes: 10 * gb, burstBytes: 0)

        let first = engine.evaluate(input(cumulative: [chrome: 10 * gb]), thresholds: thresholds)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.threshold, 10 * gb)

        // Same multiple: silent.
        XCTAssertTrue(engine.evaluate(input(cumulative: [chrome: 15 * gb]), thresholds: thresholds).isEmpty)

        // Next multiple: fires again with the higher threshold.
        let second = engine.evaluate(input(cumulative: [chrome: 21 * gb]), thresholds: thresholds)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.threshold, 20 * gb)
    }

    func testBurstFiresOncePerWindow() {
        let engine = TrafficAlertEngine()
        let thresholds = TrafficAlertThresholds(dailyTotalBytes: 0, dailyAppBytes: 0,
                                                cumulativeAppBytes: 0,
                                                burstBytes: 512 * TrafficAlertThresholds.megabyte,
                                                burstWindow: 300)
        let big: UInt64 = 600 * TrafficAlertThresholds.megabyte
        XCTAssertEqual(engine.evaluate(input(burst: [chrome: big]), thresholds: thresholds).count, 1)
        XCTAssertTrue(engine.evaluate(input(burst: [chrome: big]), thresholds: thresholds).isEmpty)

        // A later window can fire again.
        let later = now.addingTimeInterval(600)
        XCTAssertEqual(
            engine.evaluate(input(burst: [chrome: big], at: later), thresholds: thresholds).count, 1
        )
    }

    func testZeroThresholdDisablesTheCheck() {
        let engine = TrafficAlertEngine()
        let off = TrafficAlertThresholds(dailyTotalBytes: 0, dailyAppBytes: 0,
                                         cumulativeAppBytes: 0, burstBytes: 0)
        XCTAssertTrue(engine.evaluate(
            input(total: 999 * gb, daily: [chrome: 999 * gb], cumulative: [chrome: 999 * gb],
                  burst: [chrome: 999 * gb]),
            thresholds: off
        ).isEmpty)
    }

    func testNewAppFiresOnlyWhenEnabledAndOnlyOnce() {
        let engine = TrafficAlertEngine()
        var thresholds = TrafficAlertThresholds(dailyTotalBytes: 0, dailyAppBytes: 0,
                                                cumulativeAppBytes: 0, burstBytes: 0)
        thresholds.notifyOnNewApp = true

        let fired = engine.evaluate(input(daily: [chrome: 1]), thresholds: thresholds)
        XCTAssertEqual(fired.map(\.kind), [.newApp])
        XCTAssertTrue(engine.evaluate(input(daily: [chrome: 2]), thresholds: thresholds).isEmpty)
    }

    func testAppsSeenWhileDisabledAreNotAnnouncedLater() {
        // Turning the check on should not replay every app already running.
        let engine = TrafficAlertEngine()
        var thresholds = TrafficAlertThresholds(dailyTotalBytes: 0, dailyAppBytes: 0,
                                                cumulativeAppBytes: 0, burstBytes: 0)
        _ = engine.evaluate(input(daily: [chrome: 1]), thresholds: thresholds)

        thresholds.notifyOnNewApp = true
        XCTAssertTrue(engine.evaluate(input(daily: [chrome: 2]), thresholds: thresholds).isEmpty)
        // A genuinely new app still fires.
        XCTAssertEqual(
            engine.evaluate(input(daily: [chrome: 2, slack: 1]), thresholds: thresholds).map(\.app),
            [slack]
        )
    }

    func testSeedingKnownAppsSuppressesFirstSeenNoise() {
        let engine = TrafficAlertEngine()
        engine.seedKnownApps([chrome])
        var thresholds = TrafficAlertThresholds(dailyTotalBytes: 0, dailyAppBytes: 0,
                                                cumulativeAppBytes: 0, burstBytes: 0)
        thresholds.notifyOnNewApp = true
        XCTAssertTrue(engine.evaluate(input(daily: [chrome: 5]), thresholds: thresholds).isEmpty)
    }

    func testStateSurvivesARestart() {
        let engine = TrafficAlertEngine()
        let thresholds = TrafficAlertThresholds(dailyTotalBytes: 10 * gb, dailyAppBytes: 0,
                                                cumulativeAppBytes: 0, burstBytes: 0)
        XCTAssertEqual(engine.evaluate(input(total: 11 * gb), thresholds: thresholds).count, 1)

        // Rehydrate a fresh engine from the persisted state — must stay quiet.
        let restarted = TrafficAlertEngine(state: engine.currentState)
        XCTAssertTrue(restarted.evaluate(input(total: 12 * gb), thresholds: thresholds).isEmpty)
    }

    func testPruneKeepsPermanentKeysAndDropsStaleDays() {
        let engine = TrafficAlertEngine()
        var thresholds = TrafficAlertThresholds(dailyTotalBytes: 10 * gb, dailyAppBytes: 0,
                                                cumulativeAppBytes: 10 * gb, burstBytes: 0)
        thresholds.notifyOnNewApp = true
        _ = engine.evaluate(input(total: 11 * gb, daily: [chrome: 1], cumulative: [chrome: 11 * gb]),
                            thresholds: thresholds)
        XCTAssertEqual(engine.currentState.firedKeys.count, 3)

        // A week later the daily key is unreachable; the others must survive.
        engine.pruneState(now: now.addingTimeInterval(7 * 86_400))
        let keys = engine.currentState.firedKeys
        XCTAssertTrue(keys.contains { $0.hasPrefix("cumulativeApp|") })
        XCTAssertTrue(keys.contains { $0.hasPrefix("newApp|") })
        XCTAssertFalse(keys.contains { $0.hasPrefix("dailyTotal|") })
    }
}
