import XCTest
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouProxyCore
@testable import EyesOnYouIPC

/// The host↔extension wire contract. These messages cross a process boundary, so
/// a silent encoding change would strand the extension with stale rules while the
/// UI claims enforcement is active — hence round-trip coverage for every case.
final class ProxyRulesPayloadTests: XCTestCase {
    private let telegram = AppIdentityKey(teamIdentifier: nil, signingIdentifier: "ph.telegra.Telegraph")

    /// Rebuild rules the way the extension does, so the test proves the whole
    /// path: host policy → JSON → decode → routable LocalProxyRules.
    private func rebuild(_ payload: ProxyRulesPayload) throws -> LocalProxyRules {
        let archive = try JSONDecoder().decode(PolicyArchive.self, from: payload.policyArchiveJSON)
        let store = PolicyStore()
        archive.apply(to: store)
        let upstream: ProxyUpstream? = payload.systemUpstreamHost.flatMap { host in
            payload.systemUpstreamPort.map { port in
                ProxyUpstream(
                    kind: payload.systemUpstreamKind == "socks5" ? .socks5 : .http,
                    host: host,
                    port: port
                )
            }
        }
        return LocalProxyRules(
            snapshot: store.compileSnapshot(),
            systemUpstream: upstream,
            profiles: archive.proxyProfiles
        )
    }

    func testPolicySurvivesTheProcessBoundary() throws {
        let store = PolicyStore()
        store.assignRoute(app: telegram, route: .systemProxy)
        let archive = PolicyArchive.capture(from: store, proxyProfiles: [])
        let payload = ProxyRulesPayload(
            generation: 7,
            policyArchiveJSON: try JSONEncoder().encode(archive),
            systemUpstreamHost: "127.0.0.1",
            systemUpstreamPort: 1082,
            systemUpstreamKind: "http"
        )

        // Full IPC hop, as the provider receives it.
        let wire = try IPCCoding.encode(HostToExtensionMessage.pushRules(payload))
        guard case .pushRules(let received) = try IPCCoding.decode(
            HostToExtensionMessage.self, from: wire
        ) else {
            return XCTFail("expected pushRules")
        }
        XCTAssertEqual(received, payload)

        let rules = try rebuild(received)
        XCTAssertEqual(
            TransparentFlowPlanner.plan(
                app: telegram, host: "chatgpt.com", port: 443, rules: rules
            ),
            .dialUpstream(ProxyUpstream(kind: .http, host: "127.0.0.1", port: 1082))
        )
    }

    func testSOCKSUpstreamKindIsPreserved() throws {
        let store = PolicyStore()
        store.assignRoute(app: telegram, route: .systemProxy)
        let payload = ProxyRulesPayload(
            generation: 1,
            policyArchiveJSON: try JSONEncoder().encode(
                PolicyArchive.capture(from: store, proxyProfiles: [])
            ),
            systemUpstreamHost: "127.0.0.1",
            systemUpstreamPort: 1086,
            systemUpstreamKind: "socks5"
        )
        XCTAssertEqual(
            try rebuild(payload).systemUpstream,
            ProxyUpstream(kind: .socks5, host: "127.0.0.1", port: 1086)
        )
    }

    func testMissingUpstreamStaysNilSoExplicitRoutesRefuse() throws {
        let store = PolicyStore()
        store.assignRoute(app: telegram, route: .systemProxy)
        let payload = ProxyRulesPayload(
            generation: 2,
            policyArchiveJSON: try JSONEncoder().encode(
                PolicyArchive.capture(from: store, proxyProfiles: [])
            )
        )
        let rules = try rebuild(payload)
        XCTAssertNil(rules.systemUpstream)
        XCTAssertEqual(
            TransparentFlowPlanner.plan(app: telegram, host: "x.com", port: 443, rules: rules),
            .refuse(.systemProxyMissing)
        )
    }

    func testFlowEventsRoundTripWithStatus() throws {
        let samples = [
            FlowEventSample(
                signingIdentifier: "ph.telegra.Telegraph", host: "chatgpt.com", port: 443,
                action: "upstream", bytesUp: 1_024, bytesDown: 8_192
            ),
            FlowEventSample(
                signingIdentifier: "com.apple.Safari", host: "baidu.com", port: 443,
                action: "direct", bytesUp: 10, bytesDown: 20
            )
        ]
        let status = ExtensionStatus(proxyEnabled: true, ruleGeneration: 9, providerReachable: true)
        let wire = try IPCCoding.encode(ExtensionToHostMessage.flowEvents(samples, status: status))
        guard case .flowEvents(let received, let receivedStatus) = try IPCCoding.decode(
            ExtensionToHostMessage.self, from: wire
        ) else {
            return XCTFail("expected flowEvents")
        }
        XCTAssertEqual(received, samples)
        XCTAssertEqual(receivedStatus.ruleGeneration, 9)
        // Byte counts are measured facts; truncation here would silently understate traffic.
        XCTAssertEqual(received.first?.bytesDown, 8_192)
    }

    func testControlMessagesRoundTrip() throws {
        for message: HostToExtensionMessage in [
            .ping, .requestStatus, .requestFlowEvents,
            .setProxyEnabled(true), .setFilterEnabled(false)
        ] {
            let wire = try IPCCoding.encode(message)
            XCTAssertNoThrow(try IPCCoding.decode(HostToExtensionMessage.self, from: wire))
        }
    }

    func testUndecodableRulesPayloadIsRejectedNotSilentlyEmpty() {
        // The provider must keep its previous rules rather than fall back to an
        // empty policy, which would un-enforce every rule without saying so.
        let payload = ProxyRulesPayload(
            generation: 3,
            policyArchiveJSON: Data("not json".utf8)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(PolicyArchive.self, from: payload.policyArchiveJSON)
        )
    }
}
