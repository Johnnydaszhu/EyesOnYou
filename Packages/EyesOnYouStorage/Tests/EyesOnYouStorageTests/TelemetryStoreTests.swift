import XCTest
import EyesOnYouCore
@testable import EyesOnYouStorage

final class TelemetryStoreTests: XCTestCase {
    private var tempPath: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EyesOnYouTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempPath = dir.appendingPathComponent("telemetry.sqlite").path
    }

    override func tearDownWithError() throws {
        if let tempPath {
            try? FileManager.default.removeItem(atPath: (tempPath as NSString).deletingLastPathComponent)
        }
    }

    func testWriteReadTotalsAndTopApps() throws {
        let store = try TelemetryStore(path: tempPath)
        let chrome = AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome")
        let claude = AppIdentityKey(teamIdentifier: "TEAM2", signingIdentifier: "com.anthropic.Claude")

        let baseMs: Int64 = 1_700_000_000_000

        let chromeBucket = TrafficBucket(
            key: TrafficBucketKey(
                granularity: .oneMinute,
                bucketStartMs: baseMs,
                app: chrome,
                routeKind: .direct
            ),
            totals: TrafficTotals(bytesUp: 542_000_000, bytesDown: 3_450_000_000, flowsOpened: 100)
        )
        let claudeBucket = TrafficBucket(
            key: TrafficBucketKey(
                granularity: .oneMinute,
                bucketStartMs: baseMs,
                app: claude,
                routeKind: .customProxy
            ),
            totals: TrafficTotals(bytesUp: 312_000_000, bytesDown: 1_820_000_000, flowsOpened: 50)
        )

        _ = try store.upsertApp(chrome, displayName: "Chrome")
        _ = try store.upsertApp(claude, displayName: "Claude")
        try store.mergeBucket(chromeBucket)
        try store.mergeBucket(claudeBucket)

        // Merge again — should accumulate
        try store.mergeBucket(TrafficBucket(
            key: chromeBucket.key,
            totals: TrafficTotals(bytesUp: 1_000, bytesDown: 2_000, flowsOpened: 1)
        ))

        let from = Date(timeIntervalSince1970: Double(baseMs) / 1000 - 10)
        let to = Date(timeIntervalSince1970: Double(baseMs) / 1000 + 120)

        let chromeTotals = try store.queryTotals(
            app: chrome,
            granularity: .oneMinute,
            from: from,
            to: to
        )
        XCTAssertEqual(chromeTotals.bytesUp, 542_000_000 + 1_000)
        XCTAssertEqual(chromeTotals.bytesDown, 3_450_000_000 + 2_000)
        XCTAssertEqual(chromeTotals.flowsOpened, 101)

        let allTotals = try store.queryTotals(app: nil, granularity: .oneMinute, from: from, to: to)
        XCTAssertEqual(allTotals.bytesUp, 542_000_000 + 1_000 + 312_000_000)
        XCTAssertEqual(allTotals.bytesDown, 3_450_000_000 + 2_000 + 1_820_000_000)

        let top = try store.queryTopApps(granularity: .oneMinute, from: from, to: to, limit: 5)
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].0, chrome)
        XCTAssertEqual(top[0].1, "Chrome")
        XCTAssertEqual(top[1].0, claude)
    }

    func testFlushFromAggregator() throws {
        let store = try TelemetryStore(path: tempPath)
        let agg = TelemetryAggregator()
        let app = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.example.Tool")
        let t0 = Date(timeIntervalSince1970: 1_700_100_000)

        let flow = FlowDescriptor(app: app, remoteHostname: "api.example.com", openedAt: t0)
        agg.recordOpen(flow, displayName: "Tool")
        agg.recordDelta(flowID: flow.id, app: app, up: 100, down: 500, at: t0.addingTimeInterval(1))
        agg.recordClose(flowID: flow.id, app: app, at: t0.addingTimeInterval(2))

        try store.flushAggregator(agg, granularity: .oneSecond)

        let totals = try store.queryTotals(
            app: app,
            granularity: .oneSecond,
            from: t0.addingTimeInterval(-1),
            to: t0.addingTimeInterval(60)
        )
        XCTAssertEqual(totals.bytesUp, 100)
        XCTAssertEqual(totals.bytesDown, 500)
        XCTAssertEqual(totals.flowsOpened, 1)
        XCTAssertEqual(totals.flowsClosed, 1)
    }

    func testReadOnlyStoreReadsButCannotMutateOrCreateDatabase() throws {
        let app = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.example.ReadOnly")
        var writer: TelemetryStore? = try TelemetryStore(path: tempPath)
        _ = try writer?.upsertApp(app, displayName: "Read Only")
        writer = nil

        let reader = try TelemetryStore(path: tempPath, mode: .readOnly)
        XCTAssertEqual(try reader.statistics().apps, 1)
        XCTAssertThrowsError(try reader.upsertApp(app, displayName: "Changed"))

        let missingPath = tempPath + ".missing"
        XCTAssertThrowsError(try TelemetryStore(path: missingPath, mode: .readOnly))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
    }

    func testLongLivedReaderNeverReusesDeletedAppIdentity() throws {
        let removed = AppIdentityKey(
            teamIdentifier: nil,
            signingIdentifier: "com.example.Removed"
        )
        let replacement = AppIdentityKey(
            teamIdentifier: nil,
            signingIdentifier: "com.example.Replacement"
        )
        let base = Date(timeIntervalSince1970: 1_700_200_000)
        let baseMs = Int64(base.timeIntervalSince1970 * 1_000)
        let writer = try TelemetryStore(path: tempPath)
        try writer.mergeBucket(TrafficBucket(
            key: TrafficBucketKey(
                granularity: .oneMinute,
                bucketStartMs: baseMs,
                app: removed,
                destinationKey: "removed.example"
            ),
            totals: TrafficTotals(bytesDown: 10)
        ))
        let reader = try TelemetryStore(path: tempPath, mode: .readOnly)
        let end = base.addingTimeInterval(60)
        XCTAssertEqual(
            try reader.queryTotals(app: removed, granularity: .oneMinute, from: base, to: end).bytesDown,
            10
        )

        _ = try writer.deleteApp(removed)
        try writer.mergeBucket(TrafficBucket(
            key: TrafficBucketKey(
                granularity: .oneMinute,
                bucketStartMs: baseMs,
                app: replacement,
                destinationKey: "replacement.example"
            ),
            totals: TrafficTotals(bytesDown: 20)
        ))

        XCTAssertEqual(
            try reader.queryTotals(app: removed, granularity: .oneMinute, from: base, to: end).bytesDown,
            0
        )
        XCTAssertEqual(
            try reader.queryTopDestinations(
                app: removed,
                granularity: .oneMinute,
                from: base,
                to: end
            ).count,
            0
        )
        XCTAssertEqual(
            try reader.queryTotals(app: replacement, granularity: .oneMinute, from: base, to: end).bytesDown,
            20
        )
    }
}
