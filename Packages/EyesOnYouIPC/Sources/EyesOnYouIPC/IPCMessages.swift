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
        version: String = "0.1.1"
    ) {
        self.filterEnabled = filterEnabled
        self.proxyEnabled = proxyEnabled
        self.ruleGeneration = ruleGeneration
        self.providerReachable = providerReachable
        self.version = version
    }
}

public enum HostToExtensionMessage: Codable, Sendable {
    case ping
    case setFilterEnabled(Bool)
    case setProxyEnabled(Bool)
    case pushRuleSnapshot(generation: UInt64, checksum: Data)
    case requestStatus
}

public enum ExtensionToHostMessage: Codable, Sendable {
    case pong
    case status(ExtensionStatus)
    case telemetryTick(bytesUp: UInt64, bytesDown: UInt64, activeFlows: Int)
    case error(String)
}

public enum EyesOnYouConstants {
    public static let appGroupIdentifier = "group.com.example.EyesOnYou"
    public static let machServiceName = "com.example.EyesOnYou.xpc"
    public static let hostBundleID = "com.example.EyesOnYou"
    public static let extensionBundleID = "com.example.EyesOnYou.NetworkExtension"
}
