import Foundation
import EyesOnYouCore

/// Shared IPC message models between host app and system extension.
/// Pure Codable — no NetworkExtension dependency.

public enum ProviderKind: String, Codable, Sendable {
    case filter
    case transparentProxy
}

public struct ExtensionStatus: Codable, Sendable, Equatable {
    public var filterEnabled: Bool
    public var proxyEnabled: Bool
    public var ruleGeneration: UInt64
    public var providerReachable: Bool
    public var version: String

    public init(
        filterEnabled: Bool = false,
        proxyEnabled: Bool = false,
        ruleGeneration: UInt64 = 0,
        providerReachable: Bool = false,
        version: String = "0.1.3"
    ) {
        self.filterEnabled = filterEnabled
        self.proxyEnabled = proxyEnabled
        self.ruleGeneration = ruleGeneration
        self.providerReachable = providerReachable
        self.version = version
    }
}

/// Everything the transparent proxy provider needs to route flows, as one blob:
/// the policy archive (rules + groups + profiles, PolicyArchive JSON) plus the
/// upstream that holds the system-proxy slot (captured by the host from the
/// merged config). Encoded as Data so this package stays free of ProxyCore.
public struct ProxyRulesPayload: Codable, Sendable, Equatable {
    public var generation: UInt64
    public var policyArchiveJSON: Data
    public var systemUpstreamHost: String?
    public var systemUpstreamPort: UInt16?
    /// "http" | "socks5"
    public var systemUpstreamKind: String?

    public init(
        generation: UInt64,
        policyArchiveJSON: Data,
        systemUpstreamHost: String? = nil,
        systemUpstreamPort: UInt16? = nil,
        systemUpstreamKind: String? = nil
    ) {
        self.generation = generation
        self.policyArchiveJSON = policyArchiveJSON
        self.systemUpstreamHost = systemUpstreamHost
        self.systemUpstreamPort = systemUpstreamPort
        self.systemUpstreamKind = systemUpstreamKind
    }
}

/// One completed (or blocked) flow the provider handled — exact bytes, measured.
public struct FlowEventSample: Codable, Sendable, Equatable {
    public var signingIdentifier: String
    public var host: String
    public var port: UInt16
    /// "direct" | "upstream" | "block" | "refused"
    public var action: String
    public var bytesUp: UInt64
    public var bytesDown: UInt64

    public init(
        signingIdentifier: String,
        host: String,
        port: UInt16,
        action: String,
        bytesUp: UInt64,
        bytesDown: UInt64
    ) {
        self.signingIdentifier = signingIdentifier
        self.host = host
        self.port = port
        self.action = action
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
    }
}

public enum HostToExtensionMessage: Codable, Sendable {
    case ping
    case setFilterEnabled(Bool)
    case setProxyEnabled(Bool)
    case pushRules(ProxyRulesPayload)
    case requestStatus
    /// Drain buffered flow events (the provider forgets what it hands over).
    case requestFlowEvents
}

public enum ExtensionToHostMessage: Codable, Sendable {
    case pong
    case status(ExtensionStatus)
    case telemetryTick(bytesUp: UInt64, bytesDown: UInt64, activeFlows: Int)
    case flowEvents([FlowEventSample], status: ExtensionStatus)
    case error(String)
}

/// JSON wire helpers so both processes agree on encoding.
public enum IPCCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public enum EyesOnYouConstants {
    public static let appGroupIdentifier = "group.com.example.EyesOnYou"
    public static let machServiceName = "com.example.EyesOnYou.xpc"
    public static let hostBundleID = "com.example.EyesOnYou"
    public static let extensionBundleID = "com.example.EyesOnYou.NetworkExtension"
}
