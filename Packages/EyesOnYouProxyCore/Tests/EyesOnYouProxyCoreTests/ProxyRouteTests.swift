import XCTest
import EyesOnYouCore
import EyesOnYouRuleEngine
@testable import EyesOnYouProxyCore

final class ProxyRouteTests: XCTestCase {
    func testShouldClaimOnlyProxyRoutes() {
        let profile = UUID()
        let appProxy = AppIdentityKey(teamIdentifier: "T", signingIdentifier: "com.a.Proxy")
        let appDirect = AppIdentityKey(teamIdentifier: "T", signingIdentifier: "com.a.Direct")
        let store = PolicyStore()
        store.assignRoute(app: appProxy, route: .proxy(profileID: profile))
        store.assignRoute(app: appDirect, route: .direct)
        let snap = store.compileSnapshot()

        let claim = ProxyRouteEvaluator.shouldClaimFlow(FlowDescriptor(app: appProxy), snapshot: snap)
        XCTAssertTrue(claim.claim)
        XCTAssertEqual(claim.decision.action, .proxy(profileID: profile))

        let noClaim = ProxyRouteEvaluator.shouldClaimFlow(FlowDescriptor(app: appDirect), snapshot: snap)
        XCTAssertFalse(noClaim.claim)
        XCTAssertEqual(noClaim.decision.action, .direct)
    }

    func testUnruledAppFollowsSystemAndIsStillNotClaimed() {
        // An app with no policy reports `.inherit` — "macOS decides" — rather than
        // claiming `.direct`. The transparent proxy must still leave it to the OS:
        // this is the fail-open guarantee, and reporting must not change enforcement.
        let unruled = AppIdentityKey(teamIdentifier: "T", signingIdentifier: "com.a.Unruled")
        let snapshot = PolicyStore().compileSnapshot()

        let result = ProxyRouteEvaluator.shouldClaimFlow(
            FlowDescriptor(app: unruled),
            snapshot: snapshot
        )
        XCTAssertEqual(result.decision.action, .inherit)
        XCTAssertFalse(result.claim)
    }

    func testGroupDefaultStillOverridesTheFollowSystemDefault() {
        let member = AppIdentityKey(teamIdentifier: "T", signingIdentifier: "com.a.Member")
        let store = PolicyStore()
        store.upsert(group: AppGroup(name: "Direct", memberKeys: [member], defaultRoute: .direct))

        let decision = store.compileSnapshot().evaluateRoute(FlowDescriptor(app: member))
        XCTAssertEqual(decision.action, .direct)
    }
}
