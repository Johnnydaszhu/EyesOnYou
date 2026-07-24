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

private struct ActiveFlowState: Sendable {
    let app: AppIdentityKey
    let openedAt: Date
    let destinationKey: String
}

/// In-memory multi-granularity traffic aggregator.
/// Call sites feed open / stats-delta / close events; queries roll up ranges.
/// Buckets are keyed by app **and** destination so browsers can split by website.
public final class TelemetryAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var buckets: [TrafficBucketKey: TrafficTotals] = [:]
    private var appDisplayNames: [AppIdentityKey: String] = [:]
    private var liveRates: [AppIdentityKey: (up: Double, down: Double, at: Date)] = [:]
    private var activeFlows: [UUID: ActiveFlowState] = [:]
    private var recentConnections: [LiveConnection] = []
    private let maxRecentConnections: Int

    public init(maxRecentConnections: Int = 100) {
        self.maxRecentConnections = maxRecentConnections
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
        for granularity in BucketGranularity.allCases {
            let key = makeKey(
                granularity: granularity,
                atMs: nowMs,
                app: flow.app,
                destinationKey: dest,
                route: route,
                transport: flow.transport
            )
            var totals = buckets[key, default: TrafficTotals()]
            totals.flowsOpened &+= 1
            if firewall == .block {
                totals.flowsBlocked &+= 1
            }
            buckets[key] = totals
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
        destinationKey: String? = nil
    ) {
        guard up > 0 || down > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        let dest = destinationKey
            ?? activeFlows[flowID]?.destinationKey
            ?? DestinationKey.unknown

        let nowMs = Int64(at.timeIntervalSince1970 * 1000)
        for granularity in BucketGranularity.allCases {
            let key = makeKey(
                granularity: granularity,
                atMs: nowMs,
                app: app,
                destinationKey: dest,
                route: route,
                transport: transport
            )
            var totals = buckets[key, default: TrafficTotals()]
            totals.bytesUp &+= up
            totals.bytesDown &+= down
            buckets[key] = totals
        }

        let rateKey = makeKey(
            granularity: .oneSecond,
            atMs: nowMs,
            app: app,
            destinationKey: dest,
            route: route,
            transport: transport
        )
        // App-level rate: sum all destinations for this second bucket set is expensive;
        // accumulate on liveRates by merging app-wide second totals via scan.
        var upSum: UInt64 = 0
        var downSum: UInt64 = 0
        let bucketStart = Self.bucketStartMs(atMs: nowMs, granularity: .oneSecond)
        for (key, totals) in buckets {
            guard key.granularity == .oneSecond,
                  key.app == app,
                  key.bucketStartMs == bucketStart else { continue }
            upSum &+= totals.bytesUp
            downSum &+= totals.bytesDown
        }
        liveRates[app] = (up: Double(upSum), down: Double(downSum), at: at)
        _ = rateKey
    }

    public func recordClose(
        flowID: UUID,
        app: AppIdentityKey,
        at: Date = Date(),
        finalUp: UInt64 = 0,
        finalDown: UInt64 = 0,
        route: RouteAction = .direct,
        transport: TransportProtocol = .tcp,
        destinationKey: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        let dest = destinationKey
            ?? activeFlows[flowID]?.destinationKey
            ?? DestinationKey.unknown
        activeFlows.removeValue(forKey: flowID)

        let nowMs = Int64(at.timeIntervalSince1970 * 1000)
        for granularity in BucketGranularity.allCases {
            let key = makeKey(
                granularity: granularity,
                atMs: nowMs,
                app: app,
                destinationKey: dest,
                route: route,
                transport: transport
            )
            var totals = buckets[key, default: TrafficTotals()]
            if finalUp > 0 || finalDown > 0 {
                totals.bytesUp &+= finalUp
                totals.bytesDown &+= finalDown
            }
            totals.flowsClosed &+= 1
            buckets[key] = totals
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

        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        let spanSec = max(1, Int((to.timeIntervalSince1970 - from.timeIntervalSince1970)))
        let granularity = preferredGranularity ?? Self.chooseGranularity(spanSeconds: spanSec)

        var result = TrafficTotals()
        for (key, totals) in buckets {
            guard key.granularity == granularity else { continue }
            if let app, key.app != app { continue }
            if key.bucketStartMs + Int64(granularity.seconds) * 1000 <= fromMs { continue }
            if key.bucketStartMs >= toMs { continue }
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
        lock.lock()
        defer { lock.unlock() }

        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        let spanSec = max(1, Int((to.timeIntervalSince1970 - from.timeIntervalSince1970)))
        let granularity = preferredGranularity ?? Self.chooseGranularity(spanSeconds: spanSec)

        var byApp: [AppIdentityKey: TrafficTotals] = [:]
        var byAppSite: [AppIdentityKey: [String: TrafficTotals]] = [:]
        for (key, totals) in buckets {
            guard key.granularity == granularity else { continue }
            if key.bucketStartMs + Int64(granularity.seconds) * 1000 <= fromMs { continue }
            if key.bucketStartMs >= toMs { continue }
            byApp[key.app, default: TrafficTotals()].merge(totals)
            byAppSite[key.app, default: [:]][key.destinationKey, default: TrafficTotals()].merge(totals)
        }

        let activeCountByApp: [AppIdentityKey: Int] = {
            var counts: [AppIdentityKey: Int] = [:]
            for entry in activeFlows.values {
                counts[entry.app, default: 0] += 1
            }
            return counts
        }()
        let activeCountByAppSite: [AppIdentityKey: [String: Int]] = {
            var counts: [AppIdentityKey: [String: Int]] = [:]
            for entry in activeFlows.values {
                counts[entry.app, default: [:]][entry.destinationKey, default: 0] += 1
            }
            return counts
        }()

        return byApp
            .map { app, totals in
                let rates = liveRates[app]
                let browser = BrowserIdentity.isBrowser(app)
                let kind = DrillableIdentity.segmentKind(for: app)
                // Include destination breakdown for browsers, IDE projects, AI sessions,
                // or any app that has multiple destination keys in range.
                let destMap = byAppSite[app] ?? [:]
                let shouldBreakDown = includeSitesForBrowsers
                    && (browser || DrillableIdentity.isDrillable(app) || destMap.count > 1)
                let sites: [SiteTrafficSnapshot]
                if shouldBreakDown {
                    sites = destMap
                        .filter { $0.key != DestinationKey.unknown || destMap.count == 1 }
                        .map { dest, siteTotals in
                            SiteTrafficSnapshot(
                                destinationKey: dest,
                                hostname: Self.displayTitle(forDestination: dest),
                                totals: siteTotals,
                                activeConnections: activeCountByAppSite[app]?[dest] ?? 0,
                                kind: kind
                            )
                        }
                        .sorted { $0.totals.totalBytes > $1.totals.totalBytes }
                } else {
                    sites = []
                }
                return AppTrafficSnapshot(
                    app: app,
                    displayName: appDisplayNames[app] ?? app.signingIdentifier,
                    totals: totals,
                    rateUpBps: rates?.up ?? 0,
                    rateDownBps: rates?.down ?? 0,
                    activeConnections: activeCountByApp[app] ?? 0,
                    isBrowser: browser,
                    sites: sites
                )
            }
            .sorted { $0.totals.totalBytes > $1.totals.totalBytes }
            .prefix(limit)
            .map { $0 }
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
        defer { lock.unlock() }

        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        let spanSec = max(1, Int((to.timeIntervalSince1970 - from.timeIntervalSince1970)))
        let granularity = preferredGranularity ?? Self.chooseGranularity(spanSeconds: spanSec)

        var bySite: [String: TrafficTotals] = [:]
        for (key, totals) in buckets {
            guard key.granularity == granularity, key.app == app else { continue }
            if key.bucketStartMs + Int64(granularity.seconds) * 1000 <= fromMs { continue }
            if key.bucketStartMs >= toMs { continue }
            bySite[key.destinationKey, default: TrafficTotals()].merge(totals)
        }

        var activeBySite: [String: Int] = [:]
        for entry in activeFlows.values where entry.app == app {
            activeBySite[entry.destinationKey, default: 0] += 1
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

    public func liveRateBps() -> (up: Double, down: Double) {
        lock.lock()
        defer { lock.unlock() }
        var up = 0.0
        var down = 0.0
        let cutoff = Date().addingTimeInterval(-2)
        for (_, rate) in liveRates where rate.at >= cutoff {
            up += rate.up
            down += rate.down
        }
        return (up, down)
    }

    public func recentConnections(limit: Int = 20) -> [LiveConnection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentConnections.prefix(limit))
    }

    public func activeConnectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeFlows.count
    }

    /// Export all buckets for a granularity (for SQLite flush / tests).
    public func exportBuckets(granularity: BucketGranularity) -> [TrafficBucket] {
        lock.lock()
        defer { lock.unlock() }
        return buckets
            .filter { $0.key.granularity == granularity }
            .map { TrafficBucket(key: $0.key, totals: $0.value) }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buckets.removeAll()
        liveRates.removeAll()
        activeFlows.removeAll()
        recentConnections.removeAll()
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
        let prefixes = ["project:", "session:", "chat:", "workspace:"]
        for p in prefixes {
            if dest.lowercased().hasPrefix(p) {
                return String(dest.dropFirst(p.count))
            }
        }
        return dest
    }

    private func makeKey(
        granularity: BucketGranularity,
        atMs: Int64,
        app: AppIdentityKey,
        destinationKey: String,
        route: RouteAction,
        transport: TransportProtocol
    ) -> TrafficBucketKey {
        TrafficBucketKey(
            granularity: granularity,
            bucketStartMs: Self.bucketStartMs(atMs: atMs, granularity: granularity),
            app: app,
            destinationKey: destinationKey,
            routeKind: RouteKind(action: route),
            transport: transport
        )
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
