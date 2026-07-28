import Darwin
import Foundation

public struct BoundedProcessResult: Sendable {
    public let stdout: Data
    public let terminationStatus: Int32
    public let timedOut: Bool
}

/// Runs a helper process with a real wall-clock deadline.
///
/// Output is drained concurrently so a verbose child cannot fill its pipe and
/// deadlock before termination. A timed-out child receives TERM, then KILL.
public enum BoundedProcess {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func store(_ data: Data) {
            lock.lock()
            value = data
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        mergeStderrIntoStdout: Bool = false
    ) -> BoundedProcessResult? {
        guard timeout > 0, timeout.isFinite else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = mergeStderrIntoStdout ? outputPipe : FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        let outputFinished = DispatchSemaphore(value: 0)
        let output = DataBox()
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        DispatchQueue.global(qos: .utility).async {
            output.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            outputFinished.signal()
        }

        var timedOut = false
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if terminated.wait(timeout: .now() + 0.25) == .timedOut {
                let pid = process.processIdentifier
                if pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
                _ = terminated.wait(timeout: .now() + 1)
            }
        }

        guard !process.isRunning else { return nil }
        _ = outputFinished.wait(timeout: .now() + 1)
        return BoundedProcessResult(
            stdout: output.load(),
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }
}
