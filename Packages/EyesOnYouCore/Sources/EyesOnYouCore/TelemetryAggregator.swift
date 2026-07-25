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
    /// Last wall-clock time bytes were recorded for an app (does not expire with live rates).
    private var lastTrafficAtByApp: [AppIdentityKey: Date] = [:]
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
        if let previous = lastTrafficAtByApp[app] {
            if at > previous { lastTrafficAtByApp[app] = at }
        } else {
            lastTrafficAtByApp[app] = at
        }
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
        if finalUp > 0 || finalDown > 0 {
            if let previous = lastTrafficAtByApp[app] {
                if at > previous { lastTrafficAtByApp[app] = at }
            } else {
                lastTrafficAtByApp[app] = at
            }
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
                        // A segment with no bytes carries only a flow-open counter and
                        // would read as a destination the app sent nothing to.
                        .filter { $0.value.totalBytes > 0 }
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

    /// Most recent time this app recorded non-zero byte traffic.
    public func lastTrafficAt(for app: AppIdentityKey) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let stamped = lastTrafficAtByApp[app] {
            return stamped
        }
        // Fallback: newest one-second bucket that carried bytes.
        var latest: Int64 = 0
        for (key, totals) in buckets {
            guard key.app == app, key.granularity == .oneSecond else { continue }
            guard totals.bytesUp > 0 || totals.bytesDown > 0 else { continue }
            if key.bucketStartMs > latest {
                latest = key.bucketStartMs
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
        buckets = buckets.filter { $0.key.app != app }
        liveRates.removeValue(forKey: app)
        lastTrafficAtByApp.removeValue(forKey: app)
        activeFlows = activeFlows.filter { $0.value.app != app }
        recentConnections.removeAll { $0.app == app }
        appDisplayNames.removeValue(forKey: app)
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

        let spanSec = max(1, Int(to.timeIntervalSince1970 - from.timeIntervalSince1970))
        let granularity = Self.chooseGranularity(spanSeconds: spanSec)

        for (key, totals) in buckets {
            guard key.granularity == granularity else { continue }
            if let app, key.app != app { continue }
            if key.bucketStartMs + Int64(granularity.seconds) * 1000 <= fromMs { continue }
            if key.bucketStartMs >= toMs { continue }
            let idx = min(n - 1, max(0, Int((key.bucketStartMs - fromMs) * Int64(n) / spanMs)))
            upBins[idx] += Double(totals.bytesUp)
            downBins[idx] += Double(totals.bytesDown)
        }
        return (upBins, downBins)
    }

    /// Byte share by route kind over a wall-clock range (optionally scoped to one app).
    /// Per-app byte totals split into direct vs proxied, in one pass over the buckets.
    ///
    /// Backs the per-app "proxy share" label: `proxied` is systemProxy + customProxy
    /// route bytes, `direct` is everything else the app actually moved.
    public func routeByteShareByApp(
        from: Date,
        to: Date,
        preferredGranularity: BucketGranularity? = nil
    ) -> [AppIdentityKey: (direct: UInt64, proxied: UInt64)] {
        lock.lock()
        defer { lock.unlock() }

        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        let spanSec = max(1, Int(to.timeIntervalSince1970 - from.timeIntervalSince1970))
        let granularity = preferredGranularity ?? Self.chooseGranularity(spanSeconds: spanSec)

        var byApp: [AppIdentityKey: (direct: UInt64, proxied: UInt64)] = [:]
        for (key, totals) in buckets {
            guard key.granularity == granularity else { continue }
            if key.bucketStartMs + Int64(granularity.seconds) * 1000 <= fromMs { continue }
            if key.bucketStartMs >= toMs { continue }
            let bytes = totals.totalBytes
            guard bytes > 0 else { continue }
            var entry = byApp[key.app] ?? (direct: 0, proxied: 0)
            switch key.routeKind {
            case .systemProxy, .customProxy:
                entry.proxied &+= bytes
            case .direct, .blocked, .unknown:
                entry.direct &+= bytes
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

        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)
        let spanSec = max(1, Int(to.timeIntervalSince1970 - from.timeIntervalSince1970))
        let granularity = Self.chooseGranularity(spanSeconds: spanSec)

        var direct: UInt64 = 0
        var system: UInt64 = 0
        var custom: UInt64 = 0
        var blocked: UInt64 = 0

        for (key, totals) in buckets {
            guard key.granularity == granularity else { continue }
            if let app, key.app != app { continue }
            if key.bucketStartMs + Int64(granularity.seconds) * 1000 <= fromMs { continue }
            if key.bucketStartMs >= toMs { continue }
            let bytes = totals.totalBytes
            blocked &+= totals.flowsBlocked
            switch key.routeKind {
            case .direct, .unknown:
                direct &+= bytes
            case .systemProxy:
                system &+= bytes
            case .customProxy:
                custom &+= bytes
            case .blocked:
                // Blocked path still counts under share as non-routed; fold into direct for mix UI.
                direct &+= bytes
            }
        }
        return (direct, system, custom, blocked)
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

    /// Load persisted buckets back in, so a restart resumes with its history intact.
    ///
    /// Totals are **replaced**, not merged: the caller is restoring a snapshot that
    /// already includes everything recorded for those buckets. Merging would double
    /// every byte that survived the restart.
    public func importBuckets(_ imported: [TrafficBucket]) {
        lock.lock()
        defer { lock.unlock() }
        for bucket in imported {
            buckets[bucket.key] = bucket.totals
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
        buckets.removeAll()
        liveRates.removeAll()
        lastTrafficAtByApp.removeAll()
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
