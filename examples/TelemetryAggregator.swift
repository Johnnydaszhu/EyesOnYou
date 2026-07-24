import Foundation
import os

public struct FlowCounters: Sendable {
    public var lastUp: UInt64 = 0
    public var lastDown: UInt64 = 0
    public var totalUp: UInt64 = 0
    public var totalDown: UInt64 = 0
}

public struct CounterDelta: Sendable {
    public let up: UInt64
    public let down: UInt64
}

public final class ShardedFlowRegistry: @unchecked Sendable {
    private final class Shard: @unchecked Sendable {
        let state = OSAllocatedUnfairLock(initialState: [UUID: FlowCounters]())
    }

    private let shards: [Shard]

    public init(shardCount: Int = 32) {
        precondition(shardCount > 0 && shardCount.nonzeroBitCount == 1)
        self.shards = (0..<shardCount).map { _ in Shard() }
    }

    private func shard(for id: UUID) -> Shard {
        var uuid = id.uuid
        let hash = withUnsafeBytes(of: &uuid) { raw -> UInt64 in
            raw.loadUnaligned(as: UInt64.self)
        }
        return shards[Int(hash) & (shards.count - 1)]
    }

    /// Converts a latest cumulative counter report into a delta.
    /// A lower value is treated as a provider/system reset, not a negative delta.
    public func update(id: UUID, cumulativeUp: UInt64, cumulativeDown: UInt64) -> CounterDelta {
        shard(for: id).state.withLock { table in
            var state = table[id, default: FlowCounters()]
            let up = cumulativeUp >= state.lastUp ? cumulativeUp - state.lastUp : cumulativeUp
            let down = cumulativeDown >= state.lastDown ? cumulativeDown - state.lastDown : cumulativeDown
            state.lastUp = cumulativeUp
            state.lastDown = cumulativeDown
            state.totalUp &+= up
            state.totalDown &+= down
            table[id] = state
            return CounterDelta(up: up, down: down)
        }
    }

    public func remove(id: UUID) -> FlowCounters? {
        shard(for: id).state.withLock { $0.removeValue(forKey: id) }
    }
}
