import Foundation
import EyesOnYouCore

/// Writes an in-memory aggregator into SQLite repeatedly without double counting.
///
/// `TelemetryAggregator` holds *cumulative* totals per bucket and `mergeBucket` adds
/// to what is already stored, so flushing the same bucket twice would count its bytes
/// twice. This keeps a watermark of what has already been written per bucket and
/// sends only the difference.
///
/// The watermark lives in memory only, which is correct across restarts: a fresh
/// process starts with an empty aggregator, so its first deltas are exactly the new
/// traffic, and the rows already in SQLite keep everything from before.
public final class TelemetryFlusher: @unchecked Sendable {
    /// Granularities worth persisting. Second-level buckets are deliberately excluded
    /// — they exist for live rate charts and would dominate the database.
    public static let persistedGranularities: [BucketGranularity] = [.oneMinute, .oneHour, .oneDay]

    private let store: TelemetryStore
    private let granularities: [BucketGranularity]
    private var written: [TrafficBucketKey: TrafficTotals] = [:]
    /// Names already sent to the catalog, so a steady state writes nothing.
    private var namesWritten: [AppIdentityKey: String] = [:]
    private let lock = NSLock()

    public init(
        store: TelemetryStore,
        granularities: [BucketGranularity] = TelemetryFlusher.persistedGranularities
    ) {
        self.store = store
        self.granularities = granularities
    }

    /// Record buckets restored from storage as already written.
    ///
    /// Must be called with whatever was imported into the aggregator; otherwise the
    /// first flush would re-add the restored history on top of itself.
    public func seed(with buckets: [TrafficBucket]) {
        lock.lock()
        defer { lock.unlock() }
        for bucket in buckets {
            written[bucket.key] = bucket.totals
        }
    }

    /// Persist everything recorded since the last flush.
    /// - Returns: number of bucket rows written.
    @discardableResult
    public func flush(_ aggregator: TelemetryAggregator) throws -> Int {
        // Keep snapshot selection, persistence, and watermark advancement serialized.
        // Advancing only after the transaction commits makes a failed batch retryable.
        lock.lock()
        defer { lock.unlock() }

        // Persist product names alongside the counters; without this the catalog only
        // ever holds bundle identifiers and every reader has to re-resolve them.
        let pendingNames = aggregator.exportDisplayNames()
            .filter { !$0.value.isEmpty && namesWritten[$0.key] != $0.value }

        for (app, name) in pendingNames {
            _ = try store.upsertApp(app, displayName: name)
            namesWritten[app] = name
        }

        let changes = aggregator.exportChangedBuckets(granularities: granularities)
        var pending: [TrafficBucket] = []
        var committedTotals: [TrafficBucketKey: TrafficTotals] = [:]
        pending.reserveCapacity(changes.buckets.count)
        committedTotals.reserveCapacity(changes.buckets.count)

        for bucket in changes.buckets {
            let previous = written[bucket.key] ?? TrafficTotals()
            if let delta = Self.delta(current: bucket.totals, previous: previous) {
                pending.append(TrafficBucket(key: bucket.key, totals: delta))
            }
            committedTotals[bucket.key] = bucket.totals
        }

        if !pending.isEmpty {
            try store.mergeBuckets(pending)
        }
        for (key, totals) in committedTotals {
            written[key] = totals
        }
        aggregator.acknowledgeChangedBuckets(
            through: changes.revision,
            granularities: granularities
        )
        return pending.count
    }

    /// Forget watermarks only after their buckets have left the aggregator.
    ///
    /// Time-based cleanup is unsafe because each granularity has a different
    /// retention window. Dropping a watermark while its cumulative bucket still
    /// exists makes the next flush merge that entire bucket into SQLite again.
    @discardableResult
    public func forgetWatermarks(notPresentIn aggregator: TelemetryAggregator) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var retainedKeys = Set<TrafficBucketKey>()
        for granularity in granularities {
            retainedKeys.formUnion(
                aggregator.exportBuckets(granularity: granularity).map(\.key)
            )
        }
        let previousCount = written.count
        written = written.filter { retainedKeys.contains($0.key) }
        return previousCount - written.count
    }

    /// Forget one app after its persisted rows were deliberately deleted.
    ///
    /// This is explicit rather than presence-based because an app can create fresh
    /// traffic again before the asynchronous deletion transaction finishes.
    @discardableResult
    public func forgetWatermarks(for app: AppIdentityKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return forgetWatermarksLocked(for: app)
    }

    /// Serialize deletion with older queued flushes, then re-queue any traffic that
    /// arrived after the in-memory purge so it cannot be acknowledged and erased.
    @discardableResult
    public func deleteApp(
        _ app: AppIdentityKey,
        preservingCurrentBucketsIn aggregator: TelemetryAggregator
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let deleted = try store.deleteApp(app)
        _ = forgetWatermarksLocked(for: app)
        aggregator.markBucketsChanged(for: app, granularities: granularities)
        return deleted
    }

    private func forgetWatermarksLocked(for app: AppIdentityKey) -> Int {
        let previousCount = written.count
        written = written.filter { $0.key.app != app }
        namesWritten.removeValue(forKey: app)
        return previousCount - written.count
    }

    /// Difference between two cumulative snapshots, or `nil` when nothing changed.
    ///
    /// A counter should never decrease; if one somehow does (a bucket rebuilt after a
    /// reset), treat that field as unchanged rather than writing a negative delta.
    static func delta(current: TrafficTotals, previous: TrafficTotals) -> TrafficTotals? {
        let result = TrafficTotals(
            bytesUp: current.bytesUp > previous.bytesUp ? current.bytesUp - previous.bytesUp : 0,
            bytesDown: current.bytesDown > previous.bytesDown ? current.bytesDown - previous.bytesDown : 0,
            flowsOpened: current.flowsOpened > previous.flowsOpened
                ? current.flowsOpened - previous.flowsOpened : 0,
            flowsClosed: current.flowsClosed > previous.flowsClosed
                ? current.flowsClosed - previous.flowsClosed : 0,
            flowsBlocked: current.flowsBlocked > previous.flowsBlocked
                ? current.flowsBlocked - previous.flowsBlocked : 0
        )
        let isEmpty = result.bytesUp == 0 && result.bytesDown == 0
            && result.flowsOpened == 0 && result.flowsClosed == 0 && result.flowsBlocked == 0
        return isEmpty ? nil : result
    }
}
