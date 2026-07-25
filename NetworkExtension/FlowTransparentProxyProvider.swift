import Foundation
import NetworkExtension
import OSLog
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouProxyCore

/// Selective transparent proxy: claim only routes that match proxy rules.
/// Default-off / fail-open: return false so the OS handles the flow directly.
final class FlowTransparentProxyProvider: NETransparentProxyProvider {
    private let log = Logger(subsystem: "com.example.EyesOnYou", category: "Proxy")
    private let runtime = ExtensionRuntime.shared

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try runtime.startIfNeeded()
            guard runtime.proxyEnabled else {
                log.info("Proxy provider started but selective proxy is disabled — no claim")
                completionHandler(nil)
                return
            }

            let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            // Empty included rules ⇒ no flows offered until configured (safe default).
            settings.includedNetworkRules = []
            settings.excludedNetworkRules = []

            setTunnelNetworkSettings(settings) { error in
                if let error {
                    self.log.error("transparent proxy settings failed: \(error.localizedDescription, privacy: .public)")
                }
                completionHandler(error)
            }
        } catch {
            log.error("proxy start failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(nil) // fail-open
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("Proxy stopped reason=\(String(describing: reason), privacy: .public)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard runtime.proxyEnabled else { return false }

        guard let descriptor = runtime.makeProxyDescriptor(from: flow) else {
            return false
        }

        let result = ProxyRouteEvaluator.shouldClaimFlow(descriptor, snapshot: runtime.rules)
        if !result.claim {
            return false
        }

        // Production would open app-side, handshake upstream (HTTP CONNECT / SOCKS5),
        // and run bounded bidirectional pumps. Scaffold returns false until profiles
        // and flow-copy sessions are fully implemented — fail-open.
        log.info("Would claim flow for proxy route \(String(describing: result.decision.action), privacy: .public)")
        return false
    }
}
