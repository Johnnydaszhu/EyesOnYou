import Foundation
import EyesOnYouCore
import EyesOnYouRuleEngine

/// Selective-proxy routing helpers used by the transparent proxy provider path.
/// Fail-open: unclassified or inherit → direct (return false to OS).
public enum ProxyRouteEvaluator {
    public static func shouldClaimFlow(
        _ flow: FlowDescriptor,
        snapshot: RuleSnapshot
    ) -> (claim: Bool, decision: RouteDecision) {
        let decision = snapshot.evaluateRoute(flow)
        switch decision.action {
        case .inherit, .direct:
            return (false, decision)
        case .systemProxy, .proxy:
            return (true, decision)
        }
    }
}

public struct ProxyProfile: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case httpConnect
        case socks5
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var host: String
    public var port: UInt16
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        host: String,
        port: UInt16,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.enabled = enabled
    }
}
