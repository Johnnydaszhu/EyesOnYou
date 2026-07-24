import XCTest
import FlowLensCore
@testable import FlowLensRuleEngine

final class RouteGroupTests: XCTestCase {
    private let appA = AppIdentityKey(teamIdentifier: "AAA", signingIdentifier: "com.example.AppA")
    private let appB = AppIdentityKey(teamIdentifier: "BBB", signingIdentifier: "com.example.AppB")
    private let appC = AppIdentityKey(teamIdentifier: "CCC", signingIdentifier: "com.example.AppC")

    private func flow(for app: AppIdentityKey, host: String = "example.com") -> FlowDescriptor {
        FlowDescriptor(app: app, remoteHostname: host, remotePort: 443)
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

        // Flip app A off (inherit → falls through to default direct)
        store.assignRoute(app: appA, route: .inherit)
        snapshot = store.compileSnapshot()
        let decisionAAfter = snapshot.evaluateRoute(flow(for: appA))
        XCTAssertEqual(decisionAAfter.action, .direct)

        // Group still applies to C
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appC)).action, .proxy(profileID: profileID))

        // Remove C from group → direct
        store.removeApp(appC, fromGroup: group.id)
        snapshot = store.compileSnapshot()
        XCTAssertEqual(snapshot.evaluateRoute(flow(for: appC)).action, .direct)
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
            .direct
        )
        XCTAssertEqual(
            snapshot.evaluateRoute(flow(for: appA, host: "notapi.com")).action,
            .direct
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
}
