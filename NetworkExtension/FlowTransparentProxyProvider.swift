import Foundation
import Network
import NetworkExtension
import OSLog
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouProxyCore
import EyesOnYouIPC

/// Selective transparent proxy: claim only flows whose app has an explicit route
/// or firewall rule; everything else is declined back to the OS untouched.
///
/// This is the per-flow precision path: unlike the system-proxy takeover it does
/// not depend on apps honoring proxy settings, and a TUN-mode VPN cannot shadow
/// it — flows are intercepted at the socket layer before any tunnel sees them.
/// Fail-open throughout: no rules, unknown app, or any internal error ⇒ decline.
final class FlowTransparentProxyProvider: NETransparentProxyProvider {
    private let log = Logger(subsystem: "com.example.EyesOnYou", category: "Proxy")
    private let runtime = ExtensionRuntime.shared

    /// The non-tunnel interface force-direct dials bind to. Tracked with a fresh
    /// monitor per start (a cancelled NWPathMonitor cannot be restarted).
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "eyesonyou.proxy.path")
    private let interfaceLock = NSLock()
    private var physicalInterface: NWInterface?

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try runtime.startIfNeeded()

            let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            // Ask for every outbound TCP flow; the per-app decision happens in
            // handleNewFlow, where declining is cheap and fail-open. Claiming
            // nothing here would mean never seeing rule-matched apps at all.
            let allTCP = NENetworkRule(
                remoteNetwork: nil,
                remotePrefix: 0,
                localNetwork: nil,
                localPrefix: 0,
                protocol: .TCP,
                direction: .outbound
            )
            settings.includedNetworkRules = [allTCP]
            settings.excludedNetworkRules = []

            let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.other, .loopback])
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.interfaceLock.lock()
                self.physicalInterface = path.availableInterfaces.first
                self.interfaceLock.unlock()
            }
            monitor.start(queue: monitorQueue)
            pathMonitor = monitor

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
        pathMonitor?.cancel()
        pathMonitor = nil
        log.info("Proxy stopped reason=\(String(describing: reason), privacy: .public)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard runtime.proxyEnabled else { return false }
        // v1 steers TCP only; UDP flows pass through untouched.
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else { return false }
        guard let target = runtime.makeProxyTarget(from: flow) else { return false }

        let plan = TransparentFlowPlanner.plan(
            app: target.app,
            host: target.host,
            port: target.port,
            rules: runtime.rules
        )
        if case .decline = plan {
            return false
        }

        let pump = TCPFlowPump(
            flow: tcpFlow,
            app: target.app,
            host: target.host,
            port: target.port,
            runtime: runtime
        )
        PumpRegistry.shared.add(pump)
        interfaceLock.lock()
        let interface = physicalInterface
        interfaceLock.unlock()
        pump.start(plan: plan, physicalInterface: interface)
        return true
    }

    /// Control channel from the host app (rules push, telemetry drain).
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        let reply: ExtensionToHostMessage
        do {
            switch try IPCCoding.decode(HostToExtensionMessage.self, from: messageData) {
            case .ping:
                reply = .pong
            case .setProxyEnabled(let enabled):
                runtime.setProxyEnabled(enabled)
                reply = .status(runtime.status)
            case .setFilterEnabled:
                reply = .status(runtime.status)
            case .pushRules(let payload):
                if runtime.apply(payload) {
                    runtime.setProxyEnabled(true)
                    reply = .status(runtime.status)
                } else {
                    reply = .error("rules payload undecodable; keeping previous rules")
                }
            case .requestStatus:
                reply = .status(runtime.status)
            case .requestFlowEvents:
                reply = .flowEvents(runtime.drainEvents(), status: runtime.status)
            }
        } catch {
            reply = .error("bad message: \(error.localizedDescription)")
        }
        completionHandler?(try? IPCCoding.encode(reply))
    }
}
