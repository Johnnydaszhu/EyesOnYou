import Foundation

public struct AppIdentityKey: Hashable, Codable, Sendable {
    public let teamIdentifier: String?
    public let signingIdentifier: String
}

public enum TransportProtocol: UInt8, Codable, Sendable {
    case any = 0
    case tcp = 1
    case udp = 2
    case other = 255
}

public enum FlowDirection: UInt8, Codable, Sendable {
    case outbound = 1
    case inbound = 2
}

public enum FirewallAction: UInt8, Codable, Sendable {
    case inherit = 0
    case observe = 1
    case allow = 2
    case block = 3
}

public enum RouteAction: Hashable, Codable, Sendable {
    case inherit
    case direct
    case systemProxy
    case proxy(profileID: UUID)
}

public struct FlowDescriptor: Hashable, Sendable {
    public let id: UUID
    public let app: AppIdentityKey
    public let direction: FlowDirection
    public let transport: TransportProtocol
    public let remoteHostname: String?
    public let remoteAddress: String?
    public let remotePort: UInt16?
    public let openedAt: Date
}

public struct FirewallDecision: Sendable {
    public let action: FirewallAction
    public let matchedRuleID: UUID?
}

public struct RouteDecision: Sendable {
    public let action: RouteAction
    public let matchedRuleID: UUID?
}
