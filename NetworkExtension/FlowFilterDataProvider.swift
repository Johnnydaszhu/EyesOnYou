import Foundation
import NetworkExtension
import OSLog
import EyesOnYouCore
import EyesOnYouRuleEngine

/// Content filter provider: observe / allow / block + statistics → aggregator.
/// Compile against the current macOS SDK; method availability may vary by OS version.
final class FlowFilterDataProvider: NEFilterDataProvider {
    private let log = Logger(subsystem: "com.example.EyesOnYou", category: "Filter")
    private let runtime = ExtensionRuntime.shared

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            try runtime.startIfNeeded()
            log.info("Filter starting generation=\(self.runtime.rules.snapshot.generation, privacy: .public)")

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
        runtime.stopFilterAccounting()
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

        let snapshot = runtime.rules.snapshot
        let decision = snapshot.evaluateFirewall(descriptor)
        let route = snapshot.evaluateRoute(descriptor).action
        runtime.aggregator.recordOpen(
            descriptor,
            displayName: descriptor.app.signingIdentifier,
            route: route,
            firewall: decision.action
        )

        switch decision.action {
        case .block:
            // A dropped socket does not produce a later close report. Close its
            // accounting lifecycle now instead of retaining its UUID forever.
            runtime.aggregator.recordClose(
                flowID: descriptor.id,
                app: descriptor.app,
                at: Date(),
                route: route,
                transport: descriptor.transport
            )
            return .drop()
        case .inherit, .observe, .allow:
            let verdict = NEFilterNewFlowVerdict.allow()
            // `shouldReport` guarantees a final flowClosed report for socket
            // flows; periodic reports provide cumulative byte counters.
            verdict.shouldReport = true
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
