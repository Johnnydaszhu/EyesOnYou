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
        /// Takeover succeeded at the networksetup layer, but a VPN's
        /// NetworkExtension-provided proxy settings win in the merged config apps
        /// actually read — so no flows reach us while its tunnel is up. Not a
        /// failure: the takeover stays in place and flips to `.active` on its own
        /// the moment the tunnel drops.
        case shadowedByVPN(port: UInt16, observedProxy: String?)
        case failed(FailureReason)
    }

    /// Why enforcement could not reach `.active`. Structured so the UI can explain
    /// the cause in the user's language and offer the matching fix, instead of
    /// burying a raw English string in a tooltip.
    enum FailureReason: Equatable {
        /// PAC / auto-discovery system proxy — HTTP/HTTPS takeover cannot chain to it.
        case unsupportedSystemProxy
        /// The local routing proxy never bound its port.
        case serverStart(String)
        /// Saving the restore point or applying the takeover failed.
        case takeover(String)
        /// The merged config never showed the EyesOnYou port and no competitor was visible.
        case notActivated
    }

    @Published private(set) var status: Status = .off
    var onStatus: ((Status) -> Void)?

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
    func enable(
        snapshot: RuleSnapshot,
        profiles: [ProxyProfile],
        systemUpstreamHint: ProxyUpstream?
    ) {
        guard case .off = status else { return }

        let currentProxy = SystemProxyReader.current()
        // PAC / WPAD route per-URL via a script we cannot evaluate, so takeover
        // cannot chain to them. SOCKS is fine: the local proxy speaks SOCKS5
        // upstream, and `fixedUpstream` prefers it (Clash/Shadowrocket expose one).
        if currentProxy.autoConfigEnabled || currentProxy.autoDiscoveryEnabled {
            setStatus(.failed(.unsupportedSystemProxy))
            return
        }
        setStatus(.starting)

        server.start(preferredPort: 0)
        // Wait for the listener to report its port before touching system settings —
        // pointing the OS at a port that never opened would break all networking.
        waitForRunningPort { [weak self] result in
            guard let self else { return }
            switch result {
            case .failed(let message):
                self.setStatus(.failed(.serverStart(message)))
            case .ready(let port):
                do {
                    let backup = try self.systemProxy.takeOver(localPort: port)
                    // Some proxy apps publish a live Dynamic Store override that
                    // `networksetup` does not expose. Keep that upstream instead of
                    // losing it during takeover — `currentProxy` is the merged
                    // config read before takeover, so it still shows the VPN's
                    // endpoint rather than ourselves.
                    self.currentUpstream = backup.upstream
                        ?? currentProxy.fixedUpstream
                        ?? systemUpstreamHint
                    self.rulesBox.update(LocalProxyRules(
                        snapshot: snapshot,
                        systemUpstream: self.currentUpstream,
                        profiles: profiles
                    ))
                    // Do not claim success until CFNetwork — the same API client apps
                    // use — actually sees EyesOnYou as the active proxy.
                    self.waitForTakeover(port: port)
                } catch {
                    // Could not save a restore point — refuse takeover, tear down.
                    self.server.stop()
                    self.setStatus(.failed(.takeover("\(error)")))
                }
            }
        }
    }

    /// Re-check the merged proxy config against our takeover. Called on the model's
    /// refresh tick so the badge follows the VPN tunnel: shadowed while it is up,
    /// active again once it drops (and back).
    func reevaluateShadowing(merged: SystemProxySnapshot) {
        switch status {
        case .active(let port, _):
            if case .shadowed(let observed) = SystemProxyController.verifyTakeover(
                localPort: port, merged: merged
            ) {
                setStatus(.shadowedByVPN(port: port, observedProxy: observed))
            }
        case .shadowedByVPN(let port, _):
            if case .active = SystemProxyController.verifyTakeover(
                localPort: port, merged: merged
            ) {
                setStatus(.active(port: port, upstream: currentUpstream))
            }
        case .off, .starting, .failed:
            break
        }
    }

    /// Stop enforcing and restore the previous system proxy settings.
    func disable() {
        _ = systemProxy.restoreIfNeeded()
        server.stop()
        currentUpstream = nil
        setStatus(.off)
    }

    // MARK: - Internals

    private enum PortResult {
        case ready(UInt16)
        case failed(String)
    }

    private func setStatus(_ next: Status) {
        status = next
        onStatus?(next)
    }

    private func waitForTakeover(port: UInt16, attempt: Int = 0) {
        let verification = SystemProxyController.verifyTakeover(
            localPort: port, merged: SystemProxyReader.current()
        )
        if case .active = verification {
            setStatus(.active(port: port, upstream: currentUpstream))
            return
        }
        guard attempt < 20 else {
            if case .shadowed(let observed) = verification {
                // A VPN's NE-provided proxy settings override ours in the merged
                // config. Keep the takeover and the proxy running: the moment the
                // tunnel drops, our settings become visible and enforcement starts
                // for real (`reevaluateShadowing` flips the status).
                setStatus(.shadowedByVPN(port: port, observedProxy: observed))
                return
            }
            _ = systemProxy.restoreIfNeeded()
            server.stop()
            currentUpstream = nil
            setStatus(.failed(.notActivated))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForTakeover(port: port, attempt: attempt + 1)
        }
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
