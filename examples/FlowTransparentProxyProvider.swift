import Foundation
import Network
import NetworkExtension
import OSLog

/// Architecture skeleton. The actual TCP/UDP flow APIs and network-rule
/// initializer spelling must be compiled against the current macOS SDK.
final class FlowTransparentProxyProvider: NETransparentProxyProvider {
    private let log = Logger(subsystem: "com.example.EyesOnYou", category: "Proxy")
    private let runtime = ProxyRuntime.shared

    override func startProxy(
        options: [String : Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try runtime.startIfNeeded()

            let settings = NETransparentProxyNetworkSettings(
                tunnelRemoteAddress: "127.0.0.1"
            )
            settings.includedNetworkRules = runtime.makeIncludedRules()
            settings.excludedNetworkRules = runtime.makeExcludedRules()

            setTunnelNetworkSettings(settings) { error in
                if let error {
                    self.log.error("transparent proxy settings failed: \(error.localizedDescription, privacy: .public)")
                }
                completionHandler(error)
            }
        } catch {
            completionHandler(error)
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        runtime.cancelAllSessions(reason: reason)
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let descriptor = runtime.descriptorFactory.makeProxyDescriptor(from: flow) else {
            return false // Transparent proxy: let the OS handle unclassified flow.
        }

        if runtime.recursionGuard.mustBypass(descriptor) {
            return false
        }

        let decision = runtime.rules.current.evaluateRoute(descriptor)
        switch decision.action {
        case .inherit, .direct:
            runtime.telemetry.recordDirect(descriptor, decision: decision)
            return false

        case .systemProxy, .proxy:
            guard runtime.sessions.claim(flow: flow, descriptor: descriptor, decision: decision) else {
                // Apply the selected profile's explicit failure policy here.
                return false
            }
            return true
        }
    }
}

final class ProxyRuntime: @unchecked Sendable {
    static let shared = ProxyRuntime()
    let descriptorFactory = ProxyDescriptorFactory()
    let recursionGuard = RecursionGuard()
    let rules = AtomicRuleStore()
    let telemetry = ProxyTelemetry()
    let sessions = ProxySessionRegistry()

    func startIfNeeded() throws {}
    func makeIncludedRules() -> [NENetworkRule] { [] }
    func makeExcludedRules() -> [NENetworkRule] { [] }
    func cancelAllSessions(reason: NEProviderStopReason) {}
}

final class ProxyDescriptorFactory {
    func makeProxyDescriptor(from flow: NEAppProxyFlow) -> FlowDescriptor? { nil }
}
final class RecursionGuard { func mustBypass(_ flow: FlowDescriptor) -> Bool { false } }
final class ProxyTelemetry { func recordDirect(_ flow: FlowDescriptor, decision: RouteDecision) {} }
final class ProxySessionRegistry {
    func claim(flow: NEAppProxyFlow, descriptor: FlowDescriptor, decision: RouteDecision) -> Bool {
        // Retain flow, open app side, create NWConnection, perform optional
        // HTTP CONNECT/SOCKS5 handshake, then start bounded bidirectional pumps.
        false
    }
}
