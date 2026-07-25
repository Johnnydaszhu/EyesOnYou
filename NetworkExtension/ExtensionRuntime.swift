import Foundation
import NetworkExtension
import EyesOnYouCore
import EyesOnYouRuleEngine

/// Shared process-local runtime for both providers inside the system extension.
final class ExtensionRuntime: @unchecked Sendable {
    static let shared = ExtensionRuntime()

    let aggregator = TelemetryAggregator()
    let flowRegistry = ShardedFlowRegistry()
    let metrics = ExtensionMetrics()
    private(set) var rules: RuleSnapshot
    var proxyEnabled: Bool = false
    private var started = false
    private let lock = NSLock()

    private init() {
        rules = RuleSnapshot(generation: 0, checksum: Data(), rules: [])
    }

    func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        // Load last-known-good snapshot from App Group when available.
        // Absent snapshot ⇒ fail-open empty rules (allow / direct).
        started = true
    }

    func updateRules(_ snapshot: RuleSnapshot) {
        lock.lock()
        rules = snapshot
        lock.unlock()
    }

    func setProxyEnabled(_ enabled: Bool) {
        lock.lock()
        proxyEnabled = enabled
        lock.unlock()
    }

    func flush() {
        // Future: batch-write aggregator buckets to telemetry.sqlite via single writer.
    }

    func makeDescriptor(from flow: NEFilterFlow) -> FlowDescriptor? {
        // macOS exposes sourceAppAuditToken (not iOS-only sourceAppIdentifier).
        // Production resolves Team ID + signing ID via SecCode; scaffold uses a stable token hash.
        let signing: String
        if let token = flow.sourceAppAuditToken, !token.isEmpty {
            signing = "audit:\(token.base64EncodedString().prefix(24))"
        } else {
            signing = "unknown"
        }
        let flowID = flow.identifier
        let app = AppIdentityKey(teamIdentifier: nil, signingIdentifier: signing)
        return FlowDescriptor(
            id: flowID,
            app: app,
            direction: .outbound,
            transport: .tcp,
            remoteHostname: nil,
            remoteAddress: nil,
            remotePort: nil
        )
    }

    func makeProxyDescriptor(from flow: NEAppProxyFlow) -> FlowDescriptor? {
        let meta = flow.metaData
        let signing = meta.sourceAppSigningIdentifier
        guard !signing.isEmpty else { return nil }
        return FlowDescriptor(
            app: AppIdentityKey(teamIdentifier: nil, signingIdentifier: signing),
            direction: .outbound,
            transport: .tcp
        )
    }

    func consume(report: NEFilterReport) {
        // Wire cumulative bytes when flow identity is available from report.
        // Phase 0 calibrates which fields are non-zero on each macOS version.
        _ = report
    }
}

final class ExtensionMetrics: @unchecked Sendable {
    var unclassifiedFlows: UInt64 = 0
}
