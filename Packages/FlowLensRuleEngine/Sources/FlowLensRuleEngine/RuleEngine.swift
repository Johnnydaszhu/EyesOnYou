import Foundation
import FlowLensCore

// MARK: - Compiled rule

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
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - Immutable snapshot evaluator

public final class RuleSnapshot: @unchecked Sendable {
    public let generation: UInt64
    public let checksum: Data
    private let rules: [CompiledRule]
    private let groups: [UUID: AppGroup]
    private let appAssignments: [AppIdentityKey: RouteAction]

    public init(
        generation: UInt64,
        checksum: Data,
        rules: [CompiledRule],
        groups: [AppGroup] = [],
        appAssignments: [AppIdentityKey: RouteAction] = [:]
    ) {
        self.generation = generation
        self.checksum = checksum
        self.rules = rules.sorted(by: CompiledRule.precedes)
        self.groups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        self.appAssignments = appAssignments
    }

    public var activeRuleCount: Int { rules.count }

    public func evaluateFirewall(_ flow: FlowDescriptor) -> FirewallDecision {
        for rule in rules where rule.matches(flow) {
            if rule.firewall != .inherit {
                return FirewallDecision(action: rule.firewall, matchedRuleID: rule.id)
            }
        }
        // Group default firewall
        if let group = groupContaining(flow.app), group.defaultFirewall != .inherit {
            return FirewallDecision(action: group.defaultFirewall, matchedRuleID: nil)
        }
        return FirewallDecision(action: .allow, matchedRuleID: nil)
    }

    public func evaluateRoute(_ flow: FlowDescriptor) -> RouteDecision {
        // 1) Explicit per-app assignment (highest convenience toggle)
        if let assigned = appAssignments[flow.app], assigned != .inherit {
            return RouteDecision(action: assigned, matchedRuleID: nil)
        }

        // 2) Compiled rules
        for rule in rules where rule.matches(flow) {
            if rule.route != .inherit {
                return RouteDecision(action: rule.route, matchedRuleID: rule.id)
            }
        }

        // 3) Named group default route
        if let group = groupContaining(flow.app), group.defaultRoute != .inherit {
            return RouteDecision(action: group.defaultRoute, matchedRuleID: nil)
        }

        return RouteDecision(action: .direct, matchedRuleID: nil)
    }

    private func groupContaining(_ app: AppIdentityKey) -> AppGroup? {
        groups.values.first { $0.memberKeys.contains(app) }
    }
}

// MARK: - Mutable policy store → snapshot compiler

public final class PolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [NetworkPolicyRule] = []
    private var groups: [AppGroup] = []
    private var appAssignments: [AppIdentityKey: RouteAction] = [:]
    private var generation: UInt64 = 0

    public init() {}

    public var currentGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    // MARK: Mutations

    public func upsert(rule: NetworkPolicyRule) {
        lock.lock(); defer { lock.unlock() }
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        generation &+= 1
    }

    public func removeRule(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        rules.removeAll { $0.id == id }
        generation &+= 1
    }

    public func setRules(_ newRules: [NetworkPolicyRule]) {
        lock.lock(); defer { lock.unlock() }
        rules = newRules
        generation &+= 1
    }

    public func upsert(group: AppGroup) {
        lock.lock(); defer { lock.unlock() }
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        } else {
            groups.append(group)
        }
        generation &+= 1
    }

    public func removeGroup(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        groups.removeAll { $0.id == id }
        for key in appAssignments.keys {
            // leave assignments; group membership is on the group
            _ = key
        }
        generation &+= 1
    }

    public func assignRoute(app: AppIdentityKey, route: RouteAction) {
        lock.lock(); defer { lock.unlock() }
        if route == .inherit {
            appAssignments.removeValue(forKey: app)
        } else {
            appAssignments[app] = route
        }
        generation &+= 1
    }

    public func addApp(_ app: AppIdentityKey, toGroup groupID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].add(app)
        generation &+= 1
    }

    public func removeApp(_ app: AppIdentityKey, fromGroup groupID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].remove(app)
        generation &+= 1
    }

    public func allRules() -> [NetworkPolicyRule] {
        lock.lock(); defer { lock.unlock() }
        return rules
    }

    public func allGroups() -> [AppGroup] {
        lock.lock(); defer { lock.unlock() }
        return groups
    }

    public func assignment(for app: AppIdentityKey) -> RouteAction {
        lock.lock(); defer { lock.unlock() }
        return appAssignments[app] ?? .inherit
    }

    // MARK: Compile snapshot

    public func compileSnapshot() -> RuleSnapshot {
        lock.lock()
        let rulesCopy = rules
        let groupsCopy = groups
        let assignmentsCopy = appAssignments
        let gen = generation
        lock.unlock()

        let compiled = rulesCopy
            .filter(\.enabled)
            .map { Self.compile($0, groups: groupsCopy) }

        let checksum = Self.checksum(generation: gen, ruleCount: compiled.count)
        return RuleSnapshot(
            generation: gen,
            checksum: checksum,
            rules: compiled,
            groups: groupsCopy,
            appAssignments: assignmentsCopy
        )
    }

    // MARK: - Compile helpers

    private static func compile(_ rule: NetworkPolicyRule, groups: [AppGroup]) -> CompiledRule {
        let groupLookup = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let appMatcher = rule.app
        let destMatcher = rule.destination
        let portMatcher = rule.ports
        let transport = rule.transport
        let direction = rule.direction

        let predicate: @Sendable (FlowDescriptor) -> Bool = { flow in
            if !matchesApp(appMatcher, flow: flow, groups: groupLookup) { return false }
            if !matchesDestination(destMatcher, flow: flow) { return false }
            if !portMatcher.matches(flow.remotePort) { return false }
            if transport != .any && flow.transport != transport && flow.transport != .any {
                return false
            }
            if let direction, flow.direction != direction { return false }
            return true
        }

        return CompiledRule(
            id: rule.id,
            priority: rule.priority,
            specificity: rule.specificity,
            firewall: rule.firewall,
            route: rule.route,
            predicate: predicate
        )
    }

    private static func matchesApp(
        _ matcher: AppMatcher,
        flow: FlowDescriptor,
        groups: [UUID: AppGroup]
    ) -> Bool {
        switch matcher {
        case .any:
            return true
        case .exact(let key):
            return flow.app == key
        case .signingID(let id):
            return flow.app.signingIdentifier == id
        case .group(let groupID):
            return groups[groupID]?.memberKeys.contains(flow.app) == true
        }
    }

    private static func matchesDestination(_ matcher: DestinationMatcher, flow: FlowDescriptor) -> Bool {
        switch matcher {
        case .any:
            return true
        case .hostnameExact(let host):
            return flow.remoteHostname?.caseInsensitiveCompare(host) == .orderedSame
        case .hostnameSuffix(let suffix):
            guard let host = flow.remoteHostname?.lowercased() else { return false }
            let s = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // Label-boundary only: "api.com" must not match "evilapi.com".
            return host == s || host.hasSuffix("." + s)
        case .ip(let address):
            return flow.remoteAddress == address
        case .cidr(let network, _):
            // Simplified: exact network string match or address prefix check placeholder
            return flow.remoteAddress == network || (flow.remoteAddress?.hasPrefix(network.split(separator: ".").first.map(String.init) ?? "___") == true)
        }
    }

    private static func checksum(generation: UInt64, ruleCount: Int) -> Data {
        var gen = generation
        var count = UInt64(ruleCount)
        var data = Data()
        withUnsafeBytes(of: &gen) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        return data
    }
}
