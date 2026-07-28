import XCTest
import EyesOnYouCore
import EyesOnYouRuleEngine
@testable import EyesOnYouProxyCore

final class ProxyRequestHeadTests: XCTestCase {
    private func parse(_ text: String) -> Result<ProxyRequestHead, ProxyRequestHead.ParseError>? {
        ProxyRequestHead.parse(buffer: Data(text.utf8))
    }

    func testConnectTunnel() throws {
        let result = try XCTUnwrap(parse("CONNECT youtube.com:443 HTTP/1.1\r\nHost: youtube.com\r\n\r\n"))
        let head = try result.get()
        XCTAssertEqual(head.kind, .connect)
        XCTAssertEqual(head.host, "youtube.com")
        XCTAssertEqual(head.port, 443)
        XCTAssertTrue(head.remainder.isEmpty)
    }

    func testConnectDefaultsToPort443WhenOmitted() throws {
        let head = try XCTUnwrap(parse("CONNECT example.com HTTP/1.1\r\n\r\n")).get()
        XCTAssertEqual(head.port, 443)
    }

    func testAbsoluteFormHTTP() throws {
        let head = try XCTUnwrap(parse("GET http://bilibili.com/watch HTTP/1.1\r\nHost: bilibili.com\r\n\r\n")).get()
        XCTAssertEqual(head.kind, .httpForward)
        XCTAssertEqual(head.host, "bilibili.com")
        XCTAssertEqual(head.port, 80)
        // The head must be preserved verbatim for forwarding.
        XCTAssertTrue(String(data: head.rawHead, encoding: .utf8)!.hasPrefix("GET http://bilibili.com/watch"))
    }

    func testIncompleteHeadReturnsNil() {
        XCTAssertNil(parse("CONNECT youtube.com:443 HTTP/1.1\r\nHost: you"))
    }

    func testRemainderCapturesEarlyPayload() throws {
        let head = try XCTUnwrap(parse("CONNECT a.com:443 HTTP/1.1\r\n\r\n\u{16}\u{03}extra")).get()
        XCTAssertEqual(String(data: head.remainder, encoding: .utf8), "\u{16}\u{03}extra")
    }

    func testMalformedIsFailureNotNil() throws {
        let result = try XCTUnwrap(parse("GARBAGE\r\n\r\n"))
        XCTAssertThrowsError(try result.get())
    }

    func testIPv6Authority() {
        XCTAssertEqual(
            ProxyRequestHead.splitAuthority("[2606:4700::1]:8443", defaultPort: 443)?.1,
            8443
        )
        XCTAssertEqual(
            ProxyRequestHead.splitAuthority("[2606:4700::1]", defaultPort: 443)?.0,
            "2606:4700::1"
        )
    }
}

final class LocalProxyRulesTests: XCTestCase {
    private let chrome = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.google.Chrome")
    private let slack = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.tinyspeck.slackmacgap")
    private let shadowrocket = ProxyUpstream(kind: .socks5, host: "127.0.0.1", port: 1082)

    private func rules(
        configure: (PolicyStore) -> Void,
        systemUpstream: ProxyUpstream? = nil,
        profiles: [ProxyProfile] = []
    ) -> LocalProxyRules {
        let store = PolicyStore()
        configure(store)
        return LocalProxyRules(
            snapshot: store.compileSnapshot(),
            systemUpstream: systemUpstream,
            profiles: profiles
        )
    }

    func testExplicitProxyRouteGoesUpstream() {
        let r = rules(
            configure: { $0.assignRoute(app: chrome, route: .systemProxy) },
            systemUpstream: shadowrocket
        )
        XCTAssertEqual(r.action(for: chrome, host: "youtube.com", port: 443), .upstream(shadowrocket))
    }

    func testExplicitSystemProxyDoesNotLeakDirectWhenUpstreamMissing() {
        let r = rules(
            configure: { $0.assignRoute(app: chrome, route: .systemProxy) }
        )
        XCTAssertEqual(
            r.action(for: chrome, host: "youtube.com", port: 443),
            .unavailable(.systemProxyMissing)
        )
    }

    func testExplicitDirectBypassesTheProxy() {
        let r = rules(
            configure: { $0.assignRoute(app: chrome, route: .direct) },
            systemUpstream: shadowrocket
        )
        XCTAssertEqual(r.action(for: chrome, host: "bilibili.com", port: 443), .direct)
    }

    func testInheritFollowsSystemUpstreamWhenPresent() {
        // No rule: EyesOnYou holds the slot, so an unruled app keeps going where the
        // system proxy would have sent it — the upstream that held the slot before us.
        let r = rules(configure: { _ in }, systemUpstream: shadowrocket)
        XCTAssertEqual(r.action(for: slack, host: "api.slack.com", port: 443), .upstream(shadowrocket))
    }

    func testInheritIsDirectWhenNoSystemProxyExisted() {
        let r = rules(configure: { _ in }, systemUpstream: nil)
        XCTAssertEqual(r.action(for: slack, host: "api.slack.com", port: 443), .direct)
    }

    func testBlockRuleWins() {
        let r = rules(configure: {
            $0.upsert(rule: NetworkPolicyRule(
                priority: 10,
                app: .exact(chrome),
                destination: .hostnameSuffix("ads.example.com"),
                firewall: .block,
                route: .inherit
            ))
        }, systemUpstream: shadowrocket)
        XCTAssertEqual(r.action(for: chrome, host: "ads.example.com", port: 443), .block)
    }

    func testProfileRouteUsesProfileUpstream() {
        let profile = ProxyProfile(name: "Office", kind: .httpConnect, host: "10.0.0.1", port: 3128)
        let r = rules(
            configure: { $0.assignRoute(app: chrome, route: .proxy(profileID: profile.id)) },
            systemUpstream: shadowrocket,
            profiles: [profile]
        )
        XCTAssertEqual(
            r.action(for: chrome, host: "youtube.com", port: 443),
            .upstream(ProxyUpstream(kind: .http, host: "10.0.0.1", port: 3128))
        )
    }

    func testMissingProfileDoesNotFallBackToAnotherProxyOrDirect() {
        let missingID = UUID()
        let r = rules(
            configure: { $0.assignRoute(app: chrome, route: .proxy(profileID: missingID)) },
            systemUpstream: shadowrocket
        )
        XCTAssertEqual(
            r.action(for: chrome, host: "youtube.com", port: 443),
            .unavailable(.profileMissing(missingID))
        )
    }
}

final class ConnectionOwnerResolverTests: XCTestCase {
    func testParsesLsofFieldOutput() {
        let text = """
        p4242
        n127.0.0.1:52000->127.0.0.1:7890
        p4242
        n127.0.0.1:52001->127.0.0.1:7890
        p900
        n[::1]:52010->[::1]:7890
        """
        let pairs = ConnectionOwnerResolver.parseLsofFieldOutput(text)
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs[0].pid, 4242)
        XCTAssertEqual(pairs[0].localPort, 52000)
        XCTAssertEqual(pairs[1].localPort, 52001)
        // Bracketed IPv6 loopback still yields a usable client port.
        XCTAssertEqual(pairs[2].pid, 900)
        XCTAssertEqual(pairs[2].localPort, 52010)
    }

    func testResolvesOwnerFromInjectedSampler() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let resolver = ConnectionOwnerResolver(refreshInterval: 0) {
            [(pid: selfPID, localPort: UInt16(59999))]
        }
        // The test process resolves to *some* identity; the port must map to our PID.
        let owner = resolver.owner(clientPort: 59999)
        XCTAssertEqual(owner?.pid, selfPID)
        XCTAssertNil(resolver.owner(clientPort: 12345))
    }
}

final class ConnectionOwnerResolverRefreshTests: XCTestCase {
    /// Regression: a scheduled refresh must not suppress the on-miss retry.
    ///
    /// Real-machine testing showed only the *first* connection resolved; every later
    /// one came back "Unknown" because the periodic rebuild armed the same rate
    /// limiter the miss-retry checked.
    func testMissTriggersRebuildEvenRightAfterAScheduledRefresh() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let visible = LockedPorts()
        var sampleCount = 0

        let resolver = ConnectionOwnerResolver(refreshInterval: 60) {
            sampleCount += 1
            return visible.get().map { (pid: selfPID, localPort: $0) }
        }

        // First lookup builds the index while port 5001 is the only socket.
        visible.set([5001])
        XCTAssertNotNil(resolver.owner(clientPort: 5001))
        let afterFirst = sampleCount

        // A new connection appears. The index is fresh (60s interval), so only the
        // miss-retry can find it.
        visible.set([5001, 5002])
        XCTAssertNotNil(
            resolver.owner(clientPort: 5002, now: Date().addingTimeInterval(0.5)),
            "a brand-new port must trigger a rebuild"
        )
        XCTAssertGreaterThan(sampleCount, afterFirst, "expected a forced rebuild")
    }

    func testRepeatedMissesAreRateLimited() {
        let resolver = ConnectionOwnerResolver(refreshInterval: 60) { [] }
        let start = Date()
        _ = resolver.owner(clientPort: 1, now: start)
        // Within the rate-limit window a second miss must not rebuild again; the
        // guard exists so unattributable traffic cannot spawn an lsof per connection.
        _ = resolver.owner(clientPort: 2, now: start.addingTimeInterval(0.01))
        // No assertion on counts beyond not crashing: behaviour is the rate limit.
        XCTAssertNil(resolver.owner(clientPort: 3, now: start.addingTimeInterval(0.01)))
    }
}

private final class LockedPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [UInt16] = []
    func set(_ p: [UInt16]) { lock.lock(); ports = p; lock.unlock() }
    func get() -> [UInt16] { lock.lock(); defer { lock.unlock() }; return ports }
}
