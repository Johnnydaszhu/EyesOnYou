import Foundation
import Network
import NetworkExtension
import EyesOnYouCore
import EyesOnYouProxyCore
import EyesOnYouIPC

/// Moves one claimed TCP flow between the app and its destination (direct dial or
/// via an upstream proxy), counting exact bytes both ways.
///
/// Lifecycle: `start(plan:)` opens the flow, dials, optionally handshakes
/// (HTTP CONNECT / SOCKS5), then runs both copy loops until either side ends.
/// Every exit path funnels through `finish(action:)` exactly once, which closes
/// both ends and reports the measured sample to the runtime — so a flow can never
/// leak or double-report.
final class TCPFlowPump: @unchecked Sendable {
    private static let startupTimeout: TimeInterval = 30

    private let flow: NEAppProxyTCPFlow
    private let app: AppIdentityKey
    private let host: String
    private let port: UInt16
    private let runtime: ExtensionRuntime
    private let queue = DispatchQueue(label: "eyesonyou.flow.pump")

    private let lock = NSLock()
    private var bytesUp: UInt64 = 0
    private var bytesDown: UInt64 = 0
    private var finished = false
    private var copying = false
    private var connection: NWConnection?

    init(flow: NEAppProxyTCPFlow, app: AppIdentityKey, host: String, port: UInt16, runtime: ExtensionRuntime) {
        self.flow = flow
        self.app = app
        self.host = host
        self.port = port
        self.runtime = runtime
    }

    /// `physicalInterface`: the non-tunnel interface force-direct dials bind to,
    /// so "direct" cannot re-enter a TUN-mode proxy.
    func start(plan: TransparentFlowPlan, physicalInterface: NWInterface?) {
        runtime.flowStarted()
        queue.asyncAfter(deadline: .now() + Self.startupTimeout) { [weak self] in
            self?.finishIfStillStarting()
        }
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                self.finish(action: "refused")
                return
            }
            guard !self.isFinished else { return }
            switch plan {
            case .dialDirect:
                self.dialDirect(physicalInterface: physicalInterface)
            case .dialUpstream(let upstream):
                self.dialUpstream(upstream)
            case .block:
                self.finish(action: "block")
            case .refuse, .decline:
                // decline never reaches a pump; refuse = explicit proxy route with
                // no upstream — fail closed, never silently direct.
                self.finish(action: "refused")
            }
        }
    }

    // MARK: - Dial

    private func dialDirect(physicalInterface: NWInterface?) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            finish(action: "refused")
            return
        }
        // Loopback targets must stay unscoped — pinning them to the physical
        // interface would make every localhost dial unroutable.
        let params: NWParameters = SocketTable.isLoopback(host)
            ? .tcp
            : LocalProxyServer.directDialParameters(physicalInterface: physicalInterface)
        open(NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)) { [weak self] _ in
            self?.pump(action: "direct")
        }
    }

    private func dialUpstream(_ upstream: ProxyUpstream) {
        guard let upstreamPort = NWEndpoint.Port(rawValue: upstream.port) else {
            finish(action: "refused")
            return
        }
        // The upstream is usually the local proxy client (loopback); a remote
        // upstream riding the normal stack (including a VPN) is fine too.
        let connection = NWConnection(
            host: NWEndpoint.Host(upstream.host),
            port: upstreamPort,
            using: .tcp
        )
        open(connection) { [weak self] connection in
            guard let self else { return }
            switch upstream.kind {
            case .http:
                HTTPConnectHandshake.perform(
                    on: connection, host: self.host, port: self.port, queue: self.queue
                ) { remainder in
                    guard let remainder else {
                        self.finish(action: "refused")
                        return
                    }
                    if !remainder.isEmpty {
                        self.writeToFlow(remainder)
                    }
                    self.pump(action: "upstream")
                }
            case .socks5:
                SOCKS5Handshake.perform(
                    on: connection, host: self.host, port: self.port, queue: self.queue
                ) { ok in
                    guard ok else {
                        self.finish(action: "refused")
                        return
                    }
                    self.pump(action: "upstream")
                }
            }
        }
    }

    private func open(
        _ connection: NWConnection,
        ready: @escaping @Sendable (NWConnection) -> Void
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let connection else {
                    self.finish(action: "refused")
                    return
                }
                // Break the connection → handler → ready closure chain as soon as
                // the dial completes. Handshake callbacks own only what they need.
                connection.stateUpdateHandler = nil
                guard !self.isFinished else {
                    connection.cancel()
                    return
                }
                ready(connection)
            case .failed, .cancelled:
                connection?.stateUpdateHandler = nil
                self.finish(action: "refused")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Copy loops

    private func pump(action: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        copying = true
        lock.unlock()
        readFromApp(action: action)
        readFromDestination(action: action)
    }

    private func readFromApp(action: String) {
        flow.readData { [weak self] data, error in
            guard let self, let connection = self.currentConnection() else { return }
            if error != nil {
                self.finish(action: action)
                return
            }
            guard let data, !data.isEmpty else {
                // App finished sending — half-close toward the destination.
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in })
                return
            }
            self.add(up: UInt64(data.count))
            connection.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil {
                    self.finish(action: action)
                } else {
                    self.readFromApp(action: action)
                }
            })
        }
    }

    private func readFromDestination(action: String) {
        guard let connection = currentConnection() else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.add(down: UInt64(data.count))
                self.flow.write(data) { writeError in
                    if writeError != nil || error != nil {
                        self.finish(action: action)
                    } else if isComplete {
                        self.finish(action: action)
                    } else {
                        self.readFromDestination(action: action)
                    }
                }
                return
            }
            if isComplete || error != nil {
                self.finish(action: action)
            } else {
                self.readFromDestination(action: action)
            }
        }
    }

    private func writeToFlow(_ data: Data) {
        add(down: UInt64(data.count))
        flow.write(data) { _ in }
    }

    // MARK: - Accounting / teardown

    private func currentConnection() -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        return connection
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// A provider can otherwise retain a pump forever while flow opening, dialing,
    /// or an upstream handshake waits for a callback that never arrives.
    private func finishIfStillStarting() {
        lock.lock()
        let shouldFinish = !finished && !copying
        lock.unlock()
        if shouldFinish {
            finish(action: "refused")
        }
    }

    func cancel() {
        finish(action: "refused")
    }

    private func add(up: UInt64 = 0, down: UInt64 = 0) {
        lock.lock()
        bytesUp &+= up
        bytesDown &+= down
        lock.unlock()
    }

    private func finish(action: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let sample = FlowEventSample(
            signingIdentifier: app.signingIdentifier,
            host: host,
            port: port,
            action: action,
            bytesUp: bytesUp,
            bytesDown: bytesDown
        )
        let connection = self.connection
        self.connection = nil
        lock.unlock()

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        runtime.flowFinished(sample)
        PumpRegistry.shared.remove(self)
    }
}

/// Keeps pumps alive for the duration of their flow (NE gives us no ownership).
final class PumpRegistry: @unchecked Sendable {
    static let shared = PumpRegistry()
    private let lock = NSLock()
    private var storage: [ObjectIdentifier: TCPFlowPump] = [:]

    func add(_ pump: TCPFlowPump) {
        lock.lock()
        storage[ObjectIdentifier(pump)] = pump
        lock.unlock()
    }

    func remove(_ pump: TCPFlowPump) {
        lock.lock()
        storage[ObjectIdentifier(pump)] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let pumps = Array(storage.values)
        storage.removeAll(keepingCapacity: false)
        lock.unlock()
        for pump in pumps {
            pump.cancel()
        }
    }
}
