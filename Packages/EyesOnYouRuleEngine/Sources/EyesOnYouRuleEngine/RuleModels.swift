import Foundation
import EyesOnYouCore

// MARK: - Matchers

public enum AppMatcher: Hashable, Codable, Sendable {
    case any
    case exact(AppIdentityKey)
    case signingID(String)
    case group(UUID)
}

public enum DestinationMatcher: Hashable, Codable, Sendable {
    case any
    case hostnameExact(String)
    case hostnameSuffix(String)
    case ip(String)
    case cidr(network: String, prefix: UInt8)
}

public enum PortMatcher: Hashable, Codable, Sendable {
    case any
    case single(UInt16)
    case range(ClosedRange<UInt16>)

    public func matches(_ port: UInt16?) -> Bool {
        guard let port else {
            return self == .any
        }
        switch self {
        case .any: return true
        case .single(let p): return p == port
        case .range(let r): return r.contains(port)
        }
    }
}

// MARK: - Named app group (shared route / firewall decision)

public struct AppGroup: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var memberKeys: Set<AppIdentityKey>
    public var defaultRoute: RouteAction
    public var defaultFirewall: FirewallAction

    public init(
        id: UUID = UUID(),
        name: String,
        memberKeys: Set<AppIdentityKey> = [],
        defaultRoute: RouteAction = .inherit,
        defaultFirewall: FirewallAction = .inherit
    ) {
        self.id = id
        self.name = name
        self.memberKeys = memberKeys
        self.defaultRoute = defaultRoute
        self.defaultFirewall = defaultFirewall
    }

    public mutating func add(_ app: AppIdentityKey) {
        memberKeys.insert(app)
    }

    public mutating func remove(_ app: AppIdentityKey) {
        memberKeys.remove(app)
    }
}

// MARK: - Policy rule

public struct NetworkPolicyRule: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var enabled: Bool
    public var priority: Int32
    public var app: AppMatcher
    public var destination: DestinationMatcher
    public var ports: PortMatcher
    public var transport: TransportProtocol
    public var direction: FlowDirection?
    public var firewall: FirewallAction
    public var route: RouteAction
    public var note: String?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        priority: Int32 = 0,
        app: AppMatcher = .any,
        destination: DestinationMatcher = .any,
        ports: PortMatcher = .any,
        transport: TransportProtocol = .any,
        direction: FlowDirection? = nil,
        firewall: FirewallAction = .inherit,
        route: RouteAction = .inherit,
        note: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.enabled = enabled
        self.priority = priority
        self.app = app
        self.destination = destination
        self.ports = ports
        self.transport = transport
        self.direction = direction
        self.firewall = firewall
        self.route = route
        self.note = note
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Rough specificity for precedence (higher wins when priority ties).
    public var specificity: UInt64 {
        var score: UInt64 = 0
        switch app {
        case .any: break
        case .signingID: score += 10
        case .group: score += 20
        case .exact: score += 40
        }
        switch destination {
        case .any: break
        case .hostnameSuffix: score += 10
        case .hostnameExact: score += 20
        case .ip: score += 30
        case .cidr: score += 25
        }
        switch ports {
        case .any: break
        case .range: score += 5
        case .single: score += 10
        }
        if transport != .any { score += 5 }
        if direction != nil { score += 2 }
        return score
    }
}

// MARK: - Per-app route assignment (UI toggle convenience)

public struct AppRouteAssignment: Hashable, Codable, Sendable {
    public var app: AppIdentityKey
    public var route: RouteAction
    public var groupID: UUID?

    public init(app: AppIdentityKey, route: RouteAction, groupID: UUID? = nil) {
        self.app = app
        self.route = route
        self.groupID = groupID
    }
}
