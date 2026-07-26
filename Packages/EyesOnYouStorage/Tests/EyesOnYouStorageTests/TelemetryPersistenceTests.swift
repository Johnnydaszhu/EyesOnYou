import XCTest
@testable import EyesOnYouStorage
import EyesOnYouCore

final class TelemetryFlusherTests: XCTestCase {
    private var directory: URL!
    private var store: TelemetryStore!

    private let app = AppIdentityKey(teamIdentifier: "TEAM", signingIdentifier: "com.example.Agent")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eyesonyou-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try TelemetryStore(path: directory.appendingPathComponent("telemetry.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeAggregator(up: UInt64, down: UInt64, at: Date) -> TelemetryAggregator {
        let aggregator = TelemetryAggregator()
        let flow = FlowDescriptor(app: app, remoteHostname: "project:EyesOnYou", openedAt: at)
        aggregator.recordOpen(flow, displayName: "Agent", route: .direct)
        aggregator.recordDelta(flowID: flow.id, app: app, up: up, down: down, at: at, route: .direct)
        return aggregator
    }

    private func storedTotals(around date: Date) throws -> TrafficTotals {
        try store.queryTotals(
            app: nil,
            granularity: .oneMinute,
            from: date.addingTimeInterval(-3_600),
            to: date.addingTimeInterval(3_600)
        )
    }

    func testFlushingTwiceDoesNotDoubleCount() throws {
        let now = Date()
        let aggregator = makeAggregator(up: 100, down: 900, at: now)
        let flusher = TelemetryFlusher(store: store)

        try flusher.flush(aggregator)
        let afterFirst = try storedTotals(around: now)
        XCTAssertEqual(afterFirst.bytesUp, 100)
        XCTAssertEqual(afterFirst.bytesDown, 900)

        // Nothing new recorded — a second flush must write nothing at all.
        XCTAssertEqual(try flusher.flush(aggregator), 0)
        let afterSecond = try storedTotals(around: now)
        XCTAssertEqual(afterSecond.bytesUp, 100)
        XCTAssertEqual(afterSecond.bytesDown, 900)
    }

    func testFlushWritesOnlyTheIncrement() throws {
        let now = Date()
        let aggregator = makeAggregator(up: 100, down: 900, at: now)
        let flusher = TelemetryFlusher(store: store)
        try flusher.flush(aggregator)

        let flow = FlowDescriptor(app: app, remoteHostname: "project:EyesOnYou", openedAt: now)
        aggregator.recordOpen(flow, displayName: "Agent", route: .direct)
        aggregator.recordDelta(flowID: flow.id, app: app, up: 50, down: 100, at: now, route: .direct)

        try flusher.flush(aggregator)
        let totals = try storedTotals(around: now)
        XCTAssertEqual(totals.bytesUp, 150)
        XCTAssertEqual(totals.bytesDown, 1_000)
    }

    func testSeedingPreventsRestoredHistoryFromBeingWrittenAgain() throws {
        let now = Date()
        // Session one: record and persist.
        let first = makeAggregator(up: 100, down: 900, at: now)
        try TelemetryFlusher(store: store).flush(first)

        // Session two: restore into a fresh aggregator, as the app does on launch.
        let restored = try store.loadBuckets(
            granularity: .oneMinute,
            from: now.addingTimeInterval(-3_600),
            to: now.addingTimeInterval(3_600)
        )
        let second = TelemetryAggregator()
        second.importBuckets(restored)
        let flusher = TelemetryFlusher(store: store)
        flusher.seed(with: restored)

        XCTAssertEqual(try flusher.flush(second), 0, "restored history must not be rewritten")
        let totals = try storedTotals(around: now)
        XCTAssertEqual(totals.bytesUp, 100)
        XCTAssertEqual(totals.bytesDown, 900)
    }

    func testWithoutSeedingRestoredHistoryWouldDoubleCount() throws {
        // Guards the reason `seed(with:)` exists — if this ever stops doubling, the
        // watermark is no longer what protects restored data.
        let now = Date()
        try TelemetryFlusher(store: store).flush(makeAggregator(up: 100, down: 900, at: now))

        let restored = try store.loadBuckets(
            granularity: .oneMinute,
            from: now.addingTimeInterval(-3_600),
            to: now.addingTimeInterval(3_600)
        )
        let second = TelemetryAggregator()
        second.importBuckets(restored)
        try TelemetryFlusher(store: store).flush(second)

        XCTAssertEqual(try storedTotals(around: now).bytesUp, 200)
    }

    func testFlushPersistsProductNamesNotJustIdentifiers() throws {
        let now = Date()
        let flusher = TelemetryFlusher(store: store)
        try flusher.flush(makeAggregator(up: 10, down: 20, at: now))

        // `mergeBucket` creates the app row without a name, so the flusher has to
        // fill it in — otherwise every reader shows a bundle identifier.
        XCTAssertEqual(try store.displayNames()[app], "Agent")

        let ranked = try store.queryTopApps(
            granularity: .oneMinute,
            from: now.addingTimeInterval(-3_600),
            to: now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(ranked.first?.1, "Agent")
    }

    func testDeltaIgnoresCountersThatWentBackwards() {
        let previous = TrafficTotals(bytesUp: 100, bytesDown: 900)
        XCTAssertNil(TelemetryFlusher.delta(current: previous, previous: previous))
        let shrunk = TelemetryFlusher.delta(
            current: TrafficTotals(bytesUp: 10, bytesDown: 1_000),
            previous: previous
        )
        XCTAssertEqual(shrunk?.bytesUp, 0)
        XCTAssertEqual(shrunk?.bytesDown, 100)
    }

    func testForgetWatermarksDropsOnlyOldBuckets() throws {
        let now = Date()
        let old = now.addingTimeInterval(-86_400)
        let flusher = TelemetryFlusher(store: store)
        try flusher.flush(makeAggregator(up: 10, down: 20, at: old))
        try flusher.flush(makeAggregator(up: 30, down: 40, at: now))

        flusher.forgetWatermarks(endedBefore: now.addingTimeInterval(-3_600))
        // The recent bucket keeps its watermark, so re-flushing it writes nothing.
        let recent = makeAggregator(up: 30, down: 40, at: now)
        XCTAssertEqual(try flusher.flush(recent), 0)
    }
}

final class TelemetryStoreQueryTests: XCTestCase {
    private var directory: URL!
    private var store: TelemetryStore!

    private let app = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.example.Agent")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eyesonyou-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try TelemetryStore(path: directory.appendingPathComponent("telemetry.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(destination: String, up: UInt64, down: UInt64, at: Date) throws {
        let key = TrafficBucketKey(
            granularity: .oneMinute,
            bucketStartMs: Int64(at.timeIntervalSince1970 / 60) * 60_000,
            app: app,
            destinationKey: destination
        )
        _ = try store.upsertApp(app, displayName: "Agent")
        try store.mergeBucket(
            TrafficBucket(key: key, totals: TrafficTotals(bytesUp: up, bytesDown: down))
        )
    }

    func testLoadBucketsRoundTripsIdentityAndDestination() throws {
        let now = Date()
        try write(destination: "project:EyesOnYou", up: 10, down: 20, at: now)

        let loaded = try store.loadBuckets(
            granularity: .oneMinute,
            from: now.addingTimeInterval(-600),
            to: now.addingTimeInterval(600)
        )
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.key.app, app)
        XCTAssertEqual(loaded.first?.key.destinationKey, "project:EyesOnYou")
        XCTAssertEqual(loaded.first?.totals.bytesDown, 20)
    }

    func testTopDestinationsRanksProjectsByBytes() throws {
        let now = Date()
        try write(destination: "project:Small", up: 1, down: 1, at: now)
        try write(destination: "project:Large", up: 500, down: 500, at: now)

        let destinations = try store.queryTopDestinations(
            app: app,
            granularity: .oneMinute,
            from: now.addingTimeInterval(-600),
            to: now.addingTimeInterval(600)
        )
        XCTAssertEqual(destinations.first?.destinationKey, "project:Large")
        XCTAssertEqual(destinations.count, 2)
    }

    func testPruneRemovesOnlyBucketsBeforeCutoff() throws {
        let now = Date()
        try write(destination: "project:Old", up: 1, down: 1, at: now.addingTimeInterval(-86_400))
        try write(destination: "project:New", up: 2, down: 2, at: now)

        let removed = try store.prune(granularity: .oneMinute, olderThan: now.addingTimeInterval(-3_600))
        XCTAssertEqual(removed, 1)

        let remaining = try store.loadBuckets(
            granularity: .oneMinute,
            from: now.addingTimeInterval(-172_800),
            to: now.addingTimeInterval(600)
        )
        XCTAssertEqual(remaining.map(\.key.destinationKey), ["project:New"])
    }

    func testDisplayNamesAndStatistics() throws {
        let now = Date()
        try write(destination: "project:EyesOnYou", up: 1, down: 1, at: now)

        XCTAssertEqual(try store.displayNames()[app], "Agent")
        let stats = try store.statistics()
        XCTAssertEqual(stats.buckets, 1)
        XCTAssertEqual(stats.apps, 1)
        XCTAssertNotNil(stats.latest)
    }

    func testPruneOrphanedAppsDropsAppsWithoutTraffic() throws {
        let now = Date()
        try write(destination: "project:EyesOnYou", up: 1, down: 1, at: now)
        try store.prune(granularity: .oneMinute, olderThan: now.addingTimeInterval(3_600))

        XCTAssertEqual(try store.pruneOrphanedApps(), 1)
        XCTAssertEqual(try store.statistics().apps, 0)
    }

    /// `mergeBucket` adds to the stored row, so forgetting a watermark while its bucket
    /// is still in the aggregator makes the next flush re-add the bucket's whole total.
    /// The aggregator's retention must therefore expire a bucket *before* the flusher
    /// forgets its watermark — this is the ordering that keeps restarts idempotent.
    func testWatermarkOutlivesTheBucketItDescribes() throws {
        let now = Date()
        // A minute bucket from 2.5 days ago: inside a restore window, older than a
        // two-day watermark cutoff.
        let old = now.addingTimeInterval(-2.5 * 86_400)
        let restored = [
            TrafficBucket(
                key: TrafficBucketKey(
                    granularity: .oneMinute,
                    bucketStartMs: TelemetryAggregator.bucketStartMs(
                        atMs: Int64(old.timeIntervalSince1970 * 1000),
                        granularity: .oneMinute
                    ),
                    app: app,
                    destinationKey: "project:EyesOnYou"
                ),
                totals: TrafficTotals(bytesUp: 1_000, bytesDown: 4_000)
            )
        ]
        // Already on disk from the previous session.
        for bucket in restored { try store.mergeBucket(bucket) }

        let aggregator = TelemetryAggregator(retention: .live)
        aggregator.importBuckets(restored)
        let flusher = TelemetryFlusher(store: store)
        flusher.seed(with: restored)

        // What `pruneTelemetry` does right after a restore, then the next flush.
        flusher.forgetWatermarks(endedBefore: now.addingTimeInterval(-3 * 86_400))
        try flusher.flush(aggregator)

        let rows = try store.loadBuckets(
            granularity: .oneMinute,
            from: old.addingTimeInterval(-120),
            to: old.addingTimeInterval(120)
        )
        XCTAssertEqual(rows.reduce(UInt64(0)) { $0 &+ $1.totals.bytesUp }, 1_000)
    }
}
