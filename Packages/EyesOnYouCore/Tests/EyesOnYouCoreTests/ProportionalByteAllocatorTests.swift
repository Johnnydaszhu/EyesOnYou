import XCTest
@testable import EyesOnYouCore

final class ProportionalByteAllocatorTests: XCTestCase {
    func testSplitConservesEveryByteWithUnevenWeights() {
        let parts = ProportionalByteAllocator.split(total: 1_073_741_824, weights: [1, 3, 7])

        XCTAssertEqual(parts.reduce(0, &+), 1_073_741_824)
        XCTAssertGreaterThan(parts[2], parts[1])
        XCTAssertGreaterThan(parts[1], parts[0])
    }

    func testSplitConservesEveryByteWhenTotalIsSmallerThanWeightCount() {
        let parts = ProportionalByteAllocator.split(total: 2, weights: [1, 1, 1, 1])

        XCTAssertEqual(parts.reduce(0, &+), 2)
        XCTAssertEqual(parts.filter { $0 > 0 }.count, 2)
    }

    func testZeroWeightNeverReceivesBytes() {
        let parts = ProportionalByteAllocator.split(total: 99, weights: [0, 2, 0, 1])

        XCTAssertEqual(parts, [0, 66, 0, 33])
    }

    func testZeroTotalAndZeroWeightsStayZero() {
        XCTAssertEqual(
            ProportionalByteAllocator.split(total: 0, weights: [1, 2]),
            [0, 0]
        )
        XCTAssertEqual(
            ProportionalByteAllocator.split(total: 10, weights: [0, 0]),
            [0, 0]
        )
    }

    func testSplitConservesUInt64MaximumWithoutFloatingPointLoss() {
        let parts = ProportionalByteAllocator.split(
            total: UInt64.max,
            weights: [UInt64.max / 3, UInt64.max / 3, UInt64.max / 3]
        )

        XCTAssertEqual(parts.reduce(0, &+), UInt64.max)
        XCTAssertLessThanOrEqual(parts.max()! - parts.min()!, 1)
    }
}
