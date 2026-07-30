import Foundation
import NetworkExtension
import SystemExtensions
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouProxyCore
import EyesOnYouIPC

/// Host-side driver for the NetworkExtension transparent proxy — the precise
/// enforcement path ("精确模式").
///
/// Why this exists alongside `ProxyEnforcementController`: the system-proxy
/// takeover only steers apps that honor proxy settings, and a TUN-mode VPN can
/// shadow it entirely. A transparent proxy intercepts flows at the socket layer,
/// so per-app rules apply to every app and no tunnel can outrank it — at the cost
/// of a system extension, which needs a signed Network Extension entitlement.
///
/// Everything is off unless the user turns it on, and every failure state is
/// named rather than silently degraded: `docs/NE-SIGNING.md` explains what the
/// `.notEntitled` path means for people running an unsigned build.
@MainActor
final class TransparentProxyController: NSObject, ObservableObject {
    enum Status: Equatable {
        case off
        /// Waiting on the system extension to install / be approved.
        case installing(String)
        /// Extension is present and the proxy configuration is enabled.
        case active(ruleGeneration: UInt64)
        /// This build cannot load a system extension: no Network Extension
        /// entitlement in the signature (ad-hoc / fork build).
        case notEntitled
        /// The user has to approve in System Settings › Privacy & Security.
        case needsApproval
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    /// Measured per-flow byte samples the extension has handed over.
    var onFlowSamples: (([FlowEventSample]) -> Void)?
    var onStatus: ((Status) -> Void)?

    private let extensionBundleID = EyesOnYouConstants.extensionBundleID
    private var manager: NETransparentProxyManager?
    private var pendingRules: ProxyRulesPayload?
    private var generation: UInt64 = 0
    private var pollTimer: Timer?

    var isActive: Bool {
        if case .active = status { return true }
        return false
    }

    // MARK: - Enable / disable

    /// Install (if needed) and enable the transparent proxy, then push rules.
    func enable(rules: ProxyRulesPayload) {
        pendingRules = rules
        switch status {
        case .active:
            pushRules()
            return
        case .installing:
            return
        default:
            break
        }
        setStatus(.installing("requesting system extension"))
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func disable() {
        pollTimer?.invalidate()
        pollTimer = nil
        Task { @MainActor in
            do {
                let manager = try await loadManager()
                manager.isEnabled = false
                try await manager.saveToPreferences()
            } catch {
                // Nothing to disable is a success from the user's point of view.
            }
            self.setStatus(.off)
        }
    }

    /// Deactivate and uninstall the system extension entirely.
    func uninstall() {
        disable()
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Push new rules to a running provider (called on every policy change).
    func updateRules(_ rules: ProxyRulesPayload) {
        pendingRules = rules
        guard isActive else { return }
        pushRules()
    }

    // MARK: - Configuration

    /// Reuse our saved configuration when there is one, else create it.
    ///
    /// `NETransparentProxyManager` has no `shared()` of its own (the inherited one
    /// hands back the VPN singleton), so configurations are enumerated instead —
    /// and only ours, by provider bundle ID, is ever touched.
    private func loadManager() async throws -> NETransparentProxyManager {
        if let manager { return manager }
        let existing = try await NETransparentProxyManager.loadAllFromPreferences()
        let mine = existing.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == extensionBundleID
        }
        let manager = mine ?? NETransparentProxyManager()
        if mine != nil {
            try await manager.loadFromPreferences()
        }
        self.manager = manager
        return manager
    }

    private func configureAndStart() {
        Task { @MainActor in
            do {
                let manager = try await loadManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = extensionBundleID
                // Required by NE even for a transparent proxy; nothing dials it.
                proto.serverAddress = "127.0.0.1"
                manager.protocolConfiguration = proto
                manager.localizedDescription = "\(AppBrand.displayName) Per-App Routing"
                manager.isEnabled = true
                try await manager.saveToPreferences()
                // Re-load: saving invalidates the in-memory connection object.
                try await manager.loadFromPreferences()
                try manager.connection.startVPNTunnel()
                self.pushRules()
                self.startPolling()
            } catch {
                self.setStatus(.failed("proxy configuration: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Provider messaging

    private func pushRules() {
        guard let rules = pendingRules else { return }
        send(.pushRules(rules)) { [weak self] reply in
            guard let self else { return }
            switch reply {
            case .status(let status):
                self.generation = status.ruleGeneration
                self.setStatus(.active(ruleGeneration: status.ruleGeneration))
            case .error(let message):
                self.setStatus(.failed(message))
            default:
                break
            }
        }
    }

    /// Drain measured flow samples from the provider on a timer. The provider
    /// buffers a bounded number and forgets them once handed over, so nothing
    /// accumulates if the app is closed.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainFlowEvents() }
        }
        pollTimer = timer
    }

    private func drainFlowEvents() {
        send(.requestFlowEvents) { [weak self] reply in
            guard let self, case .flowEvents(let samples, let status) = reply else { return }
            self.generation = status.ruleGeneration
            if !samples.isEmpty {
                self.onFlowSamples?(samples)
            }
        }
    }

    private func send(
        _ message: HostToExtensionMessage,
        _ completion: @escaping (ExtensionToHostMessage) -> Void
    ) {
        guard let session = manager?.connection as? NETunnelProviderSession,
              let data = try? IPCCoding.encode(message) else {
            return
        }
        do {
            try session.sendProviderMessage(data) { reply in
                guard let reply,
                      let decoded = try? IPCCoding.decode(ExtensionToHostMessage.self, from: reply) else {
                    return
                }
                Task { @MainActor in completion(decoded) }
            }
        } catch {
            // Provider not running yet (or just stopped): the next tick retries.
        }
    }

    private func setStatus(_ next: Status) {
        status = next
        onStatus?(next)
    }
}

// MARK: - System extension lifecycle

extension TransparentProxyController: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always replace: a stale extension bundle silently keeps old routing code.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.setStatus(.needsApproval) }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.configureAndStart()
            case .willCompleteAfterReboot:
                self.setStatus(.installing("will finish after reboot"))
            @unknown default:
                self.setStatus(.installing("unknown result \(result.rawValue)"))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            // Name the entitlement case: for an ad-hoc or fork build this is the
            // expected outcome, not a bug to hunt.
            let nsError = error as NSError
            if nsError.domain == OSSystemExtensionErrorDomain,
               nsError.code == OSSystemExtensionError.Code.validationFailed.rawValue
                || nsError.code == OSSystemExtensionError.Code.authorizationRequired.rawValue {
                self.setStatus(.notEntitled)
                return
            }
            self.setStatus(.failed(error.localizedDescription))
        }
    }
}

// MARK: - Payload building

extension ProxyRulesPayload {
    /// Snapshot the host's current policy for the extension.
    static func build(
        generation: UInt64,
        store: PolicyStore,
        profiles: [ProxyProfile],
        systemUpstream: ProxyUpstream?
    ) -> ProxyRulesPayload? {
        let archive = PolicyArchive.capture(from: store, proxyProfiles: profiles)
        guard let json = try? JSONEncoder().encode(archive) else { return nil }
        return ProxyRulesPayload(
            generation: generation,
            policyArchiveJSON: json,
            systemUpstreamHost: systemUpstream?.host,
            systemUpstreamPort: systemUpstream?.port,
            systemUpstreamKind: systemUpstream.map { $0.kind == .socks5 ? "socks5" : "http" }
        )
    }
}
