import Foundation

/// Splits a byte delta across weighted consumers without creating or losing bytes.
///
/// Socket attribution only has connection counts as weights. Those weights are an
/// estimate, but the accounting invariant is exact: every input byte appears in
/// exactly one output slot.
public enum ProportionalByteAllocator {
    public static func split(total: UInt64, weights: [UInt64]) -> [UInt64] {
        guard !weights.isEmpty else { return [] }

        let totalWeight = weights.reduce(UInt64(0)) { partial, weight in
            partial.addingReportingOverflow(weight).overflow ? UInt64.max : partial &+ weight
        }
        guard total > 0, totalWeight > 0 else {
            return Array(repeating: 0, count: weights.count)
        }

        var remainingBytes = total
        var remainingWeight = totalWeight
        var result = Array(repeating: UInt64(0), count: weights.count)

        for index in weights.indices {
            let weight = weights[index]
            guard weight > 0, remainingBytes > 0 else {
                if weight <= remainingWeight { remainingWeight -= weight }
                continue
            }

            let part: UInt64
            if weight >= remainingWeight {
                part = remainingBytes
            } else {
                // Full-width integer division keeps large counters exact too:
                // floor(remainingBytes × weight ÷ remainingWeight).
                let product = remainingBytes.multipliedFullWidth(by: weight)
                part = min(remainingBytes, remainingWeight.dividingFullWidth(product).quotient)
            }
            result[index] = part
            remainingBytes -= part
            remainingWeight -= weight
        }

        // A saturated weight sum can leave a remainder. Give it to the largest
        // positive consumer rather than dropping it.
        if remainingBytes > 0,
           let recipient = weights.indices
            .filter({ weights[$0] > 0 })
            .max(by: { weights[$0] < weights[$1] }) {
            result[recipient] &+= remainingBytes
        }
        return result
    }
}
