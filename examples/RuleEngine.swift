import Foundation

/// The production implementation should compile exact-app maps, a reversed-label
/// hostname trie, IPv4/IPv6 prefix tries, and compact port matchers.
/// This file intentionally shows interfaces and deterministic precedence, not the
/// full optimized implementation.
public final class RuleSnapshot: @unchecked Sendable {
    public let generation: UInt64
    public let checksum: Data
    private let rules: [CompiledRule]

    public init(generation: UInt64, checksum: Data, rules: [CompiledRule]) {
        self.generation = generation
        self.checksum = checksum
        self.rules = rules.sorted(by: CompiledRule.precedes)
    }

    public func evaluateFirewall(_ flow: FlowDescriptor) -> FirewallDecision {
        for rule in rules where rule.matches(flow) {
            if rule.firewall != .inherit {
                return FirewallDecision(action: rule.firewall, matchedRuleID: rule.id)
            }
        }
        return FirewallDecision(action: .allow, matchedRuleID: nil)
    }

    public func evaluateRoute(_ flow: FlowDescriptor) -> RouteDecision {
        for rule in rules where rule.matches(flow) {
            if rule.route != .inherit {
                return RouteDecision(action: rule.route, matchedRuleID: rule.id)
            }
        }
        return RouteDecision(action: .direct, matchedRuleID: nil)
    }
}

public struct CompiledRule: Sendable {
    public let id: UUID
    public let priority: Int32
    public let specificity: UInt64
    public let firewall: FirewallAction
    public let route: RouteAction
    private let predicate: @Sendable (FlowDescriptor) -> Bool

    public init(
        id: UUID,
        priority: Int32,
        specificity: UInt64,
        firewall: FirewallAction,
        route: RouteAction,
        predicate: @escaping @Sendable (FlowDescriptor) -> Bool
    ) {
        self.id = id
        self.priority = priority
        self.specificity = specificity
        self.firewall = firewall
        self.route = route
        self.predicate = predicate
    }

    public func matches(_ flow: FlowDescriptor) -> Bool { predicate(flow) }

    public static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
        // Stable tie-break; creation/modification order must not affect policy.
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
