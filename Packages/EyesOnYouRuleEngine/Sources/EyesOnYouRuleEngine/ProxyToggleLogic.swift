import Foundation
import EyesOnYouCore

/// Maps UI "Use Proxy" toggles to an explicit per-app assignment.
/// Always base the decision on the **resolved** route (after rules + groups),
/// never on a raw `.inherit` assignment alone.
public enum ProxyToggleLogic {
    /// - If currently resolved to `.proxy`, turn proxy OFF → explicit `.direct`.
    /// - Otherwise turn proxy ON → `.proxy(profileID:)`.
    public static func nextRoute(resolved: RouteAction, profileID: UUID) -> RouteAction {
        if case .proxy = resolved {
            return .direct
        }
        return .proxy(profileID: profileID)
    }

    public static func isProxyEnabled(_ resolved: RouteAction) -> Bool {
        if case .proxy = resolved { return true }
        return false
    }
}
