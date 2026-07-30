import Foundation

/// Granularities for time-bucketed traffic (seconds).
public enum BucketGranularity: Int, Sendable, CaseIterable, Codable {
    case oneSecond = 1
    case oneMinute = 60
    case oneHour = 3600
    case oneDay = 86_400

    public var seconds: Int { rawValue }
}

public struct TrafficBucketKey: Hashable, Sendable {
    public let granularity: BucketGranularity
    public let bucketStartMs: Int64
    public let app: AppIdentityKey
    /// Normalized hostname / site key (browsers split by this).
    public let destinationKey: String
    public let routeKind: RouteKind
    public let transport: TransportProtocol

    public init(
        granularity: BucketGranularity,
        bucketStartMs: Int64,
        app: AppIdentityKey,
        destinationKey: String = DestinationKey.unknown,
        routeKind: RouteKind = .direct,
        transport: TransportProtocol = .tcp
    ) {
        self.granularity = granularity
        self.bucketStartMs = bucketStartMs
        self.app = app
        self.destinationKey = destinationKey
        self.routeKind = routeKind
        self.transport = transport
    }
}

public struct TrafficBucket: Sendable, Equatable {
    public var key: TrafficBucketKey
    public var totals: TrafficTotals

    public init(key: TrafficBucketKey, totals: TrafficTotals = TrafficTotals()) {
        self.key = key
        self.totals = totals
    }
}

/// Buckets changed since the persistence consumer last acknowledged them.
///
/// The revision token makes acknowledgement safe when ingestion continues while
/// SQLite is committing: a bucket changed after this snapshot remains pending.
public struct TrafficBucketChangeSet: Sendable, Equatable {
    public let revision: UInt64
    public let buckets: [TrafficBucket]
    /// Number of dirty buckets inspected to build this snapshot.
    public let inspectedBucketCount: Int

    public init(revision: UInt64, buckets: [TrafficBucket], inspectedBucketCount: Int) {
        self.revision = revision
        self.buckets = buckets
        self.inspectedBucketCount = inspectedBucketCount
    }
}

/// Direction-preserving byte totals for each observable network route.
///
/// Keeping upload and download separate here avoids deriving both directions from
/// one combined route percentage. `unknown` also absorbs the impossible case of
/// bytes recorded on a blocked route so callers never silently lose byte totals.
public struct RouteDirectionalTotals: Sendable, Equatable {
    public var direct: TrafficTotals
    public var systemProxy: TrafficTotals
    public var customProxy: TrafficTotals
    public var unknown: TrafficTotals

    public init(
        direct: TrafficTotals = TrafficTotals(),
        systemProxy: TrafficTotals = TrafficTotals(),
        customProxy: TrafficTotals = TrafficTotals(),
        unknown: TrafficTotals = TrafficTotals()
    ) {
        self.direct = direct
        self.systemProxy = systemProxy
        self.customProxy = customProxy
        self.unknown = unknown
    }

    public var proxied: TrafficTotals {
        systemProxy + customProxy
    }

    public var all: TrafficTotals {
        direct + systemProxy + customProxy + unknown
    }
}

public struct AppRouteByteTotals: Sendable, Equatable {
    public var direct: UInt64
    public var proxied: UInt64
    public var unknown: UInt64

    public init(
        direct: UInt64 = 0,
        proxied: UInt64 = 0,
        unknown: UInt64 = 0
    ) {
        self.direct = direct
        self.proxied = proxied
        self.unknown = unknown
    }
}

/// Cumulative upload / download checkpoints across the requested overview range.
///
/// The first point is always zero and the final point equals the scoped period
/// total. Intermediate points preserve when bytes were observed, so a large total
/// recorded before the dashboard opened does not collapse the chart into a flat line.
public struct CumulativeTrafficSeries: Sendable, Equatable {
    public var bytesUp: [UInt64]
    public var bytesDown: [UInt64]

    public init(bytesUp: [UInt64] = [], bytesDown: [UInt64] = []) {
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
    }
}

/// Overview values that share the same time range and source buckets.
public struct TrafficOverviewRollup: Sendable {
    public var topApps: [AppTrafficSnapshot]
    public var routeTotals: RouteDirectionalTotals
    public var routeShares: [AppIdentityKey: AppRouteByteTotals]
    public var cumulativeTraffic: CumulativeTrafficSeries

    public init(
        topApps: [AppTrafficSnapshot],
        routeTotals: RouteDirectionalTotals,
        routeShares: [AppIdentityKey: AppRouteByteTotals],
        cumulativeTraffic: CumulativeTrafficSeries = CumulativeTrafficSeries()
    ) {
        self.topApps = topApps
        self.routeTotals = routeTotals
        self.routeShares = routeShares
        self.cumulativeTraffic = cumulativeTraffic
    }
}

/// How much history each granularity keeps **in memory**.
///
/// A process that ingests continuously would otherwise grow without bound: nothing
/// ever removed a one-second bucket, so a day-long session held ~86 400 × (apps ×
/// destinations) of them, and every query scanned the lot.
public struct BucketRetention: Sendable, Equatable {
    /// Seconds of history to keep, per granularity. `nil` means unbounded.
    public var oneSecond: TimeInterval?
    public var oneMinute: TimeInterval?
    public var oneHour: TimeInterval?
    public var oneDay: TimeInterval?

    public init(
        oneSecond: TimeInterval?,
        oneMinute: TimeInterval?,
        oneHour: TimeInterval?,
        oneDay: TimeInterval?
    ) {
        self.oneSecond = oneSecond
        self.oneMinute = oneMinute
        self.oneHour = oneHour
        self.oneDay = oneDay
    }

    /// Keep everything — the default, and what one-shot readers (CLI, tests) want
    /// when they hydrate an aggregator from an arbitrary historical range.
    public static let unlimited = BucketRetention(
        oneSecond: nil,
        oneMinute: nil,
        oneHour: nil,
        oneDay: nil
    )

    /// For a process that ingests for as long as it runs (host app, system extension).
    ///
    /// Windows follow `chooseGranularity`: second buckets only ever answer live rates
    /// and ranges under two minutes, minute buckets only ranges under two hours. Each
    /// limit covers at least the widest matching dashboard query.
    public static let live = BucketRetention(
        oneSecond: 300,
        oneMinute: 2 * 86_400,
        oneHour: 3 * 86_400,
        oneDay: 3 * 365 * 86_400
    )

    func seconds(for granularity: BucketGranularity) -> TimeInterval? {
        switch granularity {
        case .oneSecond: return oneSecond
        case .oneMinute: return oneMinute
        case .oneHour: return oneHour
        case .oneDay: return oneDay
        }
    }
}

private struct ActiveFlowState: Sendable {
    let app: AppIdentityKey
    let openedAt: Date
    let destinationKey: String
}

/// In-memory multi-granularity traffic aggregator.
/// Call sites feed open / stats-delta / close events; queries roll up ranges.
/// Buckets are keyed by app **and** destination so browsers can split by website.
///
/// Storage is indexed by bucket start time, one table per granularity, so a range
/// query touches only the buckets inside the range instead of every bucket ever
/// recorded. That matters because the dashboard re-queries once a second.
public final class TelemetryAggregator: @unchecked Sendable {
    /// Everything about a bucket except its granularity and start time — those are
    /// the index, so they are not repeated in the value.
    private struct SlotKey: Hashable {
        let app: AppIdentityKey
        let destinationKey: String
        let routeKind: RouteKind
        let transport: TransportProtocol
    }

    private struct BucketLocator: Hashable {
        let index: Int
        let bucketStartMs: Int64
        let slotKey: SlotKey
    }

    private struct RateBatch {
        let key: Int64
        let duration: TimeInterval
        var up: UInt64
        var down: UInt64
    }

    private struct LiveRateSnapshot {
        let up: Double
        let down: Double
        let at: Date
    }

    private struct RankingContext {
        let displayNames: [AppIdentityKey: String]
        let liveRates: [AppIdentityKey: LiveRateSnapshot]
        let activeCountByApp: [AppIdentityKey: Int]
        let activeCountByAppSite: [AppIdentityKey: [String: Int]]
    }

    private struct TimedBucketRow {
        let bucketStartMs: Int64
        let key: SlotKey
        let totals: TrafficTotals
    }

    private typealias Slot = [SlotKey: TrafficTotals]

    private let lock = NSLock()
    /// `timeline[granularityIndex][bucketStartMs][slotKey]`.
    private var timeline: [[Int64: Slot]] = Array(repeating: [:], count: 4)
    /// Newest and oldest bucket start seen per granularity, so eviction can skip
    /// the scan when nothing has aged out.
    private var newestSlotStart: [Int64] = [.min, .min, .min, .min]
    private var oldestSlotStart: [Int64] = [.max, .max, .max, .max]

    private var appDisplayNames: [AppIdentityKey: String] = [:]
    private var liveRates: [AppIdentityKey: (up: Double, down: Double, at: Date)] = [:]
    private var rateBatches: [AppIdentityKey: RateBatch] = [:]
    /// Only buckets changed since the last successful persistence acknowledgement.
    private var bucketRevisions: [BucketLocator: UInt64] = [:]
    private var dirtyBuckets: [Set<BucketLocator>] = Array(repeating: [], count: 4)
    private var currentRevision: UInt64 = 0
    /// Last wall-clock time bytes were recorded for an app (does not expire with live rates).
    private var lastTrafficAtByApp: [AppIdentityKey: Date] = [:]
    private var activeFlows: [UUID: ActiveFlowState] = [:]
    /// Optional live socket census supplied by a fallback sampler. Synthetic flows
    /// represent an app/route lifecycle, not every OS socket, so their count alone
    /// would under-report active connections.
    private var observedActiveConnectionCounts: [AppIdentityKey: Int] = [:]
    private var recentConnections: [LiveConnection] = []
    private let maxRecentConnections: Int
    private let retention: BucketRetention

    public init(
        maxRecentConnections: Int = 100,
        retention: BucketRetention = .unlimited
    ) {
        self.maxRecentConnections = maxRecentConnections
        self.retention = retention
    }

    // MARK: - Event ingestion

    public func recordOpen(
        _ flow: FlowDescriptor,
        displayName: String? = nil,
        route: RouteAction = .direct,
        firewall: FirewallAction = .allow
    ) {
        lock.lock()
        defer { lock.unlock() }

        let dest = DestinationKey.make(from: flow)
        activeFlows[flow.id] = ActiveFlowState(app: flow.app, openedAt: flow.openedAt, destinationKey: dest)
        if let displayName {
            appDisplayNames[flow.app] = displayName
        }
        let name = appDisplayNames[flow.app] ?? flow.app.signingIdentifier
        let connection = LiveConnection(
            id: flow.id,
            app: flow.app,
            displayName: name,
            host: flow.remoteHostname ?? flow.remoteAddress ?? DestinationKey.unknown,
            protocolLabel: protocolLabel(flow),
            route: route,
            firewall: firewall,
            timestamp: flow.openedAt
        )
        recentConnections.insert(connection, at: 0)
        if recentConnections.count > maxRecentConnections {
            recentConnections.removeLast(recentConnections.count - maxRecentConnections)
        }

        let nowMs = Int64(flow.openedAt.timeIntervalSince1970 * 1000)
        let slotKey = SlotKey(
            app: flow.app,
            destinationKey: dest,
            routeKind: RouteKind(action: route),
            transport: flow.transport
        )
        for granularity in BucketGranularity.allCases {
            mutate(granularity: granularity, atMs: nowMs, slotKey: slotKey) { totals in
                totals.flowsOpened &+= 1
                if firewall == .block {
                    totals.flowsBlocked &+= 1
                }
            }
        }
    }

    /// Apply a byte delta (already converted from cumulative reports).
    public func recordDelta(
        flowID: UUID,
        app: AppIdentityKey,
        up: UInt64,
        down: UInt64,
        at: Date = Date(),
        route: RouteAction = .direct,
        transport: TransportProtocol = .tcp,
        destinationKey: String? = nil,
        routeKindOverride: RouteKind? = nil,
        sampleInterval: TimeInterval? = nil
    ) {
        guard up > 0 || down > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        let dest = destinationKey
            ?? activeFlows[flowID]?.destinationKey
            ?? DestinationKey.unknown

        let nowMs = Int64(at.timeIntervalSince1970 * 1000)
        let slotKey = SlotKey(
            app: app,
            destinationKey: dest,
            routeKind: routeKindOverride ?? RouteKind(action: route),
            transport: transport
        )
        if let sampleInterval, sampleInterval > 0, sampleInterval.isFinite {
            for granularity in BucketGranularity.allCases {
                recordBytesAcrossInterval(
                    granularity: granularity,
                    endingAtMs: nowMs,
                    interval: sampleInterval,
                    slotKey: slotKey,
                    up: up,
                    down: down
                )
            }
        } else {
            for granularity in BucketGranularity.allCases {
                mutate(granularity: granularity, atMs: nowMs, slotKey: slotKey) { totals in
                    totals.bytesUp &+= up
                    totals.bytesDown &+= down
                }
            }
        }

        updateLiveRate(
            app: app,
            up: up,
            down: down,
            at: at,
            sampleInterval: sampleInterval
        )
        noteTraffic(app: app, at: at)
    }

    public func recordClose(
        flowID: UUID,
        app: AppIdentityKey,
        at: Date = Date(),
        finalUp: UInt64 = 0,
        finalDown: UInt64 = 0,
        route: RouteAction = .direct,
        transport: TransportProtocol = .tcp,
        destinationKey: String? = nil,
        routeKindOverride: RouteKind? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        let dest = destinationKey
            ?? activeFlows[flowID]?.destinationKey
            ?? DestinationKey.unknown
        activeFlows.removeValue(forKey: flowID)

        let nowMs = Int64(at.timeIntervalSince1970 * 1000)
        let slotKey = SlotKey(
            app: app,
            destinationKey: dest,
            routeKind: routeKindOverride ?? RouteKind(action: route),
            transport: transport
        )
        for granularity in BucketGranularity.allCases {
            mutate(granularity: granularity, atMs: nowMs, slotKey: slotKey) { totals in
                if finalUp > 0 || finalDown > 0 {
                    totals.bytesUp &+= finalUp
                    totals.bytesDown &+= finalDown
                }
                totals.flowsClosed &+= 1
            }
        }
        if finalUp > 0 || finalDown > 0 {
            noteTraffic(app: app, at: at)
        }
    }

    public func setDisplayName(_ name: String, for app: AppIdentityKey) {
        lock.lock()
        defer { lock.unlock() }
        appDisplayNames[app] = name
    }

    // MARK: - Queries

    /// Sum totals for an app over a wall-clock range using the best granularity.
    public func totals(
        for app: AppIdentityKey?,
        from: Date,
        to: Date,
        preferredGranularity: BucketGranularity? = nil
    ) -> TrafficTotals {
        lock.lock()
        defer { lock.unlock() }

        var result = TrafficTotals()
        forEachBucket(from: from, to: to, preferred: preferredGranularity) { key, totals in
            if let app, key.app != app { return }
            result.merge(totals)
        }
        return result
    }

    public func topApps(
        from: Date,
        to: Date,
        limit: Int = 10,
        preferredGranularity: BucketGranularity? = nil,
        includeSitesForBrowsers: Bool = true
    ) -> [AppTrafficSnapshot] {
        let (rows, context) = rankingSourceSnapshot(
            from: from,
            to: to,
            preferred: preferredGranularity
        )

        var byApp: [AppIdentityKey: TrafficTotals] = [:]
        var byAppSite: [AppIdentityKey: [String: TrafficTotals]] = [:]
        for row in rows {
            let key = row.key
            let totals = row.totals
            byApp[key.app, default: TrafficTotals()].merge(totals)
            if includeSitesForBrowsers {
                byAppSite[key.app, default: [:]][key.destinationKey, default: TrafficTotals()].merge(totals)
            }
        }
        return makeTopApps(
            byApp: byApp,
            byAppSite: byAppSite,
            limit: limit,
            includeSites: includeSitesForBrowsers,
            now: Date(),
            context: context
        )
    }

    /// Build app ranking, selected-app route totals, and per-app route shares in one
    /// range pass. The dashboard used to walk the same history three times per tick.
    public func overviewRollup(
        from: Date,
        to: Date,
        limit: Int,
        selectedApp: AppIdentityKey?,
        preferredGranularity: BucketGranularity? = nil,
        includeSites: Bool = true,
        cumulativePointLimit: Int = 40
    ) -> TrafficOverviewRollup {
        let (rows, context) = rankingSourceSnapshot(
            from: from,
            to: to,
            preferred: preferredGranularity
        )

        var byApp: [AppIdentityKey: TrafficTotals] = [:]
        var byAppSite: [AppIdentityKey: [String: TrafficTotals]] = [:]
        var routeTotals = RouteDirectionalTotals()
        var routeShares: [AppIdentityKey: AppRouteByteTotals] = [:]
        let pointCount = max(2, cumulativePointLimit)
        var cumulativeUpSteps = Array(repeating: UInt64(0), count: pointCount)
        var cumulativeDownSteps = Array(repeating: UInt64(0), count: pointCount)

        for row in rows {
            let key = row.key
            let totals = row.totals
            byApp[key.app, default: TrafficTotals()].merge(totals)
            if includeSites {
                byAppSite[key.app, default: [:]][key.destinationKey, default: TrafficTotals()].merge(totals)
            }

            if selectedApp == nil || selectedApp == key.app {
                let point = Self.cumulativePointIndex(
                    bucketStartMs: row.bucketStartMs,
                    from: from,
                    to: to,
                    pointCount: pointCount
                )
                cumulativeUpSteps[point] &+= totals.bytesUp
                cumulativeDownSteps[point] &+= totals.bytesDown

                switch key.routeKind {
                case .direct:
                    routeTotals.direct.merge(totals)
                case .systemProxy:
                    routeTotals.systemProxy.merge(totals)
                case .customProxy:
                    routeTotals.customProxy.merge(totals)
                case .unknown, .blocked:
                    routeTotals.unknown.merge(totals)
                }
            }

            let bytes = totals.totalBytes
            guard bytes > 0 else { continue }
            switch key.routeKind {
            case .direct:
                routeShares[key.app, default: AppRouteByteTotals()].direct &+= bytes
            case .systemProxy, .customProxy:
                routeShares[key.app, default: AppRouteByteTotals()].proxied &+= bytes
            case .blocked, .unknown:
                routeShares[key.app, default: AppRouteByteTotals()].unknown &+= bytes
            }
        }

        let hasTraffic = routeTotals.all.totalBytes > 0
        return TrafficOverviewRollup(
            topApps: makeTopApps(
                byApp: byApp,
                byAppSite: byAppSite,
                limit: limit,
                includeSites: includeSites,
                now: Date(),
                context: context
            ),
            routeTotals: routeTotals,
            routeShares: routeShares,
            cumulativeTraffic: hasTraffic
                ? CumulativeTrafficSeries(
                    bytesUp: Self.cumulativeValues(from: cumulativeUpSteps),
                    bytesDown: Self.cumulativeValues(from: cumulativeDownSteps)
                )
                : CumulativeTrafficSeries()
        )
    }

    private static func cumulativePointIndex(
        bucketStartMs: Int64,
        from: Date,
        to: Date,
        pointCount: Int
    ) -> Int {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        let span = max(Int64(1), toMs - fromMs)
        let offset = min(max(Int64(0), bucketStartMs - fromMs), span - 1)
        let progress = Double(offset) / Double(span)
        return min(pointCount - 1, max(1, Int(progress * Double(pointCount - 1)) + 1))
    }

    private static func cumulativeValues(from steps: [UInt64]) -> [UInt64] {
        var running: UInt64 = 0
        return steps.map { value in
            running &+= value
            return running
        }
    }

    private func makeTopApps(
        byApp: [AppIdentityKey: TrafficTotals],
        byAppSite: [AppIdentityKey: [String: TrafficTotals]],
        limit: Int,
        includeSites: Bool,
        now: Date,
        context: RankingContext
    ) -> [AppTrafficSnapshot] {
        return byApp
            .sorted {
                if $0.value.totalBytes != $1.value.totalBytes {
                    return $0.value.totalBytes > $1.value.totalBytes
                }
                return $0.key.storageKey < $1.key.storageKey
            }
            .prefix(max(0, limit))
            .map { app, totals in
                let rates = context.liveRates[app].flatMap {
                    $0.at >= now.addingTimeInterval(-2) ? $0 : nil
                }
                let browser = BrowserIdentity.isBrowser(app)
                let kind = DrillableIdentity.segmentKind(for: app)
                // Include destination breakdown for browsers, IDE projects, AI sessions,
                // or any app that has multiple destination keys in range.
                let destMap = byAppSite[app] ?? [:]
                let shouldBreakDown = includeSites
                    && (browser || DrillableIdentity.isDrillable(app) || destMap.count > 1)
                let sites: [SiteTrafficSnapshot]
                if shouldBreakDown {
                    sites = destMap
                        .filter { $0.key != DestinationKey.unknown || destMap.count == 1 }
                        // A segment with no bytes carries only a flow-open counter and
                        // would read as a destination the app sent nothing to.
                        .filter { $0.value.totalBytes > 0 }
                        .map { dest, siteTotals in
                            SiteTrafficSnapshot(
                                destinationKey: dest,
                                hostname: Self.displayTitle(forDestination: dest),
                                totals: siteTotals,
                                activeConnections: context.activeCountByAppSite[app]?[dest] ?? 0,
                                kind: kind
                            )
                        }
                        .sorted { $0.totals.totalBytes > $1.totals.totalBytes }
                } else {
                    sites = []
                }
                return AppTrafficSnapshot(
                    app: app,
                    displayName: context.displayNames[app] ?? app.signingIdentifier,
                    totals: totals,
                    rateUpBps: rates?.up ?? 0,
                    rateDownBps: rates?.down ?? 0,
                    activeConnections: context.activeCountByApp[app] ?? 0,
                    isBrowser: browser,
                    sites: sites
                )
            }
    }

    /// Per-site rollup for any app (browsers, helpers, or explicit query).
    public func topDestinations(
        for app: AppIdentityKey,
        from: Date,
        to: Date,
        limit: Int = 50,
        preferredGranularity: BucketGranularity? = nil
    ) -> [SiteTrafficSnapshot] {
        lock.lock()
        var rows: [(SlotKey, TrafficTotals)] = []
        forEachBucket(from: from, to: to, preferred: preferredGranularity) { key, totals in
            if key.app == app {
                rows.append((key, totals))
            }
        }
        var activeBySite: [String: Int] = [:]
        for entry in activeFlows.values where entry.app == app {
            activeBySite[entry.destinationKey, default: 0] += 1
        }
        lock.unlock()

        var bySite: [String: TrafficTotals] = [:]
        for (key, totals) in rows {
            bySite[key.destinationKey, default: TrafficTotals()].merge(totals)
        }

        return bySite
            .map { dest, totals in
                SiteTrafficSnapshot(
                    destinationKey: dest,
                    hostname: dest,
                    totals: totals,
                    activeConnections: activeBySite[dest] ?? 0
                )
            }
            .sorted { $0.totals.totalBytes > $1.totals.totalBytes }
            .prefix(limit)
            .map { $0 }
    }

    /// Most recent time this app recorded non-zero byte traffic.
    public func lastTrafficAt(for app: AppIdentityKey) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let stamped = lastTrafficAtByApp[app] {
            return stamped
        }
        // Fallback: newest one-second bucket that carried bytes.
        var latest: Int64 = 0
        for (start, slot) in timeline[0] where start > latest {
            for (key, totals) in slot where key.app == app {
                guard totals.bytesUp > 0 || totals.bytesDown > 0 else { continue }
                latest = start
                break
            }
        }
        guard latest > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(latest) / 1000.0)
    }

    public func liveRateBps() -> (up: Double, down: Double) {
        liveRateBps(for: nil)
    }

    /// Live up/down rates; pass `app` to scope to one process.
    public func liveRateBps(for app: AppIdentityKey?) -> (up: Double, down: Double) {
        lock.lock()
        defer { lock.unlock() }
        var up = 0.0
        var down = 0.0
        let cutoff = Date().addingTimeInterval(-2)
        if let app {
            if let rate = liveRates[app], rate.at >= cutoff {
                return (rate.up, rate.down)
            }
            return (0, 0)
        }
        for (_, rate) in liveRates where rate.at >= cutoff {
            up += rate.up
            down += rate.down
        }
        return (up, down)
    }

    /// Drop all buckets / live state for one app (ranking delete).
    public func purge(app: AppIdentityKey) {
        lock.lock()
        defer { lock.unlock() }
        for index in timeline.indices {
            for (start, slot) in timeline[index] {
                let kept = slot.filter { $0.key.app != app }
                if kept.count == slot.count { continue }
                if kept.isEmpty {
                    timeline[index].removeValue(forKey: start)
                } else {
                    timeline[index][start] = kept
                }
            }
            resetBoundsIfEmpty(index)
        }
        liveRates.removeValue(forKey: app)
        rateBatches.removeValue(forKey: app)
        lastTrafficAtByApp.removeValue(forKey: app)
        activeFlows = activeFlows.filter { $0.value.app != app }
        observedActiveConnectionCounts.removeValue(forKey: app)
        recentConnections.removeAll { $0.app == app }
        appDisplayNames.removeValue(forKey: app)
        bucketRevisions = bucketRevisions.filter { $0.key.slotKey.app != app }
        for index in dirtyBuckets.indices {
            dirtyBuckets[index] = dirtyBuckets[index].filter { $0.slotKey.app != app }
        }
    }

    /// Time series of (up, down) byte totals across buckets in range — for period trend charts.
    public func byteSeries(
        for app: AppIdentityKey?,
        from: Date,
        to: Date,
        points: Int = 24
    ) -> (up: [Double], down: [Double]) {
        lock.lock()
        defer { lock.unlock() }

        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        let spanMs = max(1, toMs - fromMs)
        let n = max(2, points)
        var upBins = Array(repeating: 0.0, count: n)
        var downBins = Array(repeating: 0.0, count: n)

        forEachSlot(from: from, to: to, preferred: nil) { start, slot in
            let idx = min(n - 1, max(0, Int((start - fromMs) * Int64(n) / spanMs)))
            for (key, totals) in slot {
                if let app, key.app != app { continue }
                upBins[idx] += Double(totals.bytesUp)
                downBins[idx] += Double(totals.bytesDown)
            }
        }
        return (upBins, downBins)
    }

    /// Byte share by route kind over a wall-clock range (optionally scoped to one app).
    /// Per-app known-route byte totals split into direct vs proxied, in one pass.
    ///
    /// Backs the per-app "proxy share" label: `proxied` is systemProxy + customProxy
    /// route bytes. Unknown and blocked-route bytes are omitted instead of being
    /// mislabeled as direct.
    public func routeByteShareByApp(
        from: Date,
        to: Date,
        preferredGranularity: BucketGranularity? = nil
    ) -> [AppIdentityKey: (direct: UInt64, proxied: UInt64)] {
        lock.lock()
        defer { lock.unlock() }

        var byApp: [AppIdentityKey: (direct: UInt64, proxied: UInt64)] = [:]
        forEachBucket(from: from, to: to, preferred: preferredGranularity) { key, totals in
            let bytes = totals.totalBytes
            guard bytes > 0 else { return }
            var entry = byApp[key.app] ?? (direct: 0, proxied: 0)
            switch key.routeKind {
            case .systemProxy, .customProxy:
                entry.proxied &+= bytes
            case .direct:
                entry.direct &+= bytes
            case .blocked, .unknown:
                return
            }
            byApp[key.app] = entry
        }
        return byApp
    }

    public func routeByteShare(
        for app: AppIdentityKey?,
        from: Date,
        to: Date
    ) -> (direct: UInt64, systemProxy: UInt64, customProxy: UInt64, blockedFlows: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        var direct: UInt64 = 0
        var system: UInt64 = 0
        var custom: UInt64 = 0
        var blocked: UInt64 = 0

        forEachBucket(from: from, to: to, preferred: nil) { key, totals in
            if let app, key.app != app { return }
            let bytes = totals.totalBytes
            blocked &+= totals.flowsBlocked
            switch key.routeKind {
            case .direct:
                direct &+= bytes
            case .systemProxy:
                system &+= bytes
            case .customProxy:
                custom &+= bytes
            case .blocked, .unknown:
                return
            }
        }
        return (direct, system, custom, blocked)
    }

    /// Upload and download totals split by route over a wall-clock range.
    ///
    /// Unlike `routeByteShare`, this result does not collapse directions into one
    /// percentage. Callers can therefore present asymmetric direct/proxy rates
    /// without applying the same route ratio to upload and download.
    public func routeDirectionalTotals(
        for app: AppIdentityKey?,
        from: Date,
        to: Date,
        preferredGranularity: BucketGranularity? = nil
    ) -> RouteDirectionalTotals {
        lock.lock()
        defer { lock.unlock() }

        var result = RouteDirectionalTotals()
        forEachBucket(from: from, to: to, preferred: preferredGranularity) { key, totals in
            if let app, key.app != app { return }
            switch key.routeKind {
            case .direct:
                result.direct.merge(totals)
            case .systemProxy:
                result.systemProxy.merge(totals)
            case .customProxy:
                result.customProxy.merge(totals)
            case .unknown, .blocked:
                result.unknown.merge(totals)
            }
        }
        return result
    }

    public func recentConnections(limit: Int = 20) -> [LiveConnection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentConnections.prefix(limit))
    }

    public func activeConnectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var counts: [AppIdentityKey: Int] = [:]
        for flow in activeFlows.values {
            counts[flow.app, default: 0] += 1
        }
        for (app, count) in observedActiveConnectionCounts {
            counts[app] = count
        }
        return counts.values.reduce(0, +)
    }

    /// Replace the current OS socket census used for app-level active counts.
    public func setObservedActiveConnectionCounts(_ counts: [AppIdentityKey: Int]) {
        lock.lock()
        defer { lock.unlock() }
        observedActiveConnectionCounts = counts.filter { $0.value > 0 }
    }

    /// Export all buckets for a granularity (for SQLite flush / tests).
    public func exportBuckets(granularity: BucketGranularity) -> [TrafficBucket] {
        lock.lock()
        defer { lock.unlock() }
        var result: [TrafficBucket] = []
        let table = timeline[Self.index(granularity)]
        result.reserveCapacity(table.count)
        for (start, slot) in table {
            for (slotKey, totals) in slot {
                result.append(
                    TrafficBucket(
                        key: TrafficBucketKey(
                            granularity: granularity,
                            bucketStartMs: start,
                            app: slotKey.app,
                            destinationKey: slotKey.destinationKey,
                            routeKind: slotKey.routeKind,
                            transport: slotKey.transport
                        ),
                        totals: totals
                    )
                )
            }
        }
        return result
    }

    /// Export only buckets changed since the persistence consumer last acknowledged
    /// them. This keeps a steady-state flush proportional to new traffic rather than
    /// to all history retained in memory.
    public func exportChangedBuckets(
        granularities: [BucketGranularity]
    ) -> TrafficBucketChangeSet {
        lock.lock()
        defer { lock.unlock() }

        let selected = Set(granularities.map(Self.index))
        var result: [TrafficBucket] = []
        var inspected = 0
        result.reserveCapacity(selected.reduce(0) { $0 + dirtyBuckets[$1].count })

        for index in selected {
            for locator in dirtyBuckets[index] {
                inspected += 1
                guard let totals = timeline[index][locator.bucketStartMs]?[locator.slotKey] else {
                    continue
                }
                let granularity = Self.granularity(atIndex: index)
                result.append(
                    TrafficBucket(
                        key: TrafficBucketKey(
                            granularity: granularity,
                            bucketStartMs: locator.bucketStartMs,
                            app: locator.slotKey.app,
                            destinationKey: locator.slotKey.destinationKey,
                            routeKind: locator.slotKey.routeKind,
                            transport: locator.slotKey.transport
                        ),
                        totals: totals
                    )
                )
            }
        }
        return TrafficBucketChangeSet(
            revision: currentRevision,
            buckets: result,
            inspectedBucketCount: inspected
        )
    }

    /// Mark a successfully persisted change set as clean.
    ///
    /// A bucket written again after `revision` is deliberately retained.
    public func acknowledgeChangedBuckets(
        through revision: UInt64,
        granularities: [BucketGranularity]
    ) {
        lock.lock()
        defer { lock.unlock() }
        let selected = Set(granularities.map(Self.index))
        for index in selected {
            var retained: Set<BucketLocator> = []
            retained.reserveCapacity(dirtyBuckets[index].count)
            for locator in dirtyBuckets[index] {
                if (bucketRevisions[locator] ?? 0) <= revision {
                    bucketRevisions.removeValue(forKey: locator)
                } else {
                    retained.insert(locator)
                }
            }
            dirtyBuckets[index] = retained
        }
    }

    /// Re-queue every retained bucket for one app after its stored rows were
    /// deliberately deleted.
    public func markBucketsChanged(
        for app: AppIdentityKey,
        granularities: [BucketGranularity]
    ) {
        lock.lock()
        defer { lock.unlock() }
        for granularity in granularities {
            let index = Self.index(granularity)
            for (start, slot) in timeline[index] {
                for slotKey in slot.keys where slotKey.app == app {
                    markChanged(index: index, start: start, slotKey: slotKey)
                }
            }
        }
    }

    /// Load persisted buckets back in, so a restart resumes with its history intact.
    ///
    /// Totals are **replaced**, not merged: the caller is restoring a snapshot that
    /// already includes everything recorded for those buckets. Merging would double
    /// every byte that survived the restart.
    ///
    /// Retention applies here too. A caller that restores more history than the policy
    /// keeps would otherwise hold buckets the flusher has already forgotten the
    /// watermark for, and the next flush would write their totals to SQLite a second
    /// time.
    public func importBuckets(_ imported: [TrafficBucket]) {
        lock.lock()
        defer { lock.unlock() }
        for bucket in imported {
            let index = Self.index(bucket.key.granularity)
            let start = bucket.key.bucketStartMs
            let slotKey = SlotKey(
                app: bucket.key.app,
                destinationKey: bucket.key.destinationKey,
                routeKind: bucket.key.routeKind,
                transport: bucket.key.transport
            )
            timeline[index][start, default: [:]][slotKey] = bucket.totals
            if bucket.totals.bytesUp > 0 || bucket.totals.bytesDown > 0 {
                noteTraffic(
                    app: bucket.key.app,
                    at: Date(timeIntervalSince1970: Double(start) / 1_000)
                )
            }
            noteBounds(index: index, start: start)
        }
        for index in timeline.indices {
            evictIfNeeded(index)
        }
    }

    /// Display names known for the apps seen this session (for persistence).
    public func exportDisplayNames() -> [AppIdentityKey: String] {
        lock.lock()
        defer { lock.unlock() }
        return appDisplayNames
    }

    /// Seed display names for apps restored from storage but not yet seen live.
    public func importDisplayNames(_ names: [AppIdentityKey: String]) {
        lock.lock()
        defer { lock.unlock() }
        for (app, name) in names where !name.isEmpty {
            // Never overwrite a name resolved from a live process this session.
            if appDisplayNames[app] == nil {
                appDisplayNames[app] = name
            }
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        timeline = Array(repeating: [:], count: 4)
        newestSlotStart = [.min, .min, .min, .min]
        oldestSlotStart = [.max, .max, .max, .max]
        liveRates.removeAll()
        rateBatches.removeAll()
        bucketRevisions.removeAll()
        dirtyBuckets = Array(repeating: [], count: 4)
        lastTrafficAtByApp.removeAll()
        activeFlows.removeAll()
        observedActiveConnectionCounts.removeAll()
        recentConnections.removeAll()
    }

    /// Buckets currently held in memory, per granularity — retention diagnostics.
    public func bucketCount(granularity: BucketGranularity) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return timeline[Self.index(granularity)].values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Helpers

    public static func chooseGranularity(spanSeconds: Int) -> BucketGranularity {
        switch spanSeconds {
        case ..<120: return .oneSecond
        case ..<7_200: return .oneMinute
        case ..<172_800: return .oneHour
        default: return .oneDay
        }
    }

    public static func bucketStartMs(atMs: Int64, granularity: BucketGranularity) -> Int64 {
        let step = Int64(granularity.seconds) * 1000
        return (atMs / step) * step
    }

    /// Strip synthetic prefixes used in demo/project keys for display.
    public static func displayTitle(forDestination dest: String) -> String {
        // Path segments carry no site name by design; English defaults here, the app
        // layer localizes.
        if dest == DestinationKey.viaProxyNode { return "Via proxy node" }
        if dest == DestinationKey.directByRule { return "Direct by rule" }
        let prefixes = ["project:", "session:", "chat:", "workspace:", "window:"]
        for p in prefixes {
            if dest.lowercased().hasPrefix(p) {
                return String(dest.dropFirst(p.count))
            }
        }
        return dest
    }

    private static func index(_ granularity: BucketGranularity) -> Int {
        switch granularity {
        case .oneSecond: return 0
        case .oneMinute: return 1
        case .oneHour: return 2
        case .oneDay: return 3
        }
    }

    private static func granularity(atIndex index: Int) -> BucketGranularity {
        switch index {
        case 0: return .oneSecond
        case 1: return .oneMinute
        case 2: return .oneHour
        default: return .oneDay
        }
    }

    // MARK: - Storage

    /// Add to (or create) one bucket. Caller holds the lock.
    ///
    /// The nested subscripts mutate in place; pulling the slot out into a local and
    /// writing it back would copy the whole slot on every recorded delta.
    private func mutate(
        granularity: BucketGranularity,
        atMs: Int64,
        slotKey: SlotKey,
        _ body: (inout TrafficTotals) -> Void
    ) {
        let index = Self.index(granularity)
        let start = Self.bucketStartMs(atMs: atMs, granularity: granularity)
        body(&timeline[index][start, default: [:]][slotKey, default: TrafficTotals()])
        markChanged(index: index, start: start, slotKey: slotKey)
        if noteBounds(index: index, start: start) {
            evictIfNeeded(index)
        }
    }

    /// Add byte totals to an exact bucket start. Caller holds the lock.
    private func mutate(
        granularity: BucketGranularity,
        bucketStartMs: Int64,
        slotKey: SlotKey,
        _ body: (inout TrafficTotals) -> Void
    ) {
        let index = Self.index(granularity)
        body(&timeline[index][bucketStartMs, default: [:]][slotKey, default: TrafficTotals()])
        markChanged(index: index, start: bucketStartMs, slotKey: slotKey)
        if noteBounds(index: index, start: bucketStartMs) {
            evictIfNeeded(index)
        }
    }

    private func markChanged(index: Int, start: Int64, slotKey: SlotKey) {
        currentRevision &+= 1
        if currentRevision == 0 { currentRevision = 1 }
        let locator = BucketLocator(index: index, bucketStartMs: start, slotKey: slotKey)
        bucketRevisions[locator] = currentRevision
        dirtyBuckets[index].insert(locator)
    }

    /// Spread a sampled counter delta across every time bucket it actually covered.
    /// This prevents a delayed two-second sample from appearing as two seconds' worth
    /// of bytes in a single instant.
    private func recordBytesAcrossInterval(
        granularity: BucketGranularity,
        endingAtMs: Int64,
        interval: TimeInterval,
        slotKey: SlotKey,
        up: UInt64,
        down: UInt64
    ) {
        let step = Int64(granularity.seconds) * 1_000
        let intervalMs = max(Int64(1), Int64((interval * 1_000).rounded()))
        let startMs = endingAtMs - intervalMs
        let first = Self.bucketStartMs(atMs: startMs, granularity: granularity)
        let last = Self.bucketStartMs(atMs: max(startMs, endingAtMs - 1), granularity: granularity)
        // Materialize only the interval that this long-lived aggregator can retain.
        // A single synthetic "skipped" weight keeps the bytes in retained buckets
        // proportional to the full interval without creating millions of old rows.
        let materialFirst: Int64
        if let retainedSeconds = retention.seconds(for: granularity) {
            let retainedMs = max(Int64(1), Int64((retainedSeconds * 1_000).rounded()))
            let retentionStart = Self.bucketStartMs(
                atMs: endingAtMs - retainedMs,
                granularity: granularity
            )
            materialFirst = max(first, retentionStart)
        } else {
            materialFirst = first
        }

        var starts: [Int64] = []
        var weights: [UInt64] = []
        let materialCount = max(Int64(1), (last - materialFirst) / step + 1)
        starts.reserveCapacity(Int(materialCount))
        weights.reserveCapacity(Int(materialCount))
        var bucketStart = materialFirst
        while bucketStart <= last {
            let overlapStart = max(startMs, bucketStart)
            let overlapEnd = min(endingAtMs, bucketStart + step)
            if overlapEnd > overlapStart {
                starts.append(bucketStart)
                weights.append(UInt64(overlapEnd - overlapStart))
            }
            bucketStart += step
        }

        let skippedDuration = max(Int64(0), materialFirst - startMs)
        let hasSkippedDuration = skippedDuration > 0
        let allocationWeights = hasSkippedDuration
            ? [UInt64(skippedDuration)] + weights
            : weights
        let allUpParts = ProportionalByteAllocator.split(total: up, weights: allocationWeights)
        let allDownParts = ProportionalByteAllocator.split(total: down, weights: allocationWeights)
        let partOffset = hasSkippedDuration ? 1 : 0
        for index in starts.indices {
            let partUp = allUpParts[index + partOffset]
            let partDown = allDownParts[index + partOffset]
            guard partUp > 0 || partDown > 0 else { continue }
            mutate(granularity: granularity, bucketStartMs: starts[index], slotKey: slotKey) { totals in
                totals.bytesUp &+= partUp
                totals.bytesDown &+= partDown
            }
        }
    }

    private func updateLiveRate(
        app: AppIdentityKey,
        up: UInt64,
        down: UInt64,
        at: Date,
        sampleInterval: TimeInterval?
    ) {
        if let previous = liveRates[app], at < previous.at {
            return
        }
        let duration = sampleInterval.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? 1
        let atMs = Int64((at.timeIntervalSince1970 * 1_000).rounded(.down))
        let key: Int64
        if sampleInterval == nil {
            key = Self.bucketStartMs(atMs: atMs, granularity: .oneSecond)
        } else {
            key = atMs
        }
        var batch: RateBatch
        if let existing = rateBatches[app],
           existing.key == key,
           abs(existing.duration - duration) < 0.000_001 {
            batch = existing
            batch.up &+= up
            batch.down &+= down
        } else {
            batch = RateBatch(key: key, duration: duration, up: up, down: down)
        }
        rateBatches[app] = batch
        liveRates[app] = (
            up: Double(batch.up) / batch.duration,
            down: Double(batch.down) / batch.duration,
            at: at
        )
    }

    /// Track the newest / oldest bucket start. Returns true when the newest advanced,
    /// which is the only moment retention can newly expire something.
    @discardableResult
    private func noteBounds(index: Int, start: Int64) -> Bool {
        if start < oldestSlotStart[index] { oldestSlotStart[index] = start }
        guard start > newestSlotStart[index] else { return false }
        newestSlotStart[index] = start
        return true
    }

    private func resetBoundsIfEmpty(_ index: Int) {
        guard timeline[index].isEmpty else { return }
        newestSlotStart[index] = .min
        oldestSlotStart[index] = .max
    }

    /// Drop buckets older than the retention window for this granularity.
    private func evictIfNeeded(_ index: Int) {
        let granularity = Self.granularity(atIndex: index)
        guard let window = retention.seconds(for: granularity) else { return }
        let newest = newestSlotStart[index]
        guard newest != .min else { return }
        let cutoff = newest - Int64(window * 1000)
        guard oldestSlotStart[index] < cutoff else { return }

        var oldest = Int64.max
        var removedStarts: Set<Int64> = []
        timeline[index] = timeline[index].filter { start, _ in
            guard start >= cutoff else {
                removedStarts.insert(start)
                return false
            }
            if start < oldest { oldest = start }
            return true
        }
        if !removedStarts.isEmpty {
            bucketRevisions = bucketRevisions.filter {
                $0.key.index != index || !removedStarts.contains($0.key.bucketStartMs)
            }
            dirtyBuckets[index] = dirtyBuckets[index].filter {
                !removedStarts.contains($0.bucketStartMs)
            }
        }
        oldestSlotStart[index] = oldest
        resetBoundsIfEmpty(index)
    }

    private func noteTraffic(app: AppIdentityKey, at: Date) {
        if let previous = lastTrafficAtByApp[app] {
            if at > previous { lastTrafficAtByApp[app] = at }
        } else {
            lastTrafficAtByApp[app] = at
        }
    }

    // MARK: - Range iteration

    /// Copy only the rows and small pieces of live state needed for a ranking.
    /// Dictionary aggregation, sorting, and snapshot construction happen after the
    /// lock is released so ingestion and persistence are never blocked by UI work.
    private func rankingSourceSnapshot(
        from: Date,
        to: Date,
        preferred: BucketGranularity?
    ) -> (rows: [TimedBucketRow], context: RankingContext) {
        lock.lock()
        defer { lock.unlock() }

        var rows: [TimedBucketRow] = []
        forEachSlot(from: from, to: to, preferred: preferred) { bucketStartMs, slot in
            for (key, totals) in slot {
                rows.append(
                    TimedBucketRow(
                        bucketStartMs: bucketStartMs,
                        key: key,
                        totals: totals
                    )
                )
            }
        }

        var activeCountByApp: [AppIdentityKey: Int] = [:]
        var activeCountByAppSite: [AppIdentityKey: [String: Int]] = [:]
        for entry in activeFlows.values {
            activeCountByApp[entry.app, default: 0] += 1
            activeCountByAppSite[entry.app, default: [:]][entry.destinationKey, default: 0] += 1
        }
        for (app, count) in observedActiveConnectionCounts {
            activeCountByApp[app] = max(0, count)
        }

        return (
            rows,
            RankingContext(
                displayNames: appDisplayNames,
                liveRates: liveRates.mapValues {
                    LiveRateSnapshot(up: $0.up, down: $0.down, at: $0.at)
                },
                activeCountByApp: activeCountByApp,
                activeCountByAppSite: activeCountByAppSite
            )
        )
    }

    /// Visit every bucket overlapping `[from, to)` at the granularity that best fits
    /// the span. Caller holds the lock.
    ///
    /// The predicate matches what a full scan used to apply: a bucket counts when its
    /// window ends after `from` and it starts before `to`.
    private func forEachSlot(
        from: Date,
        to: Date,
        preferred: BucketGranularity?,
        _ body: (Int64, Slot) -> Void
    ) {
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        guard toMs > 0 else { return }
        let spanSec = max(1, Int(to.timeIntervalSince1970 - from.timeIntervalSince1970))
        let granularity = preferred ?? Self.chooseGranularity(spanSeconds: spanSec)
        let index = Self.index(granularity)
        let table = timeline[index]
        guard !table.isEmpty else { return }

        let step = Int64(granularity.seconds) * 1000
        let first = Self.bucketStartMs(atMs: fromMs, granularity: granularity)
        let last = Self.bucketStartMs(atMs: toMs - 1, granularity: granularity)
        guard last >= first else { return }

        // Walking the range is the point: it costs the number of buckets asked for,
        // not the number retained. When the range is wider than the whole table,
        // iterating the table is cheaper.
        let slotsInRange = (last - first) / step + 1
        if slotsInRange <= Int64(table.count) {
            var start = first
            while start <= last {
                if let slot = table[start] { body(start, slot) }
                start += step
            }
        } else {
            for (start, slot) in table where start >= first && start <= last {
                body(start, slot)
            }
        }
    }

    /// Every bucket in range, flattened. Rollups only ever look at the slot key, so
    /// the granularity and start time are not rebuilt into a full `TrafficBucketKey`.
    private func forEachBucket(
        from: Date,
        to: Date,
        preferred: BucketGranularity?,
        _ body: (SlotKey, TrafficTotals) -> Void
    ) {
        forEachSlot(from: from, to: to, preferred: preferred) { _, slot in
            for (slotKey, totals) in slot {
                body(slotKey, totals)
            }
        }
    }

    private func protocolLabel(_ flow: FlowDescriptor) -> String {
        switch flow.transport {
        case .tcp:
            if flow.remotePort == 443 { return "HTTPS" }
            if flow.remotePort == 80 { return "HTTP" }
            return "TCP"
        case .udp: return "UDP"
        case .any, .other: return "OTHER"
        }
    }
}
