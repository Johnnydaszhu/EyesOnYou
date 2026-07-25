import Foundation
import NetworkExtension
import SystemExtensions

@MainActor
final class FilterManagerController: NSObject {
    private let extensionBundleIdentifier = "com.example.EyesOnYou.NetworkExtension"
    private let filterProviderBundleIdentifier = "com.example.EyesOnYou.NetworkExtension"

    func requestSystemExtensionActivation() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func enableFilter() async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()

        let configuration = NEFilterProviderConfiguration()
        configuration.filterSockets = true
        configuration.filterBrowsers = false
        configuration.filterPackets = false
        configuration.filterDataProviderBundleIdentifier = filterProviderBundleIdentifier

        manager.providerConfiguration = configuration
        manager.localizedDescription = "EyesOnYou Network Filter"
        manager.isEnabled = true
        try await manager.saveToPreferences()

        // Saving is not enough: next, query provider status/XPC and show the
        // actual running version and active rule generation in the UI.
    }

    func disableFilter() async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        manager.isEnabled = false
        try await manager.saveToPreferences()
    }
}

extension FilterManagerController: OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        ext.bundleVersion > existing.bundleVersion ? .replace : .cancel
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // Update the UI with exact System Settings guidance; do not busy-wait.
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        // Continue to NEFilterManager configuration.
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        // Surface a recoverable diagnostic state.
    }
}
