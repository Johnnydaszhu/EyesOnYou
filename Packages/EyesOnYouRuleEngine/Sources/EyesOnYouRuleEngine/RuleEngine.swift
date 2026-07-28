import Foundation
import Darwin
import EyesOnYouCore

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
    /// Group defaults are evaluated for every flow. Build the exclusive lookup once
    /// instead of scanning every group on every route and firewall decision.
    ///
    /// `groups` is ordered user state, so the first group wins deterministically if
    /// malformed imported policy places the same app in more than one group.
    private let groupByApp: [AppIdentityKey: AppGroup]
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
        var groupByApp: [AppIdentityKey: AppGroup] = [:]
        for group in groups {
            for app in group.memberKeys where groupByApp[app] == nil {
                groupByApp[app] = group
            }
        }
        self.groupByApp = groupByApp
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

        // Nothing matched. That is not the same as "bypass the proxy": an app with no
        // EyesOnYou policy keeps whatever macOS system proxy settings say, so report
        // `.inherit` (follow the system) rather than asserting `.direct`.
        // `ProxyRouteEvaluator` still declines to claim `.inherit`, so the fail-open
        // behaviour of the transparent proxy is unchanged.
        return RouteDecision(action: .inherit, matchedRuleID: nil)
    }

    private func groupContaining(_ app: AppIdentityKey) -> AppGroup? {
        groupByApp[app]
    }
}

// MARK: - Mutable policy store → snapshot compiler

public final class PolicyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [NetworkPolicyRule] = []
    private var groups: [AppGroup] = []
    private var appAssignments: [AppIdentityKey: RouteAction] = [:]
    private var generation: UInt64 = 0
    private var cachedSnapshot: RuleSnapshot?

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
        didMutate()
    }

    public func removeRule(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        rules.removeAll { $0.id == id }
        didMutate()
    }

    public func setRules(_ newRules: [NetworkPolicyRule]) {
        lock.lock(); defer { lock.unlock() }
        rules = newRules
        didMutate()
    }

    public func upsert(group: AppGroup) {
        lock.lock(); defer { lock.unlock() }
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        } else {
            groups.append(group)
        }
        didMutate()
    }

    public func removeGroup(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        groups.removeAll { $0.id == id }
        didMutate()
    }

    public func assignRoute(app: AppIdentityKey, route: RouteAction) {
        lock.lock(); defer { lock.unlock() }
        if route == .inherit {
            appAssignments.removeValue(forKey: app)
        } else {
            appAssignments[app] = route
        }
        didMutate()
    }

    public func addApp(_ app: AppIdentityKey, toGroup groupID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].add(app)
        didMutate()
    }

    public func removeApp(_ app: AppIdentityKey, fromGroup groupID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].remove(app)
        didMutate()
    }

    /// Exclusive membership: remove `app` from every group, then optionally add to `groupID`.
    public func moveApp(_ app: AppIdentityKey, toGroup groupID: UUID?) {
        lock.lock(); defer { lock.unlock() }
        for i in groups.indices {
            groups[i].remove(app)
        }
        if let groupID, let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].add(app)
        }
        didMutate()
    }

    /// Reorder groups to match `orderedIDs` (unknown ids appended at end).
    public func reorderGroups(orderedIDs: [UUID]) {
        lock.lock(); defer { lock.unlock() }
        var remaining = groups
        var next: [AppGroup] = []
        next.reserveCapacity(groups.count)
        for id in orderedIDs {
            if let index = remaining.firstIndex(where: { $0.id == id }) {
                next.append(remaining.remove(at: index))
            }
        }
        // Preserve the existing order for ids the caller did not mention.
        next.append(contentsOf: remaining)
        groups = next
        didMutate()
    }

    public func allRules() -> [NetworkPolicyRule] {
        lock.lock(); defer { lock.unlock() }
        return rules
    }

    public func allGroups() -> [AppGroup] {
        lock.lock(); defer { lock.unlock() }
        return groups
    }

    public func setGroups(_ newGroups: [AppGroup]) {
        lock.lock(); defer { lock.unlock() }
        groups = newGroups
        didMutate()
    }

    /// Every explicit per-app route assignment (`.inherit` is absence, never a value).
    public func allAssignments() -> [AppIdentityKey: RouteAction] {
        lock.lock(); defer { lock.unlock() }
        return appAssignments
    }

    public func setAssignments(_ assignments: [AppIdentityKey: RouteAction]) {
        lock.lock(); defer { lock.unlock() }
        appAssignments = assignments.filter { $0.value != .inherit }
        didMutate()
    }

    public func assignment(for app: AppIdentityKey) -> RouteAction {
        lock.lock(); defer { lock.unlock() }
        return appAssignments[app] ?? .inherit
    }

    /// How many rules are enabled.
    ///
    /// The dashboard shows this once a second. Reading it off `compileSnapshot()`
    /// meant compiling every rule into a matcher closure — and rebuilding a group
    /// lookup table per rule — to produce an integer.
    public func activeRuleCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return rules.reduce(0) { $1.enabled ? $0 + 1 : $0 }
    }

    // MARK: Compile snapshot

    public func compileSnapshot() -> RuleSnapshot {
        lock.lock()
        if let cachedSnapshot, cachedSnapshot.generation == generation {
            lock.unlock()
            return cachedSnapshot
        }
        let rulesCopy = rules
        let groupsCopy = groups
        let assignmentsCopy = appAssignments
        let gen = generation
        lock.unlock()

        // One lookup for the whole compile; it used to be rebuilt for every rule.
        var groupLookup: [UUID: AppGroup] = [:]
        for group in groupsCopy where groupLookup[group.id] == nil {
            groupLookup[group.id] = group
        }
        let compiled = rulesCopy
            .filter(\.enabled)
            .map { Self.compile($0, groupLookup: groupLookup) }

        let checksum = Self.checksum(generation: gen, ruleCount: compiled.count)
        let snapshot = RuleSnapshot(
            generation: gen,
            checksum: checksum,
            rules: compiled,
            groups: groupsCopy,
            appAssignments: assignmentsCopy
        )

        // Another caller may have compiled the same generation while this one was
        // outside the lock. Reuse that object so each generation has one cache entry.
        lock.lock()
        if generation == gen {
            if let cachedSnapshot, cachedSnapshot.generation == gen {
                lock.unlock()
                return cachedSnapshot
            }
            cachedSnapshot = snapshot
        }
        lock.unlock()
        return snapshot
    }

    // MARK: - Compile helpers

    private static func compile(
        _ rule: NetworkPolicyRule,
        groupLookup: [UUID: AppGroup]
    ) -> CompiledRule {
        let appMatcher = rule.app
        let destMatcher = CompiledDestinationMatcher(rule.destination)
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

    private static func matchesDestination(
        _ matcher: CompiledDestinationMatcher,
        flow: FlowDescriptor
    ) -> Bool {
        switch matcher {
        case .any:
            return true
        case .hostnameExact(let host):
            return flow.remoteHostname?.lowercased() == host
        case .hostnameSuffix(let suffix):
            guard let host = flow.remoteHostname?.lowercased() else { return false }
            // Label-boundary only: "api.com" must not match "evilapi.com".
            return host == suffix || host.hasSuffix("." + suffix)
        case .ip(let address):
            guard let remote = flow.remoteAddress.flatMap(IPAddress.init(flowAddress:)) else {
                return false
            }
            return remote == address
        case .cidr(let network):
            guard let remote = flow.remoteAddress else { return false }
            return network.contains(remote)
        case .never:
            return false
        }
    }

    /// Every mutation changes the generation and invalidates the corresponding
    /// immutable snapshot. Caller must hold `lock`.
    private func didMutate() {
        generation &+= 1
        cachedSnapshot = nil
    }

    private enum CompiledDestinationMatcher: Sendable {
        case any
        case hostnameExact(String)
        case hostnameSuffix(String)
        case ip(IPAddress)
        case cidr(IPNetwork)
        case never

        init(_ matcher: DestinationMatcher) {
            switch matcher {
            case .any:
                self = .any
            case .hostnameExact(let raw):
                let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                self = host.isEmpty ? .never : .hostnameExact(host)
            case .hostnameSuffix(let raw):
                let host = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                self = host.isEmpty ? .never : .hostnameSuffix(host)
            case .ip(let raw):
                self = IPAddress(ruleAddress: raw).map(Self.ip) ?? .never
            case .cidr(let raw, let prefix):
                self = IPNetwork(address: raw, prefix: prefix).map(Self.cidr) ?? .never
            }
        }
    }

    /// Canonical binary representation used by exact-IP and CIDR matchers.
    private struct IPAddress: Equatable, Sendable {
        enum Family: Equatable, Sendable {
            case ipv4
            case ipv6
        }

        let family: Family
        let bytes: [UInt8]

        init?(ruleAddress raw: String) {
            self.init(raw, permitsIPv6Scope: false)
        }

        init?(flowAddress raw: String) {
            self.init(raw, permitsIPv6Scope: true)
        }

        private init?(_ raw: String, permitsIPv6Scope: Bool) {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            if permitsIPv6Scope, let percent = text.firstIndex(of: "%") {
                text = String(text[..<percent])
            } else if text.contains("%") {
                return nil
            }

            var ipv4 = in_addr()
            if inet_pton(AF_INET, text, &ipv4) == 1 {
                family = .ipv4
                bytes = withUnsafeBytes(of: ipv4) { Array($0) }
                return
            }

            var ipv6 = in6_addr()
            if inet_pton(AF_INET6, text, &ipv6) == 1 {
                family = .ipv6
                bytes = withUnsafeBytes(of: ipv6) { Array($0) }
                return
            }
            return nil
        }
    }

    /// A validated, masked network. The textual rule is parsed once at snapshot
    /// compilation; evaluation compares bytes and never performs string-prefix work.
    private struct IPNetwork: Sendable {
        let family: IPAddress.Family
        let maskedAddress: [UInt8]
        let wholeBytes: Int
        let partialMask: UInt8

        init?(address raw: String, prefix: UInt8) {
            guard let address = IPAddress(ruleAddress: raw) else { return nil }
            let bitCount = address.bytes.count * 8
            guard Int(prefix) <= bitCount else { return nil }

            family = address.family
            wholeBytes = Int(prefix) / 8
            let remainingBits = Int(prefix) % 8
            partialMask = remainingBits == 0 ? 0 : UInt8.max << (8 - remainingBits)

            var masked = address.bytes
            if wholeBytes < masked.count {
                if partialMask != 0 {
                    masked[wholeBytes] &= partialMask
                }
                let zeroFrom = wholeBytes + (partialMask == 0 ? 0 : 1)
                if zeroFrom < masked.count {
                    for index in zeroFrom..<masked.count {
                        masked[index] = 0
                    }
                }
            }
            maskedAddress = masked
        }

        func contains(_ raw: String) -> Bool {
            guard let address = IPAddress(flowAddress: raw),
                  address.family == family,
                  address.bytes.count == maskedAddress.count
            else { return false }

            if wholeBytes > 0,
               address.bytes[..<wholeBytes] != maskedAddress[..<wholeBytes] {
                return false
            }
            guard partialMask != 0 else { return true }
            return (address.bytes[wholeBytes] & partialMask) == maskedAddress[wholeBytes]
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
