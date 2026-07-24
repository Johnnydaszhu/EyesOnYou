import Foundation
import NetworkExtension
import SystemExtensions
import FlowLensIPC

/// Host-side controller for system extension activation and filter preferences.
@MainActor
final class FilterManagerController: NSObject, ObservableObject {
    @Published var statusMessage: String = "Not installed"
    @Published var filterEnabled: Bool = false

    private let extensionBundleIdentifier = FlowLensConstants.extensionBundleID

    func requestSystemExtensionActivation() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        statusMessage = "Activation requested"
    }

    func enableFilter() async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()

        let configuration = NEFilterProviderConfiguration()
        configuration.filterSockets = true
        configuration.filterBrowsers = false
        if #available(macOS 10.15, *) {
            // filterPackets may not exist on all SDKs; sockets-only is the v1 path.
        }
        configuration.filterDataProviderBundleIdentifier = extensionBundleIdentifier

        manager.providerConfiguration = configuration
        manager.localizedDescription = "FlowLens Network Filter"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        filterEnabled = true
        statusMessage = "Filter enabled (verify provider reachable)"
    }

    func disableFilter() async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        manager.isEnabled = false
        try await manager.saveToPreferences()
        filterEnabled = false
        statusMessage = "Filter disabled"
    }
}

extension FilterManagerController: OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        ext.bundleVersion.compare(existing.bundleVersion, options: .numeric) == .orderedDescending
            ? .replace
            : .cancel
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        statusMessage = "Needs user approval in System Settings › Privacy & Security"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        statusMessage = "Extension request finished: \(result.rawValue)"
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        statusMessage = "Extension request failed: \(error.localizedDescription)"
    }
}
