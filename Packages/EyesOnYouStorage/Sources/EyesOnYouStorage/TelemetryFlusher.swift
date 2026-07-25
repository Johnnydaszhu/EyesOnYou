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
        // Persist product names alongside the counters; without this the catalog only
        // ever holds bundle identifiers and every reader has to re-resolve them.
        lock.lock()
        let pendingNames = aggregator.exportDisplayNames()
            .filter { !$0.value.isEmpty && namesWritten[$0.key] != $0.value }
        lock.unlock()

        for (app, name) in pendingNames {
            _ = try store.upsertApp(app, displayName: name)
            lock.lock()
            namesWritten[app] = name
            lock.unlock()
        }

        var pending: [TrafficBucket] = []

        lock.lock()
        for granularity in granularities {
            for bucket in aggregator.exportBuckets(granularity: granularity) {
                let previous = written[bucket.key] ?? TrafficTotals()
                guard let delta = Self.delta(current: bucket.totals, previous: previous) else {
                    continue
                }
                pending.append(TrafficBucket(key: bucket.key, totals: delta))
                written[bucket.key] = bucket.totals
            }
        }
        lock.unlock()

        for bucket in pending {
            try store.mergeBucket(bucket)
        }
        return pending.count
    }

    /// Forget watermarks for buckets that ended before `cutoff`.
    ///
    /// Without this the map grows for every minute the app stays open.
    public func forgetWatermarks(endedBefore cutoff: Date) {
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)
        lock.lock()
        defer { lock.unlock() }
        written = written.filter { key, _ in
            key.bucketStartMs + Int64(key.granularity.seconds) * 1000 >= cutoffMs
        }
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
