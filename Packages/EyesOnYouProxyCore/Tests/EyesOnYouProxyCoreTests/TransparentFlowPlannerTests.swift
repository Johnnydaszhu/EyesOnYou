import XCTest
import EyesOnYouCore
import EyesOnYouRuleEngine
@testable import EyesOnYouProxyCore

/// Route planning for the NetworkExtension transparent proxy, plus the HTTP
/// CONNECT handshake parsing it chains through.
final class TransparentFlowPlannerTests: XCTestCase {
    private let telegram = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "ph.telegra.Telegraph")
    private let safari = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "com.apple.Safari")
    private let shadowrocket = ProxyUpstream(kind: .http, host: "127.0.0.1", port: 1082)

    private func rules(
        assignments: [(AppIdentityKey, RouteAction)] = [],
        systemUpstream: ProxyUpstream? = nil,
        profiles: [ProxyProfile] = []
    ) -> LocalProxyRules {
        let store = PolicyStore()
        for (app, route) in assignments {
            store.assignRoute(app: app, route: route)
        }
        return LocalProxyRules(
            snapshot: store.compileSnapshot(),
            systemUpstream: systemUpstream,
            profiles: profiles
        )
    }

    // MARK: - Planning

    func testUnruledAppIsDeclinedNotClaimed() {
        // Fail-open: an app with no rule must be handed back to the OS untouched,
        // so a transparent proxy never becomes a bottleneck for the whole machine.
        let plan = TransparentFlowPlanner.plan(
            app: safari, host: "apple.com", port: 443,
            rules: rules(systemUpstream: shadowrocket)
        )
        XCTAssertEqual(plan, .decline)
    }

    func testInheritDeclinesEvenWithUpstreamAvailable() {
        // Unlike the local proxy (where inherit = chain upstream), a transparent
        // provider declines: the OS still routes it through whatever is active.
        let plan = TransparentFlowPlanner.plan(
            app: safari, host: "apple.com", port: 443,
            rules: rules(assignments: [(safari, .inherit)], systemUpstream: shadowrocket)
        )
        XCTAssertEqual(plan, .decline)
    }

    func testForceDirectDials() {
        let plan = TransparentFlowPlanner.plan(
            app: safari, host: "baidu.com", port: 443,
            rules: rules(assignments: [(safari, .direct)], systemUpstream: shadowrocket)
        )
        XCTAssertEqual(plan, .dialDirect)
    }

    func testForceSystemProxyUsesCapturedUpstream() {
        let plan = TransparentFlowPlanner.plan(
            app: telegram, host: "chatgpt.com", port: 443,
            rules: rules(assignments: [(telegram, .systemProxy)], systemUpstream: shadowrocket)
        )
        XCTAssertEqual(plan, .dialUpstream(shadowrocket))
    }

    func testForceProxyWithoutUpstreamRefusesInsteadOfLeaking() {
        // The whole point of an explicit rule: it must never silently go direct.
        let plan = TransparentFlowPlanner.plan(
            app: telegram, host: "chatgpt.com", port: 443,
            rules: rules(assignments: [(telegram, .systemProxy)], systemUpstream: nil)
        )
        XCTAssertEqual(plan, .refuse(.systemProxyMissing))
    }

    func testProfileRouteResolvesAndMissingProfileRefuses() {
        let profile = ProxyProfile(name: "HK", kind: .socks5, host: "127.0.0.1", port: 1086)
        let resolved = TransparentFlowPlanner.plan(
            app: telegram, host: "chatgpt.com", port: 443,
            rules: rules(
                assignments: [(telegram, .proxy(profileID: profile.id))],
                profiles: [profile]
            )
        )
        XCTAssertEqual(
            resolved,
            .dialUpstream(ProxyUpstream(kind: .socks5, host: "127.0.0.1", port: 1086))
        )

        let orphanID = UUID()
        let missing = TransparentFlowPlanner.plan(
            app: telegram, host: "chatgpt.com", port: 443,
            rules: rules(assignments: [(telegram, .proxy(profileID: orphanID))])
        )
        XCTAssertEqual(missing, .refuse(.profileMissing(orphanID)))
    }

    func testFirewallBlockBeatsRoute() {
        let store = PolicyStore()
        store.assignRoute(app: telegram, route: .systemProxy)
        store.upsert(rule: NetworkPolicyRule(
            destination: .hostnameSuffix("chatgpt.com"),
            firewall: .block
        ))
        let plan = TransparentFlowPlanner.plan(
            app: telegram, host: "chatgpt.com", port: 443,
            rules: LocalProxyRules(
                snapshot: store.compileSnapshot(),
                systemUpstream: shadowrocket,
                profiles: []
            )
        )
        XCTAssertEqual(plan, .block)
    }

    // MARK: - HTTP CONNECT handshake

    func testConnectRequestShape() {
        let request = HTTPConnectHandshake.request(host: "chatgpt.com", port: 443)
        XCTAssertEqual(
            String(data: request, encoding: .utf8),
            "CONNECT chatgpt.com:443 HTTP/1.1\r\nHost: chatgpt.com:443\r\n\r\n"
        )
    }

    func testConnectSuccessKeepsEarlyTunneledBytes() {
        let buffer = Data("HTTP/1.1 200 Connection established\r\nVia: proxy\r\n\r\n\u{16}\u{03}\u{01}".utf8)
        guard case .success(let remainder) = HTTPConnectHandshake.verdict(for: buffer) else {
            return XCTFail("expected success")
        }
        // The TLS ClientHello bytes that rode along must not be dropped.
        XCTAssertEqual(remainder, Data("\u{16}\u{03}\u{01}".utf8))
    }

    func testConnectPartialResponseAsksForMore() {
        XCTAssertEqual(
            HTTPConnectHandshake.verdict(for: Data("HTTP/1.1 200 Conn".utf8)),
            .needMoreData
        )
    }

    func testConnectRejectsErrorStatusAndGarbage() {
        XCTAssertEqual(
            HTTPConnectHandshake.verdict(for: Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8)),
            .failure
        )
        XCTAssertEqual(
            HTTPConnectHandshake.verdict(for: Data("NOT-HTTP garbage\r\n\r\n".utf8)),
            .failure
        )
    }

    func testConnectGivesUpOnUnterminatedFlood() {
        // A peer that never sends the header terminator must not buffer forever.
        let flood = Data(repeating: 0x41, count: 16_385)
        XCTAssertEqual(HTTPConnectHandshake.verdict(for: flood), .failure)
    }
}
