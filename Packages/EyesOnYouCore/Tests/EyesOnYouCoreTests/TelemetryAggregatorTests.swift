import XCTest
@testable import EyesOnYouCore

final class TelemetryAggregatorTests: XCTestCase {
    private let chrome = AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome")
    private let safari = AppIdentityKey(teamIdentifier: "APPLE", signingIdentifier: "com.apple.Safari")

    func testCounterDeltaFromCumulativeReports() {
        let registry = ShardedFlowRegistry(shardCount: 8)
        let flowID = UUID()

        let d1 = registry.update(id: flowID, cumulativeUp: 100, cumulativeDown: 200)
        XCTAssertEqual(d1.up, 100)
        XCTAssertEqual(d1.down, 200)

        let d2 = registry.update(id: flowID, cumulativeUp: 150, cumulativeDown: 500)
        XCTAssertEqual(d2.up, 50)
        XCTAssertEqual(d2.down, 300)

        // Reset: lower cumulative treated as new baseline, not negative.
        let d3 = registry.update(id: flowID, cumulativeUp: 10, cumulativeDown: 20)
        XCTAssertEqual(d3.up, 10)
        XCTAssertEqual(d3.down, 20)

        let counters = registry.counters(for: flowID)
        XCTAssertEqual(counters?.totalUp, 100 + 50 + 10)
        XCTAssertEqual(counters?.totalDown, 200 + 300 + 20)
    }

    func testAggregatorTotalsAndRatesFromFlowLifecycle() {
        let agg = TelemetryAggregator()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let flowA = FlowDescriptor(
            id: UUID(),
            app: chrome,
            remoteHostname: "www.google.com",
            remotePort: 443,
            openedAt: t0
        )
        let flowB = FlowDescriptor(
            id: UUID(),
            app: safari,
            remoteHostname: "apple.com",
            remotePort: 443,
            openedAt: t0
        )

        agg.recordOpen(flowA, displayName: "Chrome", route: .direct)
        agg.recordOpen(flowB, displayName: "Safari", route: .systemProxy)

        // Simulate stats reports via registry → delta → aggregator
        let registry = ShardedFlowRegistry()
        let c1 = registry.update(id: flowA.id, cumulativeUp: 1_024, cumulativeDown: 2_048)
        agg.recordDelta(
            flowID: flowA.id,
            app: chrome,
            up: c1.up,
            down: c1.down,
            at: t0.addingTimeInterval(0.5),
            route: .direct
        )
        let c2 = registry.update(id: flowA.id, cumulativeUp: 3_072, cumulativeDown: 10_240)
        agg.recordDelta(
            flowID: flowA.id,
            app: chrome,
            up: c2.up,
            down: c2.down,
            at: t0.addingTimeInterval(1.0),
            route: .direct
        )

        let s1 = registry.update(id: flowB.id, cumulativeUp: 512, cumulativeDown: 4_096)
        agg.recordDelta(
            flowID: flowB.id,
            app: safari,
            up: s1.up,
            down: s1.down,
            at: t0.addingTimeInterval(0.5),
            route: .systemProxy
        )

        agg.recordClose(flowID: flowA.id, app: chrome, at: t0.addingTimeInterval(2))

        let from = t0.addingTimeInterval(-1)
        let to = t0.addingTimeInterval(60)
        let chromeTotals = agg.totals(for: chrome, from: from, to: to, preferredGranularity: .oneSecond)
        // Chrome deltas: up 1024+2048=3072, down 2048+8192=10240
        XCTAssertEqual(chromeTotals.bytesUp, 3_072)
        XCTAssertEqual(chromeTotals.bytesDown, 10_240)
        XCTAssertEqual(chromeTotals.flowsOpened, 1)
        XCTAssertEqual(chromeTotals.flowsClosed, 1)

        let allTotals = agg.totals(for: nil, from: from, to: to, preferredGranularity: .oneSecond)
        XCTAssertEqual(allTotals.bytesUp, 3_072 + 512)
        XCTAssertEqual(allTotals.bytesDown, 10_240 + 4_096)
        XCTAssertEqual(allTotals.flowsOpened, 2)

        let top = agg.topApps(from: from, to: to, limit: 5, preferredGranularity: .oneSecond)
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0].app, chrome)
        XCTAssertEqual(top[0].displayName, "Chrome")
        XCTAssertEqual(top[0].totals.totalBytes, 3_072 + 10_240)

        let recent = agg.recentConnections(limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent.contains { $0.host == "www.google.com" })
    }

    func testHistoryRollupsAcrossGranularities() {
        let agg = TelemetryAggregator()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Spread traffic across 3 minutes so minute buckets differ from second.
        for minute in 0..<3 {
            let flow = FlowDescriptor(
                id: UUID(),
                app: chrome,
                remoteHostname: "cdn.example.com",
                openedAt: base.addingTimeInterval(Double(minute) * 60)
            )
            agg.recordOpen(flow, displayName: "Chrome")
            agg.recordDelta(
                flowID: flow.id,
                app: chrome,
                up: 1_000,
                down: 10_000,
                at: base.addingTimeInterval(Double(minute) * 60 + 5)
            )
            agg.recordClose(flowID: flow.id, app: chrome, at: base.addingTimeInterval(Double(minute) * 60 + 10))
        }

        let shortFrom = base
        let shortTo = base.addingTimeInterval(90)
        let shortTotals = agg.totals(
            for: chrome,
            from: shortFrom,
            to: shortTo,
            preferredGranularity: .oneMinute
        )
        // First two minutes (0 and 60s) fall in range [0, 90)
        XCTAssertEqual(shortTotals.bytesUp, 2_000)
        XCTAssertEqual(shortTotals.bytesDown, 20_000)
        XCTAssertEqual(shortTotals.flowsOpened, 2)

        let multiFrom = base
        let multiTo = base.addingTimeInterval(180)
        let multiTotals = agg.totals(
            for: chrome,
            from: multiFrom,
            to: multiTo,
            preferredGranularity: .oneMinute
        )
        XCTAssertEqual(multiTotals.bytesUp, 3_000)
        XCTAssertEqual(multiTotals.bytesDown, 30_000)
        XCTAssertEqual(multiTotals.flowsOpened, 3)
        XCTAssertEqual(multiTotals.flowsClosed, 3)
    }

    func testRouteDirectionalTotalsPreserveAsymmetricUploadAndDownload() {
        let agg = TelemetryAggregator()
        let t0 = Date(timeIntervalSince1970: 1_700_100_000)

        agg.recordDelta(
            flowID: UUID(),
            app: chrome,
            up: 9_000,
            down: 100,
            at: t0,
            route: .direct
        )
        agg.recordDelta(
            flowID: UUID(),
            app: chrome,
            up: 50,
            down: 8_000,
            at: t0,
            route: .systemProxy
        )
        agg.recordDelta(
            flowID: UUID(),
            app: chrome,
            up: 700,
            down: 20,
            at: t0,
            route: .proxy(profileID: UUID())
        )
        agg.recordDelta(
            flowID: UUID(),
            app: chrome,
            up: 3,
            down: 600,
            at: t0,
            routeKindOverride: .unknown
        )

        // Other apps must not leak into an app-scoped route breakdown.
        agg.recordDelta(
            flowID: UUID(),
            app: safari,
            up: 1_000_000,
            down: 1_000_000,
            at: t0,
            route: .direct
        )

        let result = agg.routeDirectionalTotals(
            for: chrome,
            from: t0.addingTimeInterval(-1),
            to: t0.addingTimeInterval(60),
            preferredGranularity: .oneSecond
        )

        XCTAssertEqual(result.direct.bytesUp, 9_000)
        XCTAssertEqual(result.direct.bytesDown, 100)
        XCTAssertEqual(result.systemProxy.bytesUp, 50)
        XCTAssertEqual(result.systemProxy.bytesDown, 8_000)
        XCTAssertEqual(result.customProxy.bytesUp, 700)
        XCTAssertEqual(result.customProxy.bytesDown, 20)
        XCTAssertEqual(result.unknown.bytesUp, 3)
        XCTAssertEqual(result.unknown.bytesDown, 600)
        XCTAssertEqual(result.proxied.bytesUp, 750)
        XCTAssertEqual(result.proxied.bytesDown, 8_020)
        XCTAssertEqual(result.all.bytesUp, 9_753)
        XCTAssertEqual(result.all.bytesDown, 8_720)
    }

    func testRecordDeltaRouteKindOverrideStoresUnknownRoute() {
        let agg = TelemetryAggregator()
        let t0 = Date(timeIntervalSince1970: 1_700_100_100)

        agg.recordDelta(
            flowID: UUID(),
            app: chrome,
            up: 321,
            down: 654,
            at: t0,
            route: .systemProxy,
            routeKindOverride: .unknown
        )

        let result = agg.routeDirectionalTotals(
            for: nil,
            from: t0.addingTimeInterval(-1),
            to: t0.addingTimeInterval(60),
            preferredGranularity: .oneSecond
        )
        XCTAssertEqual(result.unknown.bytesUp, 321)
        XCTAssertEqual(result.unknown.bytesDown, 654)
        XCTAssertEqual(result.systemProxy.totalBytes, 0)
    }

    func testByteFormat() {
        XCTAssertEqual(ByteFormat.string(for: 512), "512 B")
        XCTAssertTrue(ByteFormat.string(for: 3_702_823_424).contains("GB") || ByteFormat.string(for: 3_702_823_424).contains("3."))
        // Live rates use MB/s (bytes/sec), not Mbps (bits/sec).
        let rate = ByteFormat.rateMBps(bytesPerSecond: 1_550_000) // ~1.48 MB/s
        XCTAssertTrue(rate.contains("MB/s"), "expected MB/s unit, got \(rate)")
        XCTAssertFalse(rate.lowercased().contains("mbps"))
        XCTAssertEqual(ByteFormat.rateMBps(bytesPerSecond: 2 * 1024 * 1024), "2.00 MB/s")
        XCTAssertTrue(ByteFormat.rateMBps(bytesPerSecond: 50_000).contains("KB/s"))
    }

    func testBrowserTrafficSplitsByHostname() {
        let agg = TelemetryAggregator()
        let t0 = Date(timeIntervalSince1970: 1_700_200_000)
        XCTAssertTrue(BrowserIdentity.isBrowser(chrome))

        let sites = [
            ("www.google.com", UInt64(1000), UInt64(10_000)),
            ("github.com", UInt64(2000), UInt64(20_000)),
            ("www.youtube.com", UInt64(3000), UInt64(30_000)),
        ]
        for (host, up, down) in sites {
            let flow = FlowDescriptor(
                app: chrome,
                remoteHostname: host,
                remotePort: 443,
                openedAt: t0
            )
            agg.recordOpen(flow, displayName: "Chrome")
            agg.recordDelta(
                flowID: flow.id,
                app: chrome,
                up: up,
                down: down,
                at: t0.addingTimeInterval(1),
                destinationKey: DestinationKey.make(hostname: host, address: nil)
            )
        }

        // Non-browser stays aggregated without forced site expansion in topApps when not browser
        let tool = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.example.CLI")
        let toolFlow = FlowDescriptor(app: tool, remoteHostname: "api.example.com", openedAt: t0)
        agg.recordOpen(toolFlow, displayName: "CLI")
        agg.recordDelta(flowID: toolFlow.id, app: tool, up: 50, down: 50, at: t0.addingTimeInterval(1))

        let from = t0.addingTimeInterval(-1)
        let to = t0.addingTimeInterval(60)
        let top = agg.topApps(from: from, to: to, limit: 10, preferredGranularity: .oneSecond)

        let chromeSnap = top.first { $0.app == chrome }
        XCTAssertNotNil(chromeSnap)
        XCTAssertTrue(chromeSnap!.isBrowser)
        XCTAssertEqual(chromeSnap!.sites.count, 3)
        XCTAssertEqual(chromeSnap!.totals.bytesUp, 1000 + 2000 + 3000)
        XCTAssertEqual(chromeSnap!.totals.bytesDown, 10_000 + 20_000 + 30_000)
        // Sites ordered by total bytes desc → youtube first
        XCTAssertEqual(chromeSnap!.sites[0].hostname, "www.youtube.com")
        XCTAssertEqual(chromeSnap!.sites[0].totals.bytesDown, 30_000)
        XCTAssertEqual(chromeSnap!.sites[1].hostname, "github.com")
        XCTAssertEqual(chromeSnap!.sites[2].hostname, "www.google.com")

        let destinations = agg.topDestinations(for: chrome, from: from, to: to, preferredGranularity: .oneSecond)
        XCTAssertEqual(destinations.count, 3)
        XCTAssertEqual(Set(destinations.map(\.hostname)), Set(["www.google.com", "github.com", "www.youtube.com"]))

        // Suffix false-aggregation: different hosts stay separate
        XCTAssertNotEqual(
            DestinationKey.make(hostname: "evilapi.com", address: nil),
            DestinationKey.make(hostname: "api.com", address: nil)
        )
    }

    // MARK: - Retention

    /// One-second buckets used to accumulate for as long as the process ran, so a
    /// day-long session held ~86 400 × apps × destinations of them and every query
    /// scanned the lot.
    func testLiveRetentionBoundsOneSecondBuckets() {
        let agg = TelemetryAggregator(retention: .live)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for second in 0..<3_600 {
            agg.recordDelta(
                flowID: UUID(),
                app: chrome,
                up: 10,
                down: 20,
                at: t0.addingTimeInterval(Double(second)),
                destinationKey: "www.google.com"
            )
        }

        // Five minutes of second buckets, not an hour's worth.
        XCTAssertLessThanOrEqual(agg.bucketCount(granularity: .oneSecond), 301)
        XCTAssertGreaterThanOrEqual(agg.bucketCount(granularity: .oneSecond), 300)

        // Coarser granularities still answer for the whole hour.
        let end = t0.addingTimeInterval(3_600)
        XCTAssertEqual(agg.totals(for: chrome, from: t0, to: end).bytesUp, 3_600 * 10)
    }

    func testUnlimitedRetentionKeepsEverySecondBucket() {
        let agg = TelemetryAggregator()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for second in 0..<1_000 {
            agg.recordDelta(
                flowID: UUID(),
                app: chrome,
                up: 1,
                down: 1,
                at: t0.addingTimeInterval(Double(second)),
                destinationKey: "www.google.com"
            )
        }
        XCTAssertEqual(agg.bucketCount(granularity: .oneSecond), 1_000)
    }

    /// A restore wider than the retention window must be trimmed. Keeping those
    /// buckets is what let the flusher re-write history it had already stored.
    func testImportRespectsRetention() {
        let agg = TelemetryAggregator(retention: .live)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let imported = (0..<6).map { day -> TrafficBucket in
            let at = t0.addingTimeInterval(Double(day) * 86_400)
            return TrafficBucket(
                key: TrafficBucketKey(
                    granularity: .oneMinute,
                    bucketStartMs: TelemetryAggregator.bucketStartMs(
                        atMs: Int64(at.timeIntervalSince1970 * 1000),
                        granularity: .oneMinute
                    ),
                    app: chrome,
                    destinationKey: "www.google.com"
                ),
                totals: TrafficTotals(bytesUp: 1, bytesDown: 1)
            )
        }
        agg.importBuckets(imported)

        // `.live` keeps two days of minute buckets: days 3, 4 and 5 survive.
        XCTAssertEqual(agg.bucketCount(granularity: .oneMinute), 3)
    }
}
