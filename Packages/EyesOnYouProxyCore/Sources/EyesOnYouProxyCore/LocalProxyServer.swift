import Foundation
import Network
import EyesOnYouCore

/// A loopback HTTP proxy that enforces per-app route rules.
///
/// Flow of one connection:
/// 1. accept on 127.0.0.1 → the peer port identifies the client process,
/// 2. read the CONNECT / absolute-form head,
/// 3. resolve the owning app and ask ``LocalProxyRules`` what to do,
/// 4. block, dial the origin directly, or hand off to an upstream proxy,
/// 5. splice bytes both ways, accounting every byte to the app + destination.
///
/// This is the enforcement layer: turning it on and pointing the system proxy at it
/// is what makes "Chrome must use the proxy / bilibili stays direct" actually happen,
/// rather than only labeling traffic.
public final class LocalProxyServer: @unchecked Sendable {
    public struct FlowEvent: Sendable {
        public let app: AppIdentityKey
        public let displayName: String
        public let host: String
        public let port: UInt16
        public let action: ProxyFlowAction
        public let bytesUp: UInt64
        public let bytesDown: UInt64
        public let startedAt: Date
        public let endedAt: Date
    }

    public enum State: Equatable, Sendable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    private let rulesBox: LocalProxyRulesBox
    private let ownerResolver: ConnectionOwnerResolver
    private let queue = DispatchQueue(label: "com.eyesonyou.localproxy", attributes: .concurrent)
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var _state: State = .stopped
    private let onFlow: @Sendable (FlowEvent) -> Void
    private let onState: @Sendable (State) -> Void
    private let nowProvider: @Sendable () -> Date

    public init(
        rules: LocalProxyRulesBox,
        ownerResolver: ConnectionOwnerResolver = ConnectionOwnerResolver(),
        now: @escaping @Sendable () -> Date = { Date() },
        onFlow: @escaping @Sendable (FlowEvent) -> Void = { _ in },
        onState: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.rulesBox = rules
        self.ownerResolver = ownerResolver
        self.nowProvider = now
        self.onFlow = onFlow
        self.onState = onState
    }

    public var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private func setState(_ new: State) {
        stateLock.lock()
        _state = new
        stateLock.unlock()
        onState(new)
    }

    /// Start listening on a loopback port (0 = kernel-assigned).
    public func start(preferredPort: UInt16 = 0) {
        stop()
        let params = NWParameters.tcp
        // Loopback only: never expose the proxy to the network.
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            if preferredPort != 0, let port = NWEndpoint.Port(rawValue: preferredPort) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            setState(.failed("listener: \(error)"))
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    self.setState(.running(port: port))
                }
            case .failed(let error):
                self.setState(.failed("\(error)"))
            case .cancelled:
                self.setState(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        // The client's ephemeral source port is our key into the owner index.
        let clientPort: UInt16? = {
            if case let .hostPort(_, port) = connection.endpoint { return port.rawValue }
            return nil
        }()
        connection.start(queue: queue)
        readHead(connection, buffer: Data(), clientPort: clientPort)
    }

    private func readHead(_ client: NWConnection, buffer: Data, clientPort: UInt16?) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                _ = error
                client.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            // Guard against an unbounded head from a hostile / non-HTTP client.
            if buffer.count > 128 * 1024 {
                client.cancel()
                return
            }

            switch ProxyRequestHead.parse(buffer: buffer) {
            case nil:
                if isComplete { client.cancel(); return }
                self.readHead(client, buffer: buffer, clientPort: clientPort)
            case .failure:
                self.respondAndClose(client, "HTTP/1.1 400 Bad Request\r\n\r\n")
            case .success(let head):
                self.route(client: client, head: head, clientPort: clientPort)
            }
        }
    }

    private func route(client: NWConnection, head: ProxyRequestHead, clientPort: UInt16?) {
        let rules = rulesBox.current
        let owner = clientPort.flatMap { ownerResolver.owner(clientPort: $0) }
        let app = owner?.app ?? AppIdentityKey(teamIdentifier: nil, signingIdentifier: "unknown")
        let displayName = owner?.displayName ?? "Unknown"
        let action = rules.action(for: app, host: head.host, port: head.port)
        let startedAt = nowProvider()

        let accounting = ByteAccounting()
        // One flow reports exactly once. Both the splice teardown and the target
        // connection's own `.cancelled` state fire on close, and without this guard
        // the same bytes were emitted — and counted — twice.
        let reported = OnceFlag()
        let finish: @Sendable () -> Void = { [weak self] in
            guard let self, reported.tryset() else { return }
            let (up, down) = accounting.totals()
            self.onFlow(FlowEvent(
                app: app,
                displayName: displayName,
                host: head.host,
                port: head.port,
                action: action,
                bytesUp: up,
                bytesDown: down,
                startedAt: startedAt,
                endedAt: self.nowProvider()
            ))
        }

        switch action {
        case .block:
            finish()
            respondAndClose(client, "HTTP/1.1 403 Forbidden\r\n\r\n")
        case .direct:
            openDirect(client: client, head: head, accounting: accounting, onClose: finish)
        case .upstream(let upstream) where upstream.kind == .http:
            openHTTPUpstream(client: client, head: head, upstream: upstream,
                             accounting: accounting, onClose: finish)
        case .upstream(let upstream):
            openSOCKSUpstream(client: client, head: head, upstream: upstream,
                              accounting: accounting, onClose: finish)
        }
    }

    // MARK: - Direct

    private func openDirect(
        client: NWConnection,
        head: ProxyRequestHead,
        accounting: ByteAccounting,
        onClose: @escaping @Sendable () -> Void
    ) {
        guard let port = NWEndpoint.Port(rawValue: head.port) else { onClose(); return }
        let target = NWConnection(
            host: NWEndpoint.Host(head.host),
            port: port,
            using: .tcp
        )
        target.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                switch head.kind {
                case .connect:
                    self.confirmConnect(client) {
                        if !head.remainder.isEmpty {
                            self.forward(head.remainder, to: target, count: nil)
                        }
                        self.splice(client, target, accounting: accounting, onClose: onClose)
                    }
                case .httpForward:
                    // Origin servers accept absolute-form (RFC 7230); forward as-is.
                    self.forward(head.rawHead + head.remainder, to: target, count: accounting.recordUp)
                    self.splice(client, target, accounting: accounting, onClose: onClose)
                }
            case .failed, .cancelled:
                onClose()
                client.cancel()
                target.cancel()
            default:
                break
            }
        }
        target.start(queue: queue)
    }

    // MARK: - HTTP upstream

    private func openHTTPUpstream(
        client: NWConnection,
        head: ProxyRequestHead,
        upstream: ProxyUpstream,
        accounting: ByteAccounting,
        onClose: @escaping @Sendable () -> Void
    ) {
        guard let port = NWEndpoint.Port(rawValue: upstream.port) else { onClose(); return }
        let up = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: .tcp)
        up.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Replay the client's exact head to the upstream proxy — a CONNECT
                // stays a CONNECT, an absolute-form GET stays absolute-form.
                self.forward(head.rawHead + head.remainder, to: up, count: accounting.recordUp)
                self.splice(client, up, accounting: accounting, onClose: onClose)
            case .failed, .cancelled:
                onClose()
                client.cancel()
                up.cancel()
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    // MARK: - SOCKS5 upstream

    private func openSOCKSUpstream(
        client: NWConnection,
        head: ProxyRequestHead,
        upstream: ProxyUpstream,
        accounting: ByteAccounting,
        onClose: @escaping @Sendable () -> Void
    ) {
        guard let port = NWEndpoint.Port(rawValue: upstream.port) else { onClose(); return }
        let up = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: .tcp)
        up.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                SOCKS5Handshake.perform(on: up, host: head.host, port: head.port, queue: self.queue) {
                    success in
                    guard success else {
                        onClose(); client.cancel(); up.cancel(); return
                    }
                    switch head.kind {
                    case .connect:
                        self.confirmConnect(client) {
                            if !head.remainder.isEmpty {
                                self.forward(head.remainder, to: up, count: accounting.recordUp)
                            }
                            self.splice(client, up, accounting: accounting, onClose: onClose)
                        }
                    case .httpForward:
                        self.forward(head.rawHead + head.remainder, to: up, count: accounting.recordUp)
                        self.splice(client, up, accounting: accounting, onClose: onClose)
                    }
                }
            } else if case .failed = state {
                onClose(); client.cancel(); up.cancel()
            }
        }
        up.start(queue: queue)
    }

    // MARK: - Plumbing

    private func confirmConnect(_ client: NWConnection, then: @escaping @Sendable () -> Void) {
        client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in then() })
    }

    private func forward(_ data: Data, to conn: NWConnection, count: ((Int) -> Void)?) {
        guard !data.isEmpty else { return }
        count?(data.count)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Bidirectional copy until either side closes; totals recorded via `accounting`.
    private func splice(
        _ a: NWConnection,
        _ b: NWConnection,
        accounting: ByteAccounting,
        onClose: @escaping @Sendable () -> Void
    ) {
        let closed = OnceFlag()
        let shutdown: @Sendable () -> Void = {
            guard closed.tryset() else { return }
            // Let the peer drain what is already queued before tearing down, so a
            // response that arrived with the FIN is not lost.
            a.cancel()
            b.cancel()
            onClose()
        }
        // a→b is client→origin (upload); b→a is origin→client (download).
        pump(from: a, to: b, record: accounting.recordUp, onEnd: shutdown)
        pump(from: b, to: a, record: accounting.recordDown, onEnd: shutdown)
    }

    private func pump(
        from: NWConnection,
        to: NWConnection,
        record: @escaping (Int) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            if let data, !data.isEmpty {
                record(data.count)
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                onEnd()
                return
            }
            self.pump(from: from, to: to, record: record, onEnd: onEnd)
        }
    }

    private func respondAndClose(_ client: NWConnection, _ response: String) {
        client.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            client.cancel()
        })
    }
}

// MARK: - Small concurrency helpers

/// Thread-safe up/down byte counters for one flow.
final class ByteAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var up: UInt64 = 0
    private var down: UInt64 = 0

    func recordUp(_ n: Int) { lock.lock(); up &+= UInt64(max(0, n)); lock.unlock() }
    func recordDown(_ n: Int) { lock.lock(); down &+= UInt64(max(0, n)); lock.unlock() }
    func totals() -> (UInt64, UInt64) { lock.lock(); defer { lock.unlock() }; return (up, down) }
}

/// One-shot flag so paired teardown runs exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
