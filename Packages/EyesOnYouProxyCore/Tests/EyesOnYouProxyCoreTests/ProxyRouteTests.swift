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
}
