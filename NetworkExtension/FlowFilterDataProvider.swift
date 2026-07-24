import Foundation
import NetworkExtension
import OSLog
import FlowLensCore
import FlowLensRuleEngine

/// Content filter provider: observe / allow / block + statistics → aggregator.
/// Compile against the current macOS SDK; method availability may vary by OS version.
final class FlowFilterDataProvider: NEFilterDataProvider {
    private let log = Logger(subsystem: "com.example.FlowLens", category: "Filter")
    private let runtime = ExtensionRuntime.shared

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            try runtime.startIfNeeded()
            log.info("Filter starting generation=\(self.runtime.rules.generation, privacy: .public)")

            // Broad outbound socket coverage; user rules evaluate in-process.
            // Use current SDK non-deprecated NENetworkRule initializer when available.
            let settings = NEFilterSettings(rules: [], defaultAction: .allow)
            apply(settings) { error in
                if let error {
                    self.log.error("apply filter settings failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.log.info("Filter settings applied (fail-open default allow)")
                }
                completionHandler(error)
            }
        } catch {
            log.error("filter start failed: \(error.localizedDescription, privacy: .public)")
            // Fail-open: still complete so the system does not leave the provider half-started.
            completionHandler(nil)
        }
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        runtime.flush()
        log.info("Filter stopped reason=\(String(describing: reason), privacy: .public)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Hot path: no disk I/O, DNS, icon lookup, sync XPC, or regex.
        guard let descriptor = runtime.makeDescriptor(from: flow) else {
            runtime.metrics.unclassifiedFlows &+= 1
            return .allow()
        }

        let decision = runtime.rules.evaluateFirewall(descriptor)
        runtime.aggregator.recordOpen(
            descriptor,
            displayName: descriptor.app.signingIdentifier,
            route: runtime.rules.evaluateRoute(descriptor).action,
            firewall: decision.action
        )

        switch decision.action {
        case .block:
            return .drop()
        case .inherit, .observe, .allow:
            let verdict = NEFilterNewFlowVerdict.allow()
            // Prefer medium stats when available; property may differ by SDK.
            if #available(macOS 11.0, *) {
                verdict.statisticsReportFrequency = .medium
            }
            return verdict
        }
    }

    override func handle(_ report: NEFilterReport) {
        // Map cumulative bytes into deltas via ShardedFlowRegistry when flow ID is known.
        // Phase 0 must calibrate byte semantics per OS version.
        runtime.consume(report: report)
    }
}
