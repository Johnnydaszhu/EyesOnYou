import Foundation
import NetworkExtension
import OSLog
import os

/// Architecture skeleton only. Compile against the current macOS SDK and update
/// API spelling/availability based on Xcode diagnostics and Phase 0 results.
final class FlowFilterDataProvider: NEFilterDataProvider {
    private let log = Logger(subsystem: "com.example.EyesOnYou", category: "Filter")
    private let runtime = ProviderRuntime.shared

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            try runtime.startIfNeeded()

            // Use the current SDK's non-deprecated NENetworkRule initializer.
            // Keep this system-level rule set deliberately small; user rules live
            // in RuleSnapshot and are evaluated in handleNewFlow.
            let catchAllOutbound = NENetworkRule(
                remoteNetworkEndpoint: nil,
                remotePrefix: 0,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .any,
                direction: .outbound
            )
            let filterRule = NEFilterRule(
                networkRule: catchAllOutbound,
                action: .filterData
            )
            let settings = NEFilterSettings(
                rules: [filterRule],
                defaultAction: .allow
            )

            apply(settings) { error in
                if let error {
                    self.log.error("apply filter settings failed: \(error.localizedDescription, privacy: .public)")
                }
                completionHandler(error)
            }
        } catch {
            log.error("filter start failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }
    }

    override func stopFilter(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        runtime.flushAndStop(reason: reason) {
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // No disk I/O, DNS, icon lookup, sync XPC, regex, or UI wait here.
        guard let descriptor = runtime.descriptorFactory.makeFilterDescriptor(from: flow) else {
            runtime.metrics.incrementUnclassifiedFlowCount()
            return NEFilterNewFlowVerdict.allow()
        }

        let decision = runtime.rules.current.evaluateFirewall(descriptor)
        runtime.telemetry.recordOpen(descriptor, decision: decision)

        switch decision.action {
        case .block:
            return NEFilterNewFlowVerdict.drop()

        case .inherit, .observe, .allow:
            let verdict = NEFilterNewFlowVerdict.allow()
            verdict.statisticsReportFrequency = runtime.statisticsFrequency
            return verdict
        }
    }

    override func handle(_ report: NEFilterReport) {
        // Treat report counters as latest cumulative values until Phase 0 proves
        // otherwise for every supported macOS version.
        runtime.telemetry.consume(report: report)
    }
}

// MARK: - Deliberately minimal placeholders

final class ProviderRuntime: @unchecked Sendable {
    static let shared = ProviderRuntime()
    let descriptorFactory = FlowDescriptorFactory()
    let rules = AtomicRuleStore()
    let telemetry = TelemetryRuntime()
    let metrics = RuntimeMetrics()
    var statisticsFrequency: NEFilterReport.Frequency = .medium

    func startIfNeeded() throws {}
    func flushAndStop(reason: NEProviderStopReason, completion: @escaping () -> Void) { completion() }
}

final class FlowDescriptorFactory {
    func makeFilterDescriptor(from flow: NEFilterFlow) -> FlowDescriptor? { nil }
}

final class AtomicRuleStore { var current = RuleSnapshot(generation: 0, checksum: Data(), rules: []) }
final class TelemetryRuntime {
    func recordOpen(_ flow: FlowDescriptor, decision: FirewallDecision) {}
    func consume(report: NEFilterReport) {}
}
final class RuntimeMetrics {
    private let unclassifiedFlowCount = OSAllocatedUnfairLock(initialState: UInt64(0))
    func incrementUnclassifiedFlowCount() {
        unclassifiedFlowCount.withLock { $0 &+= 1 }
    }
}
