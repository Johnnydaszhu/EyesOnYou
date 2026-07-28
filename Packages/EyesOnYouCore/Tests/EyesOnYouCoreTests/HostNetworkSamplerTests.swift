import XCTest
@testable import EyesOnYouCore

final class HostNetworkSamplerTests: XCTestCase {
    private final class SnapshotSource {
        private var snapshots: [[HostNetworkSampler.InterfaceCounters]]
        private var index = 0

        init(_ snapshots: [[HostNetworkSampler.InterfaceCounters]]) {
            self.snapshots = snapshots
        }

        func next() -> [HostNetworkSampler.InterfaceCounters] {
            let snapshot = snapshots[min(index, snapshots.count - 1)]
            index += 1
            return snapshot
        }
    }

    private func interface(
        _ name: String,
        incoming: UInt64,
        outgoing: UInt64,
        isUp: Bool = true
    ) -> HostNetworkSampler.InterfaceCounters {
        HostNetworkSampler.InterfaceCounters(
            name: name,
            bytesIn: incoming,
            bytesOut: outgoing,
            isUp: isUp
        )
    }

    func testCurrentCountersReadable() {
        let counters = HostNetworkSampler.currentCounters()
        // Fresh macOS hosts almost always have non-zero cumulative iface counters.
        // Don't assert magnitude — just that the call is safe.
        _ = counters.bytesIn &+ counters.bytesOut
    }

    func testSampleRatesPrimesThenReports() {
        let sampler = HostNetworkSampler()
        let first = sampler.sampleRates()
        XCTAssertEqual(first.downBps, 0, accuracy: 0.001)
        XCTAssertEqual(first.upBps, 0, accuracy: 0.001)

        // Second sample after a short wait should be well-formed (may still be ~0 if idle).
        Thread.sleep(forTimeInterval: 0.3)
        let second = sampler.sampleRates()
        XCTAssertGreaterThanOrEqual(second.downBps, 0)
        XCTAssertGreaterThanOrEqual(second.upBps, 0)
    }

    func testPhysicalInterfaceDoesNotAddTunnelOrSideChannelAcrossTwoIntervals() {
        let source = SnapshotSource([
            [
                interface("en0", incoming: 100, outgoing: 200),
                interface("utun4", incoming: 1_000, outgoing: 2_000),
                interface("awdl0", incoming: 3_000, outgoing: 4_000),
            ],
            [
                interface("en0", incoming: 160, outgoing: 225),
                interface("utun4", incoming: 11_000, outgoing: 22_000),
                interface("awdl0", incoming: 33_000, outgoing: 44_000),
            ],
            [
                interface("en0", incoming: 190, outgoing: 275),
                interface("utun4", incoming: 111_000, outgoing: 222_000),
                interface("awdl0", incoming: 333_000, outgoing: 444_000),
            ],
        ])
        let sampler = HostNetworkSampler(counterProvider: source.next)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(sampler.sampleRates(now: start), .init())

        let first = sampler.sampleRates(now: start.addingTimeInterval(1))
        XCTAssertEqual(first.deltaIn, 60)
        XCTAssertEqual(first.deltaOut, 25)
        XCTAssertEqual(first.downBps, 60, accuracy: 0.001)
        XCTAssertEqual(first.upBps, 25, accuracy: 0.001)

        let second = sampler.sampleRates(now: start.addingTimeInterval(2))
        XCTAssertEqual(second.deltaIn, 30)
        XCTAssertEqual(second.deltaOut, 50)
        XCTAssertEqual(second.downBps, 30, accuracy: 0.001)
        XCTAssertEqual(second.upBps, 50, accuracy: 0.001)
    }

    func testThirtyTwoBitCounterWrapProducesSmallDelta() {
        let maximum = UInt64(UInt32.max)
        let source = SnapshotSource([
            [interface("en0", incoming: maximum - 5, outgoing: maximum - 10)],
            [interface("en0", incoming: 7, outgoing: 4)],
        ])
        let sampler = HostNetworkSampler(counterProvider: source.next)
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        XCTAssertEqual(sampler.sampleRates(now: start), .init())
        let rates = sampler.sampleRates(now: start.addingTimeInterval(1))

        XCTAssertEqual(rates.deltaIn, 13)
        XCTAssertEqual(rates.deltaOut, 15)
    }

    func testCounterResetDoesNotLookLikeWrap() {
        let source = SnapshotSource([
            [interface("en0", incoming: 10_000, outgoing: 20_000)],
            [interface("en0", incoming: 10, outgoing: 20)],
        ])
        let sampler = HostNetworkSampler(counterProvider: source.next)
        let start = Date(timeIntervalSinceReferenceDate: 3_000)

        XCTAssertEqual(sampler.sampleRates(now: start), .init())
        XCTAssertEqual(
            sampler.sampleRates(now: start.addingTimeInterval(1)),
            .init()
        )
    }

    func testNewInterfaceStartsAtBaselineAndRemovedInterfaceStopsContributing() {
        let source = SnapshotSource([
            [interface("en0", incoming: 100, outgoing: 200)],
            [
                interface("en0", incoming: 130, outgoing: 240),
                interface("en5", incoming: 10_000, outgoing: 20_000),
            ],
            [interface("en5", incoming: 10_020, outgoing: 20_030)],
        ])
        let sampler = HostNetworkSampler(counterProvider: source.next)
        let start = Date(timeIntervalSinceReferenceDate: 4_000)

        XCTAssertEqual(sampler.sampleRates(now: start), .init())

        let added = sampler.sampleRates(now: start.addingTimeInterval(1))
        XCTAssertEqual(added.deltaIn, 30)
        XCTAssertEqual(added.deltaOut, 40)

        let removed = sampler.sampleRates(now: start.addingTimeInterval(2))
        XCTAssertEqual(removed.deltaIn, 20)
        XCTAssertEqual(removed.deltaOut, 30)
    }

    func testShortIntervalDoesNotConsumeCountersBeforeNextRealSample() {
        let source = SnapshotSource([
            [interface("en0", incoming: 100, outgoing: 200)],
            [interface("en0", incoming: 150, outgoing: 240)],
            [interface("en0", incoming: 220, outgoing: 290)],
        ])
        let sampler = HostNetworkSampler(counterProvider: source.next)
        let start = Date(timeIntervalSinceReferenceDate: 4_500)

        XCTAssertEqual(sampler.sampleRates(now: start), .init())
        XCTAssertEqual(
            sampler.sampleRates(now: start.addingTimeInterval(0.1)),
            .init()
        )

        let rates = sampler.sampleRates(now: start.addingTimeInterval(1))
        XCTAssertEqual(rates.deltaIn, 120)
        XCTAssertEqual(rates.deltaOut, 90)
    }

    func testDisappearedInterfaceDoesNotReplayItsLifetimeCounterWhenItReturns() {
        let source = SnapshotSource([
            [interface("en0", incoming: 100, outgoing: 200)],
            [],
            [interface("en0", incoming: 1_000, outgoing: 2_000)],
        ])
        let sampler = HostNetworkSampler(counterProvider: source.next)
        let start = Date(timeIntervalSinceReferenceDate: 5_000)

        XCTAssertEqual(sampler.sampleRates(now: start), .init())
        XCTAssertEqual(
            sampler.sampleRates(now: start.addingTimeInterval(1)),
            .init()
        )
        XCTAssertEqual(
            sampler.sampleRates(now: start.addingTimeInterval(2)),
            .init()
        )
    }

    func testAggregateIncludesOnlyUpPhysicalInterfaces() {
        let counters = HostNetworkSampler.aggregatePhysicalCounters([
            interface("en0", incoming: 100, outgoing: 200),
            interface("en7", incoming: 300, outgoing: 400),
            interface("en8", incoming: 500, outgoing: 600, isUp: false),
            interface("utun4", incoming: 1_000, outgoing: 2_000),
            interface("awdl0", incoming: 3_000, outgoing: 4_000),
            interface("llw0", incoming: 5_000, outgoing: 6_000),
        ])

        XCTAssertEqual(counters, .init(bytesIn: 400, bytesOut: 600))
    }
}
