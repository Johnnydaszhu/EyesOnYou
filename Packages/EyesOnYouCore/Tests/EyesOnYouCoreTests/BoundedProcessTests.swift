import XCTest
@testable import EyesOnYouCore

final class BoundedProcessTests: XCTestCase {
    func testCapturesOutputFromCompletedProcess() {
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["ready"],
            timeout: 1
        )

        XCTAssertEqual(result?.terminationStatus, 0)
        XCTAssertEqual(result?.timedOut, false)
        XCTAssertEqual(result.flatMap { String(data: $0.stdout, encoding: .utf8) }, "ready")
    }

    func testTerminatesProcessAtDeadline() {
        let started = Date()
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            timeout: 0.05
        )

        XCTAssertEqual(result?.timedOut, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testLargeStderrCannotBlockCompletion() {
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 12000 ]; do echo diagnostic >&2; i=$((i+1)); done; printf done",
            ],
            timeout: 1
        )

        XCTAssertEqual(result?.timedOut, false)
        XCTAssertEqual(result?.terminationStatus, 0)
        XCTAssertEqual(result.flatMap { String(data: $0.stdout, encoding: .utf8) }, "done")
    }
}
