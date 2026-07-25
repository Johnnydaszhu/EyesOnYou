import Foundation

#if canImport(os)
import os
#endif

public struct FlowCounters: Sendable, Equatable {
    public var lastUp: UInt64 = 0
    public var lastDown: UInt64 = 0
    public var totalUp: UInt64 = 0
    public var totalDown: UInt64 = 0

    public init(
        lastUp: UInt64 = 0,
        lastDown: UInt64 = 0,
        totalUp: UInt64 = 0,
        totalDown: UInt64 = 0
    ) {
        self.lastUp = lastUp
        self.lastDown = lastDown
        self.totalUp = totalUp
        self.totalDown = totalDown
    }
}

public struct CounterDelta: Sendable, Equatable {
    public let up: UInt64
    public let down: UInt64

    public init(up: UInt64, down: UInt64) {
        self.up = up
        self.down = down
    }
}

/// Converts cumulative provider reports into non-negative deltas.
/// A lower cumulative value is treated as a reset, not a negative delta.
public enum CounterMath {
    public static func delta(
        previous: UInt64,
        cumulative: UInt64
    ) -> UInt64 {
        cumulative >= previous ? cumulative &- previous : cumulative
    }
}

/// Sharded in-memory registry of per-flow counters (hot path).
public final class ShardedFlowRegistry: @unchecked Sendable {
    private final class Shard: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [UUID: FlowCounters] = [:]

        func withLock<T>(_ body: (inout [UUID: FlowCounters]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&table)
        }
    }

    private let shards: [Shard]
    private let shardMask: Int

    public init(shardCount: Int = 32) {
        precondition(shardCount > 0 && shardCount.nonzeroBitCount == 1, "shardCount must be power of two")
        self.shards = (0..<shardCount).map { _ in Shard() }
        self.shardMask = shardCount - 1
    }

    private func shard(for id: UUID) -> Shard {
        var uuid = id.uuid
        let hash = withUnsafeBytes(of: &uuid) { raw -> UInt64 in
            raw.loadUnaligned(as: UInt64.self)
        }
        // Mask before converting to Int — full UInt64 can set the sign bit and trap.
        return shards[Int(hash & UInt64(shardMask))]
    }

    /// Updates counters from a latest cumulative report and returns the delta.
    public func update(id: UUID, cumulativeUp: UInt64, cumulativeDown: UInt64) -> CounterDelta {
        shard(for: id).withLock { table in
            var state = table[id, default: FlowCounters()]
            let up = CounterMath.delta(previous: state.lastUp, cumulative: cumulativeUp)
            let down = CounterMath.delta(previous: state.lastDown, cumulative: cumulativeDown)
            state.lastUp = cumulativeUp
            state.lastDown = cumulativeDown
            state.totalUp &+= up
            state.totalDown &+= down
            table[id] = state
            return CounterDelta(up: up, down: down)
        }
    }

    public func remove(id: UUID) -> FlowCounters? {
        shard(for: id).withLock { $0.removeValue(forKey: id) }
    }

    public func counters(for id: UUID) -> FlowCounters? {
        shard(for: id).withLock { $0[id] }
    }
}
