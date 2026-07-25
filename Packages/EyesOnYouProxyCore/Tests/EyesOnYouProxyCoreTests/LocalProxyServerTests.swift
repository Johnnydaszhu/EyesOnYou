import XCTest
import Network
import EyesOnYouCore
import EyesOnYouRuleEngine
@testable import EyesOnYouProxyCore

/// Exercises the real listener end to end over loopback: a tiny origin server, the
/// proxy under test, and a raw client socket speaking HTTP CONNECT.
final class LocalProxyServerTests: XCTestCase {
    private let testApp = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.test.Client")

    /// Trivial TCP echo-ish origin that returns a fixed body once it receives anything.
    private final class TinyOrigin {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        let response: Data
        private let queue = DispatchQueue(label: "origin")

        init(response: Data) throws {
            self.response = response
            listener = try NWListener(using: .tcp)
        }

        func start() {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state, let p = self.listener.port?.rawValue {
                    self.port = p
                    ready.signal()
                }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: self.queue)
                self.serve(conn)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 2)
        }

        private func serve(_ conn: NWConnection) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, done, _ in
                conn.send(content: self.response, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                _ = done
            }
        }

        func stop() { listener.cancel() }
    }

    /// Start a server whose owner index is empty, so every client resolves to the
    /// "unknown" app — which is what the rules under test are written against.
    private func makeServer(
        rules: LocalProxyRules,
        onFlow: @escaping @Sendable (LocalProxyServer.FlowEvent) -> Void
    ) -> (server: LocalProxyServer, port: UInt16) {
        let boundPort = LockedBox<UInt16>(0)
        let ready = DispatchSemaphore(value: 0)
        let server = LocalProxyServer(
            rules: LocalProxyRulesBox(rules),
            ownerResolver: ConnectionOwnerResolver(refreshInterval: 0) { [] },
            onFlow: onFlow,
            onState: { state in
                if case .running(let p) = state { boundPort.set(p); ready.signal() }
            }
        )
        server.start()
        _ = ready.wait(timeout: .now() + 2)
        return (server, boundPort.get())
    }

    /// Send a CONNECT then read whatever the proxy returns; returns the full reply.
    private func connectThrough(
        proxyPort: UInt16,
        target: String,
        payload: Data
    ) -> Data {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        let queue = DispatchQueue(label: "client")
        var received = Data()
        let done = DispatchSemaphore(value: 0)

        func readLoop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isDone, _ in
                if let data { received.append(data) }
                if isDone { done.signal(); return }
                readLoop()
            }
        }

        conn.stateUpdateHandler = { state in
            if case .ready = state {
                let head = Data("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n".utf8)
                conn.send(content: head, completion: .contentProcessed { _ in
                    // After the tunnel opens, send payload; origin replies with body.
                    conn.send(content: payload, completion: .contentProcessed { _ in })
                    readLoop()
                })
            }
        }
        conn.start(queue: queue)
        _ = done.wait(timeout: .now() + 3)
        conn.cancel()
        return received
    }

    func testDirectRouteReachesOriginAndCountsBytes() throws {
        let body = Data("HELLO-FROM-ORIGIN".utf8)
        let origin = try TinyOrigin(response: body)
        origin.start()
        defer { origin.stop() }
        XCTAssertNotEqual(origin.port, 0)

        // Unknown app + no system upstream → inherit → direct. Reaches the origin.
        let rules = LocalProxyRules(
            snapshot: PolicyStore().compileSnapshot(),
            systemUpstream: nil,
            profiles: []
        )
        let flowRecorded = expectation(description: "flow event")
        var seen: LocalProxyServer.FlowEvent?
        let (server, port) = makeServer(rules: rules) { event in
            seen = event
            flowRecorded.fulfill()
        }
        defer { server.stop() }

        let reply = connectThrough(
            proxyPort: port,
            target: "127.0.0.1:\(origin.port)",
            payload: Data("ping".utf8)
        )
        XCTAssertTrue(
            String(data: reply, encoding: .utf8)?.contains("200 Connection Established") ?? false
        )
        XCTAssertTrue(reply.contains(body))

        wait(for: [flowRecorded], timeout: 3)
        XCTAssertEqual(seen?.action, .direct)
        XCTAssertGreaterThan(seen?.bytesDown ?? 0, 0)
    }

    func testBlockedFlowNeverReachesOriginAnd403s() throws {
        let origin = try TinyOrigin(response: Data("SHOULD-NOT-ARRIVE".utf8))
        origin.start()
        defer { origin.stop() }

        // Block everything from the unknown app (which is who our injected owner is).
        let store = PolicyStore()
        store.upsert(rule: NetworkPolicyRule(
            priority: 1,
            app: .any,
            destination: .any,
            firewall: .block,
            route: .inherit
        ))
        let rules = LocalProxyRules(
            snapshot: store.compileSnapshot(),
            systemUpstream: nil,
            profiles: []
        )
        let flowRecorded = expectation(description: "flow event")
        var seen: LocalProxyServer.FlowEvent?
        let (server, port) = makeServer(rules: rules) { event in
            seen = event
            flowRecorded.fulfill()
        }
        defer { server.stop() }

        let reply = connectThrough(
            proxyPort: port,
            target: "127.0.0.1:\(origin.port)",
            payload: Data("ping".utf8)
        )
        let text = String(data: reply, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("403 Forbidden"), "got: \(text)")
        XCTAssertFalse(reply.contains(Data("SHOULD-NOT-ARRIVE".utf8)))

        wait(for: [flowRecorded], timeout: 3)
        XCTAssertEqual(seen?.action, .block)
    }
}


/// Tiny thread-safe box for capturing a value out of an async state callback.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { value = initial }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
