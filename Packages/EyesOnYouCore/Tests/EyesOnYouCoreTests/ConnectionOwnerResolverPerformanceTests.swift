import XCTest
@testable import EyesOnYouCore

final class ConnectionOwnerResolverPerformanceTests: XCTestCase {
    func testSuccessfulEmptyKernelCensusDoesNotLaunchLsof() {
        var lsofReads = 0
        let rows = ConnectionOwnerResolver.loopbackClients(
            readSocketTable: { .success([]) },
            readLsof: {
                lsofReads += 1
                return [(pid: 42, localPort: 50_000)]
            }
        )

        XCTAssertEqual(rows.count, 0)
        XCTAssertEqual(lsofReads, 0)
    }

    func testKernelFailureUsesBoundedFallbackResult() {
        var lsofReads = 0
        let rows = ConnectionOwnerResolver.loopbackClients(
            readSocketTable: { .failure },
            readLsof: {
                lsofReads += 1
                return [(pid: 42, localPort: 50_000)]
            }
        )

        XCTAssertEqual(rows.first?.pid, 42)
        XCTAssertEqual(rows.first?.localPort, 50_000)
        XCTAssertEqual(lsofReads, 1)
    }

    func testConcurrentMissesShareRebuilds() {
        let samples = LockedInt()
        let resolver = ConnectionOwnerResolver(refreshInterval: 60) {
            samples.increment()
            Thread.sleep(forTimeInterval: 0.02)
            return []
        }
        let group = DispatchGroup()
        let now = Date()
        for port in UInt16(50_000)..<UInt16(50_008) {
            group.enter()
            DispatchQueue.global().async {
                _ = resolver.owner(clientPort: port, now: now)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertLessThanOrEqual(samples.value, 2)
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
