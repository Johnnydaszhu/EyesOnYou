import Foundation
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouProxyCore

/// Drives the local enforcement proxy and the system-proxy takeover as one unit.
///
/// Off by default. Turning it on is the difference between EyesOnYou *observing*
/// traffic and actually *steering* it: the local proxy applies each app's route rule
/// (direct / via the previous system proxy / block), and the system proxy is pointed
/// at it so apps' traffic really flows through. Turning it off — or the app quitting,
/// or crashing — restores the previous system proxy settings.
@MainActor
final class ProxyEnforcementController: ObservableObject {
    enum Status: Equatable {
        case off
        case starting
        case active(port: UInt16, upstream: ProxyUpstream?)
        case failed(String)
    }

    @Published private(set) var status: Status = .off

    /// Emitted for every completed flow so the model can record exact byte counts.
    var onFlow: ((LocalProxyServer.FlowEvent) -> Void)?

    private let rulesBox: LocalProxyRulesBox
    private let server: LocalProxyServer
    private let systemProxy: SystemProxyController
    private var currentUpstream: ProxyUpstream?

    init(backupURL: URL) {
        let box = LocalProxyRulesBox(
            LocalProxyRules(snapshot: PolicyStore().compileSnapshot(), systemUpstream: nil, profiles: [])
        )
        self.rulesBox = box
        self.systemProxy = SystemProxyController(backupURL: backupURL)

        // Capture the flow handler weakly through a holder so the server (which
        // outlives a single call) never retains `self`.
        let holder = FlowHandlerHolder()
        self.server = LocalProxyServer(
            rules: box,
            onFlow: { event in holder.handler?(event) }
        )
        holder.handler = { [weak self] event in
            Task { @MainActor in self?.onFlow?(event) }
        }
    }

    /// Whether a takeover backup is on disk from a previous (possibly crashed) run.
    var hasPendingBackup: Bool { systemProxy.hasPendingBackup }

    /// Restore system proxy settings left behind by a crash while enforcement was on.
    /// Safe to call unconditionally at launch.
    func recoverFromCrashIfNeeded() {
        _ = systemProxy.restoreIfNeeded()
    }

    /// Rebuild the rules the running proxy consults. Call on any policy change.
    func updateRules(snapshot: RuleSnapshot, profiles: [ProxyProfile]) {
        rulesBox.update(LocalProxyRules(
            snapshot: snapshot,
            systemUpstream: currentUpstream,
            profiles: profiles
        ))
    }

    /// Start enforcing: bind the proxy, then take over the system proxy.
    func enable(snapshot: RuleSnapshot, profiles: [ProxyProfile]) {
        guard case .off = status else { return }
        status = .starting

        server.start(preferredPort: 0)
        // Wait for the listener to report its port before touching system settings —
        // pointing the OS at a port that never opened would break all networking.
        waitForRunningPort { [weak self] result in
            guard let self else { return }
            switch result {
            case .failed(let message):
                self.status = .failed(message)
            case .ready(let port):
                do {
                    let backup = try self.systemProxy.takeOver(localPort: port)
                    self.currentUpstream = backup.upstream
                    self.rulesBox.update(LocalProxyRules(
                        snapshot: snapshot,
                        systemUpstream: backup.upstream,
                        profiles: profiles
                    ))
                    self.status = .active(port: port, upstream: backup.upstream)
                } catch {
                    // Could not save a restore point — refuse takeover, tear down.
                    self.server.stop()
                    self.status = .failed("takeover: \(error)")
                }
            }
        }
    }

    /// Stop enforcing and restore the previous system proxy settings.
    func disable() {
        _ = systemProxy.restoreIfNeeded()
        server.stop()
        currentUpstream = nil
        status = .off
    }

    // MARK: - Internals

    private enum PortResult {
        case ready(UInt16)
        case failed(String)
    }

    private func waitForRunningPort(
        attempt: Int = 0,
        _ completion: @escaping (PortResult) -> Void
    ) {
        switch server.state {
        case .running(let port):
            completion(.ready(port))
        case .failed(let message):
            completion(.failed(message))
        default:
            guard attempt < 40 else {
                completion(.failed("proxy did not start in time"))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForRunningPort(attempt: attempt + 1, completion)
            }
        }
    }
}

/// Lets the server's escaping flow handler reach the actor without retaining it.
private final class FlowHandlerHolder: @unchecked Sendable {
    var handler: (@Sendable (LocalProxyServer.FlowEvent) -> Void)?
}
