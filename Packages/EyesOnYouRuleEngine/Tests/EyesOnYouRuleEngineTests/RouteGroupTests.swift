import XCTest
import EyesOnYouCore
@testable import EyesOnYouRuleEngine

final class RouteGroupTests: XCTestCase {
    private let appA = AppIdentityKey(teamIdentifier: "AAA", signingIdentifier: "com.example.AppA")
    private let appB = AppIdentityKey(teamIdentifier: "BBB", signingIdentifier: "com.example.AppB")
    private let appC = AppIdentityKey(teamIdentifier: "CCC", signingIdentifier: "com.example.AppC")

    private func flow(for app: AppIdentityKey, host: String = "example.com") -> FlowDescriptor {
        FlowDescriptor(app: app, remoteHostname: host, remotePort: 443)
    }

    private func flow(for app: AppIdentityKey, address: String) -> FlowDescriptor {
        FlowDescriptor(app: app, remoteAddress: address, remotePort: 443)
    }

    private func snapshot(matching destination: DestinationMatcher) -> RuleSnapshot {
        let store = PolicyStore()
        store.upsert(rule: NetworkPolicyRule(
            priority: 10,
            app: .any,
            destination: destination,
            route: .systemProxy
        ))
        return store.compileSnapshot()
    }

    private func assertSnapshotInvalidated(
        _ store: PolicyStore,
        previous: inout RuleSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line,
        mutation: () -> Void
    ) {
        let previousGeneration = previous.generation
        mutation()
        let next = store.compileSnapshot()
        XCTAssertFalse(next === previous, "mutation returned the cached snapshot", file: file, line: line)
        XCTAssertGreaterThan(next.generation, previousGeneration, file: file, line: line)
        XCTAssertTrue(next === store.compileSnapshot(), "new generation was not cached", file: file, line: line)
        previous = next
    }

    func testPerAppRouteToggleAndGroupInheritance() {
        let store = PolicyStore()
        let profileID = UUID()

        // App A → custom proxy
        store.assignRoute(app: appA, route: .proxy(profileID: profileID))
        // App B → direct
        store.assignRoute(app: appB, route: .direct)

        // Group G with app C → proxy
        let group = AppGroup(
            name: "Proxy Group",
            memberKeys: [appC],
            defaultRoute: .proxy(profileID: profileID)
        )
        store.upsert(group: group)

        var snapshot = store.compileSnapshot()

        let decisionA = snapshot.evaluateRoute(flow(for: appA))
        XCTAssertEqual(decisionA.action, .proxy(profileID: profileID))

        let decisionB = snapshot.evaluateRoute(flow(for: appB))
        XCTAssertEqual(decisionB.action, .direct)

        let decisionC = snapshot.evaluateRoute(flow(for: appC))
        XCTAssertEqual(decisionC.action, .proxy(profileID: profileID))

        // Flip app A off: with no rule left, macOS decides — `.inherit`, not `.direct`.
        store.assignRoute(app: appA, route: .inherit)
        snapshot = store.compileSnapshot()
        let decisionAAfter = snapshot.evaluateRoute(flow(for: appA))
        XCTAssertEqual(decisionAAfter.action, .inherit)

        // Group still applies to C
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appC)).action, .proxy(profileID: profileID))

        // Remove C from group → no policy applies
        store.removeApp(appC, fromGroup: group.id)
        snapshot = store.compileSnapshot()
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appC)).action, .inherit)
    }

    func testExplicitRuleOverridesGroupAndDefault() {
        let store = PolicyStore()
        let profileID = UUID()

        store.upsert(group: AppGroup(
            name: "G",
            memberKeys: [appA],
            defaultRoute: .systemProxy
        ))

        let blockRule = NetworkPolicyRule(
            priority: 100,
            app: .exact(appA),
            destination: .hostnameSuffix("tracker.com"),
            firewall: .block,
            route: .direct
        )
        store.upsert(rule: blockRule)

        let proxyRule = NetworkPolicyRule(
            priority: 50,
            app: .exact(appA),
            destination: .hostnameExact("api.service.com"),
            firewall: .allow,
            route: .proxy(profileID: profileID)
        )
        store.upsert(rule: proxyRule)

        let snapshot = store.compileSnapshot()

        // Hostname rule wins for api
        let apiFlow = flow(for: appA, host: "api.service.com")
        XCTAssertEqual(snapshot.evaluateRoute(apiFlow).action, .proxy(profileID: profileID))
        XCTAssertEqual(snapshot.evaluateFirewall(apiFlow).action, .allow)

        // Block tracker
        let tracker = flow(for: appA, host: "ads.tracker.com")
        XCTAssertEqual(snapshot.evaluateFirewall(tracker).action, .block)

        // Other host → group default route
        let other = flow(for: appA, host: "example.org")
        XCTAssertEqual(snapshot.evaluateRoute(other).action, .systemProxy)
    }

    func testAppAssignmentBeatsGroupRoute() {
        let store = PolicyStore()
        let profileID = UUID()

        store.upsert(group: AppGroup(
            name: "Proxied",
            memberKeys: [appA],
            defaultRoute: .proxy(profileID: profileID)
        ))
        // Explicit direct on A
        store.assignRoute(app: appA, route: .direct)

        let snapshot = store.compileSnapshot()
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appA)).action, .direct)
    }

    func testFirewallFailOpenDefault() {
        let store = PolicyStore()
        let snapshot = store.compileSnapshot()
        let decision = snapshot.evaluateFirewall(flow(for: appA))
        XCTAssertEqual(decision.action, .allow)
        XCTAssertNil(decision.matchedRuleID)
    }

    func testHostnameSuffixUsesLabelBoundary() {
        let store = PolicyStore()
        let profileID = UUID()
        store.upsert(rule: NetworkPolicyRule(
            priority: 10,
            app: .any,
            destination: .hostnameSuffix("api.com"),
            firewall: .allow,
            route: .proxy(profileID: profileID)
        ))
        let snapshot = store.compileSnapshot()

        // Exact and proper subdomain match
        XCTAssertEqual(
            snapshot.evaluateRoute(flow(for: appA, host: "api.com")).action,
            .proxy(profileID: profileID)
        )
        XCTAssertEqual(
            snapshot.evaluateRoute(flow(for: appA, host: "v1.api.com")).action,
            .proxy(profileID: profileID)
        )

        // False positive: "evilapi.com" must NOT match suffix "api.com"
        XCTAssertEqual(
            snapshot.evaluateRoute(flow(for: appA, host: "evilapi.com")).action,
            .inherit
        )
        XCTAssertEqual(
            snapshot.evaluateRoute(flow(for: appA, host: "notapi.com")).action,
            .inherit
        )
    }

    func testProxyToggleUsesResolvedRouteNotInheritAssignment() {
        let store = PolicyStore()
        let profileID = UUID()

        // Group proxies app C; assignment for C remains inherit
        store.upsert(group: AppGroup(
            name: "G",
            memberKeys: [appC],
            defaultRoute: .proxy(profileID: profileID)
        ))
        XCTAssertEqual(store.assignment(for: appC), .inherit)

        var snapshot = store.compileSnapshot()
        let resolved = snapshot.evaluateRoute(flow(for: appC)).action
        XCTAssertEqual(resolved, .proxy(profileID: profileID))
        XCTAssertTrue(ProxyToggleLogic.isProxyEnabled(resolved))

        // UI toggle OFF must write explicit .direct (not re-apply proxy via inherit branch)
        let nextOff = ProxyToggleLogic.nextRoute(resolved: resolved, profileID: profileID)
        XCTAssertEqual(nextOff, .direct)
        store.assignRoute(app: appC, route: nextOff)
        snapshot = store.compileSnapshot()
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appC)).action, .direct)
        XCTAssertFalse(ProxyToggleLogic.isProxyEnabled(snapshot.evaluateRoute(flow(for: appC)).action))

        // Toggle ON again → proxy
        let nextOn = ProxyToggleLogic.nextRoute(
            resolved: snapshot.evaluateRoute(flow(for: appC)).action,
            profileID: profileID
        )
        XCTAssertEqual(nextOn, .proxy(profileID: profileID))
        store.assignRoute(app: appC, route: nextOn)
        snapshot = store.compileSnapshot()
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appC)).action, .proxy(profileID: profileID))
    }

    func testIPv4CIDRUsesBinaryPrefixBoundaries() {
        // Host bits in the configured address are masked during compilation.
        let subnet = snapshot(matching: .cidr(network: "10.20.30.99", prefix: 24))
        XCTAssertEqual(
            subnet.evaluateRoute(flow(for: appA, address: "10.20.30.0")).action,
            .systemProxy
        )
        XCTAssertEqual(
            subnet.evaluateRoute(flow(for: appA, address: "10.20.30.255")).action,
            .systemProxy
        )
        XCTAssertEqual(
            subnet.evaluateRoute(flow(for: appA, address: "10.20.31.1")).action,
            .inherit
        )
        XCTAssertEqual(
            subnet.evaluateRoute(flow(for: appA, address: "100.20.30.1")).action,
            .inherit,
            "CIDR matching must not compare only the first address characters"
        )

        let exact = snapshot(matching: .cidr(network: "192.0.2.7", prefix: 32))
        XCTAssertEqual(exact.evaluateRoute(flow(for: appA, address: "192.0.2.7")).action, .systemProxy)
        XCTAssertEqual(exact.evaluateRoute(flow(for: appA, address: "192.0.2.8")).action, .inherit)

        let allIPv4 = snapshot(matching: .cidr(network: "203.0.113.9", prefix: 0))
        XCTAssertEqual(allIPv4.evaluateRoute(flow(for: appA, address: "1.2.3.4")).action, .systemProxy)
        XCTAssertEqual(allIPv4.evaluateRoute(flow(for: appA, address: "2001:db8::1")).action, .inherit)
    }

    func testIPv6CIDRUsesBinaryPrefixBoundariesAndCanonicalAddresses() {
        let subnet = snapshot(matching: .cidr(network: "2001:db8:abcd::1234", prefix: 48))
        XCTAssertEqual(
            subnet.evaluateRoute(flow(for: appA, address: "2001:0db8:abcd:ffff::1")).action,
            .systemProxy
        )
        XCTAssertEqual(
            subnet.evaluateRoute(flow(for: appA, address: "2001:db8:abce::1")).action,
            .inherit
        )
        XCTAssertEqual(
            subnet.evaluateRoute(flow(for: appA, address: "10.20.30.40")).action,
            .inherit
        )

        let exact = snapshot(matching: .cidr(network: "2001:db8::7", prefix: 128))
        XCTAssertEqual(exact.evaluateRoute(flow(for: appA, address: "2001:0db8:0:0::7")).action, .systemProxy)
        XCTAssertEqual(exact.evaluateRoute(flow(for: appA, address: "2001:db8::8")).action, .inherit)

        let scoped = snapshot(matching: .cidr(network: "fe80::", prefix: 10))
        XCTAssertEqual(
            scoped.evaluateRoute(flow(for: appA, address: "fe80::1%en0")).action,
            .systemProxy
        )
    }

    func testInvalidCIDRAddressAndPrefixNeverMatch() {
        let invalidMatchers: [DestinationMatcher] = [
            .cidr(network: "not-an-address", prefix: 24),
            .cidr(network: "999.0.0.1", prefix: 24),
            .cidr(network: "10.0.0.0", prefix: 33),
            .cidr(network: "2001:db8::", prefix: 129),
            .cidr(network: "fe80::%en0", prefix: 64),
        ]

        for matcher in invalidMatchers {
            let invalid = snapshot(matching: matcher)
            XCTAssertEqual(
                invalid.evaluateRoute(flow(for: appA, address: "10.0.0.1")).action,
                .inherit,
                "\(matcher) unexpectedly matched IPv4"
            )
            XCTAssertEqual(
                invalid.evaluateRoute(flow(for: appA, address: "2001:db8::1")).action,
                .inherit,
                "\(matcher) unexpectedly matched IPv6"
            )
        }
    }

    func testCompileSnapshotCachesGenerationAndEveryMutationInvalidates() {
        let store = PolicyStore()
        var previous = store.compileSnapshot()
        XCTAssertTrue(previous === store.compileSnapshot())

        let rule = NetworkPolicyRule(
            priority: 10,
            app: .exact(appA),
            destination: .hostnameExact("example.com"),
            route: .direct
        )
        assertSnapshotInvalidated(store, previous: &previous) {
            store.upsert(rule: rule)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            var updated = rule
            updated.priority = 20
            store.upsert(rule: updated)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.removeRule(id: rule.id)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.setRules([rule])
        }

        let groupA = AppGroup(name: "A", defaultRoute: .direct)
        let groupB = AppGroup(name: "B", defaultRoute: .systemProxy)
        assertSnapshotInvalidated(store, previous: &previous) {
            store.upsert(group: groupA)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.upsert(group: groupB)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            var updated = groupA
            updated.name = "A renamed"
            store.upsert(group: updated)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.addApp(appA, toGroup: groupA.id)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.removeApp(appA, fromGroup: groupA.id)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.moveApp(appA, toGroup: groupB.id)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.reorderGroups(orderedIDs: [groupB.id, groupA.id])
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.removeGroup(id: groupA.id)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.setGroups([groupA, groupB])
        }

        assertSnapshotInvalidated(store, previous: &previous) {
            store.assignRoute(app: appA, route: .direct)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.assignRoute(app: appA, route: .inherit)
        }
        assertSnapshotInvalidated(store, previous: &previous) {
            store.setAssignments([appB: .systemProxy, appC: .inherit])
        }
    }

    func testGroupDefaultIndexUsesStableGroupOrder() {
        let store = PolicyStore()
        let direct = AppGroup(
            name: "First",
            memberKeys: [appA],
            defaultRoute: .direct,
            defaultFirewall: .allow
        )
        let proxied = AppGroup(
            name: "Second",
            memberKeys: [appA],
            defaultRoute: .systemProxy,
            defaultFirewall: .block
        )

        store.setGroups([direct, proxied])
        var snapshot = store.compileSnapshot()
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appA)).action, .direct)
        XCTAssertEqual(snapshot.evaluateFirewall(flow(for: appA)).action, .allow)

        store.reorderGroups(orderedIDs: [proxied.id, direct.id])
        snapshot = store.compileSnapshot()
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appA)).action, .systemProxy)
        XCTAssertEqual(snapshot.evaluateFirewall(flow(for: appA)).action, .block)
    }
}
