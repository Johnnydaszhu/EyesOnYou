import Foundation
import NetworkExtension

@MainActor
final class TransparentProxyManagerController {
    private let providerBundleIdentifier = "com.example.EyesOnYou.NetworkExtension"
    private var manager: NETransparentProxyManager?

    func loadOrCreate() async throws -> NETransparentProxyManager {
        let existing = try await NETransparentProxyManager.loadAllFromPreferences()
        if let first = existing.first {
            manager = first
            return first
        }

        let created = NETransparentProxyManager()
        manager = created
        return created
    }

    func installConfiguration() async throws {
        let manager = try await loadOrCreate()
        // Loading before saving is required after each app launch. For a newly
        // created manager, current SDK behavior must be verified in Phase 0.
        try await manager.loadFromPreferences()

        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        tunnelProtocol.serverAddress = "EyesOnYou Selective Proxy"
        tunnelProtocol.providerConfiguration = [
            "configurationVersion": 1
        ]

        manager.localizedDescription = "EyesOnYou Selective Proxy"
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    func start() async throws {
        guard let manager else { throw ProxyManagerError.notLoaded }
        try manager.connection.startVPNTunnel()
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    enum ProxyManagerError: Error { case notLoaded }
}
