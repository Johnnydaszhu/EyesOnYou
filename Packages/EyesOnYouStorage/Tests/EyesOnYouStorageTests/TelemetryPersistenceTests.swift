import XCTest
@testable import EyesOnYouStorage
import EyesOnYouCore
import SQLite3

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

    private func executeSQL(_ sql: String) throws {
        var db: OpaquePointer?
        let path = directory.appendingPathComponent("telemetry.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw NSError(
                domain: "TelemetryFlusherTests.SQLite",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        defer { sqlite3_close(db) }

        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown"
            sqlite3_free(error)
            throw NSError(
                domain: "TelemetryFlusherTests.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
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

    func testFailedBatchRollsBackAndCanBeRetriedWithoutLosingWatermarks() throws {
        let now = Date()
        let aggregator = TelemetryAggregator()
        for (destination, up, down) in [
            ("project:First", UInt64(100), UInt64(900)),
            ("project:Second", UInt64(50), UInt64(150)),
        ] {
            let flow = FlowDescriptor(app: app, remoteHostname: destination, openedAt: now)
            aggregator.recordOpen(flow, route: .direct)
            aggregator.recordDelta(
                flowID: flow.id,
                app: app,
                up: up,
                down: down,
                at: now,
                route: .direct
            )
        }
        let flusher = TelemetryFlusher(store: store, granularities: [.oneMinute])

        // Abort the second row after the first row has already been inserted inside
        // the transaction. The whole batch must disappear, including its app row.
        try executeSQL("""
        CREATE TRIGGER fail_second_bucket
        BEFORE INSERT ON traffic_buckets
        WHEN (SELECT COUNT(*) FROM traffic_buckets) = 1
        BEGIN
            SELECT RAISE(ABORT, 'injected bucket failure');
        END;
        """)

        XCTAssertThrowsError(try flusher.flush(aggregator))
        let failedTotals = try storedTotals(around: now)
        XCTAssertEqual(failedTotals.bytesUp, 0)
        XCTAssertEqual(failedTotals.bytesDown, 0)
        XCTAssertEqual(try store.statistics().buckets, 0)
        XCTAssertEqual(try store.statistics().apps, 0)

        try executeSQL("DROP TRIGGER fail_second_bucket;")

        // A failed flush must retain the previous watermark so the complete snapshot
        // is retried. Once committed, the next identical flush must be a no-op.
        XCTAssertEqual(try flusher.flush(aggregator), 2)
        let retriedTotals = try storedTotals(around: now)
        XCTAssertEqual(retriedTotals.bytesUp, 150)
        XCTAssertEqual(retriedTotals.bytesDown, 1_050)
        XCTAssertEqual(try flusher.flush(aggregator), 0)
        XCTAssertEqual(try storedTotals(around: now).bytesDown, 1_050)
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

        XCTAssertEqual(
            second.exportChangedBuckets(granularities: [.oneMinute]).inspectedBucketCount,
            0
        )
        XCTAssertEqual(try flusher.flush(second), 0, "restored history must not be rewritten")
        let totals = try storedTotals(around: now)
        XCTAssertEqual(totals.bytesUp, 100)
        XCTAssertEqual(totals.bytesDown, 900)
    }

    func testWithoutSeedingModifiedRestoredHistoryWouldDoubleCount() throws {
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
        second.recordDelta(
            flowID: UUID(),
            app: app,
            up: 1,
            down: 1,
            at: now,
            route: .direct,
            destinationKey: "project:EyesOnYou"
        )
        try TelemetryFlusher(store: store).flush(second)

        XCTAssertEqual(try storedTotals(around: now).bytesUp, 201)
    }

    func testCompressedRestoreSeedsEffectiveBucketsWithoutRewritingHistory() throws {
        let now = Date()
        let first = TelemetryAggregator()
        for index in 0..<3 {
            first.recordDelta(
                flowID: UUID(),
                app: app,
                up: 10,
                down: 100,
                at: now,
                destinationKey: "\(index).random.example"
            )
        }
        try TelemetryFlusher(store: store, granularities: [.oneMinute]).flush(first)

        let restored = try store.loadBuckets(
            granularity: .oneMinute,
            from: now.addingTimeInterval(-3_600),
            to: now.addingTimeInterval(3_600)
        )
        let bounded = TelemetryAggregator(retention: BucketRetention(
            oneSecond: 300,
            oneMinute: 10_800,
            oneHour: 259_200,
            oneDay: 34_560_000,
            maximumDetailedKeysPerGranularity: 1
        ))
        bounded.importBuckets(restored)
        let retained = bounded.exportBuckets(granularity: .oneMinute)
        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.contains { $0.key.destinationKey == DestinationKey.other })

        let flusher = TelemetryFlusher(store: store, granularities: [.oneMinute])
        flusher.seed(with: retained)
        bounded.recordDelta(
            flowID: UUID(),
            app: app,
            up: 1,
            down: 2,
            at: now,
            destinationKey: "new.random.example"
        )
        try flusher.flush(bounded)

        let totals = try storedTotals(around: now)
        XCTAssertEqual(totals.bytesUp, 31)
        XCTAssertEqual(totals.bytesDown, 302)
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

    func testForgetWatermarksDropsOnlyBucketsNoLongerInAggregator() throws {
        let now = Date()
        let removedApp = AppIdentityKey(
            teamIdentifier: "TEAM",
            signingIdentifier: "com.example.Removed"
        )
        let aggregator = TelemetryAggregator()
        let removedFlow = FlowDescriptor(
            app: removedApp,
            remoteHostname: "project:Removed",
            openedAt: now
        )
        let retainedFlow = FlowDescriptor(
            app: app,
            remoteHostname: "project:Retained",
            openedAt: now
        )
        aggregator.recordOpen(removedFlow, route: .direct)
        aggregator.recordDelta(
            flowID: removedFlow.id,
            app: removedApp,
            up: 10,
            down: 20,
            at: now,
            route: .direct
        )
        aggregator.recordOpen(retainedFlow, route: .direct)
        aggregator.recordDelta(
            flowID: retainedFlow.id,
            app: app,
            up: 30,
            down: 40,
            at: now,
            route: .direct
        )
        let flusher = TelemetryFlusher(store: store)
        try flusher.flush(aggregator)

        aggregator.purge(app: removedApp)
        XCTAssertGreaterThan(flusher.forgetWatermarks(notPresentIn: aggregator), 0)

        // The retained bucket keeps its watermark, so reconciling and flushing it is a no-op.
        XCTAssertEqual(try flusher.flush(aggregator), 0)
        XCTAssertEqual(try storedTotals(around: now).bytesDown, 60)
    }

    func testDeleteWatermarkAllowsFreshTrafficFromSameActiveApp() throws {
        let now = Date()
        let aggregator = makeAggregator(up: 100, down: 900, at: now)
        let flusher = TelemetryFlusher(store: store)
        try flusher.flush(aggregator)

        aggregator.purge(app: app)
        let newFlow = FlowDescriptor(
            app: app,
            remoteHostname: "project:AfterDelete",
            openedAt: now
        )
        aggregator.recordOpen(newFlow, displayName: "Agent")
        aggregator.recordDelta(
            flowID: newFlow.id,
            app: app,
            up: 7,
            down: 13,
            at: now
        )

        try store.deleteApp(app)
        XCTAssertGreaterThan(flusher.forgetWatermarks(for: app), 0)
        try flusher.flush(aggregator)
        let totals = try storedTotals(around: now)
        XCTAssertEqual(totals.bytesUp, 7)
        XCTAssertEqual(totals.bytesDown, 13)
    }

    func testQueuedFlushBeforeDeleteCannotLoseFreshTraffic() throws {
        let now = Date()
        let aggregator = makeAggregator(up: 100, down: 900, at: now)
        let flusher = TelemetryFlusher(store: store)
        try flusher.flush(aggregator)

        aggregator.purge(app: app)
        let freshFlow = FlowDescriptor(
            app: app,
            remoteHostname: "project:AfterDelete",
            openedAt: now.addingTimeInterval(1)
        )
        aggregator.recordOpen(freshFlow, displayName: "Agent")
        aggregator.recordDelta(
            flowID: freshFlow.id,
            app: app,
            up: 20,
            down: 200,
            at: now.addingTimeInterval(1)
        )

        // This represents a flush that was already queued when deletion began.
        try flusher.flush(aggregator)
        try flusher.deleteApp(app, preservingCurrentBucketsIn: aggregator)
        try flusher.flush(aggregator)

        let totals = try storedTotals(around: now)
        XCTAssertEqual(totals.bytesUp, 20)
        XCTAssertEqual(totals.bytesDown, 200)
    }

    func testWatermarkReconciliationDoesNotReplayRetainedHourOrDayBuckets() throws {
        let now = Date()
        let old = now.addingTimeInterval(-10 * 86_400)
        let aggregator = TelemetryAggregator(retention: .live)
        let flow = FlowDescriptor(
            app: app,
            remoteHostname: "project:Historical",
            openedAt: old
        )
        aggregator.recordOpen(flow, route: .direct)
        aggregator.recordDelta(
            flowID: flow.id,
            app: app,
            up: 1_000,
            down: 4_000,
            at: old,
            route: .direct
        )

        let flusher = TelemetryFlusher(
            store: store,
            granularities: [.oneHour, .oneDay]
        )
        XCTAssertEqual(try flusher.flush(aggregator), 2)
        XCTAssertEqual(flusher.forgetWatermarks(notPresentIn: aggregator), 0)
        XCTAssertEqual(try flusher.flush(aggregator), 0)

        let from = old.addingTimeInterval(-86_400)
        let to = old.addingTimeInterval(86_400)
        let hourly = try store.queryTotals(
            app: nil,
            granularity: .oneHour,
            from: from,
            to: to
        )
        let daily = try store.queryTotals(
            app: nil,
            granularity: .oneDay,
            from: from,
            to: to
        )
        XCTAssertEqual(hourly.bytesUp, 1_000)
        XCTAssertEqual(hourly.bytesDown, 4_000)
        XCTAssertEqual(daily.bytesUp, 1_000)
        XCTAssertEqual(daily.bytesDown, 4_000)
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

    func testQueriesForUnknownAppDoNotCreateCatalogRows() throws {
        let now = Date()
        let unknown = AppIdentityKey(
            teamIdentifier: "NONE",
            signingIdentifier: "com.example.DoesNotExist"
        )

        let totals = try store.queryTotals(
            app: unknown,
            granularity: .oneMinute,
            from: now.addingTimeInterval(-60),
            to: now
        )
        let destinations = try store.queryTopDestinations(
            app: unknown,
            granularity: .oneMinute,
            from: now.addingTimeInterval(-60),
            to: now
        )
        XCTAssertEqual(totals.totalBytes, 0)
        XCTAssertTrue(destinations.isEmpty)
        XCTAssertEqual(try store.statistics().apps, 0)
    }

    func testPruneOrphanedAppsDropsAppsWithoutTraffic() throws {
        let now = Date()
        try write(destination: "project:EyesOnYou", up: 1, down: 1, at: now)
        try store.prune(granularity: .oneMinute, olderThan: now.addingTimeInterval(3_600))

        XCTAssertEqual(try store.pruneOrphanedApps(), 1)
        XCTAssertEqual(try store.statistics().apps, 0)
    }

    func testDeleteAppRemovesCatalogAndEveryStoredBucket() throws {
        let now = Date()
        try write(destination: "project:First", up: 10, down: 20, at: now)
        try write(
            destination: "project:Second",
            up: 30,
            down: 40,
            at: now.addingTimeInterval(60)
        )

        XCTAssertEqual(try store.deleteApp(app), 2)
        let stats = try store.statistics()
        XCTAssertEqual(stats.buckets, 0)
        XCTAssertEqual(stats.apps, 0)
        XCTAssertTrue(try store.displayNames().isEmpty)
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
        flusher.forgetWatermarks(notPresentIn: aggregator)
        try flusher.flush(aggregator)

        let rows = try store.loadBuckets(
            granularity: .oneMinute,
            from: old.addingTimeInterval(-120),
            to: old.addingTimeInterval(120)
        )
        XCTAssertEqual(rows.reduce(UInt64(0)) { $0 &+ $1.totals.bytesUp }, 1_000)
    }
}
