import XCTest
@testable import EyesOnYouCore

final class HostNetworkSamplerTests: XCTestCase {
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
}
