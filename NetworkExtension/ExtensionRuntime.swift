import Foundation
import NetworkExtension
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouProxyCore
import EyesOnYouIPC

/// Shared process-local runtime for both providers inside the system extension.
final class ExtensionRuntime: @unchecked Sendable {
    static let shared = ExtensionRuntime()

    // The extension runs for days at a time; unbounded buckets are what gets a
    // system extension killed for memory.
    let aggregator = TelemetryAggregator(retention: .live)
    let flowRegistry = ShardedFlowRegistry()
    let metrics = ExtensionMetrics()

    /// Completed-flow samples waiting for the host to drain them. Bounded: the
    /// host polls every few seconds; if it goes away we drop oldest, never grow.
    private static let maxBufferedEvents = 512

    private let lock = NSLock()
    private var localRules = LocalProxyRules(
        snapshot: RuleSnapshot(generation: 0, checksum: Data(), rules: []),
        systemUpstream: nil,
        profiles: []
    )
    private var ruleGeneration: UInt64 = 0
    private var _proxyEnabled = false
    private var pendingEvents: [FlowEventSample] = []
    private var _activeFlows = 0
    private var started = false

    private init() {}

    var proxyEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _proxyEnabled
    }

    var rules: LocalProxyRules {
        lock.lock(); defer { lock.unlock() }
        return localRules
    }

    var status: ExtensionStatus {
        lock.lock(); defer { lock.unlock() }
        return ExtensionStatus(
            filterEnabled: false,
            proxyEnabled: _proxyEnabled,
            ruleGeneration: ruleGeneration,
            providerReachable: true,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        )
    }

    func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        // Absent rules ⇒ fail-open: every flow is declined back to the OS.
        started = true
    }

    func setProxyEnabled(_ enabled: Bool) {
        lock.lock()
        _proxyEnabled = enabled
        lock.unlock()
    }

    /// Apply a full rules push from the host (policy archive + system upstream).
    /// Returns false when the payload cannot be decoded — the old rules stay.
    @discardableResult
    func apply(_ payload: ProxyRulesPayload) -> Bool {
        guard let archive = try? JSONDecoder().decode(
            PolicyArchive.self, from: payload.policyArchiveJSON
        ) else {
            return false
        }
        let store = PolicyStore()
        archive.apply(to: store)
        let upstream: ProxyUpstream? = payload.systemUpstreamHost.flatMap { host in
            payload.systemUpstreamPort.map { port in
                ProxyUpstream(
                    kind: payload.systemUpstreamKind == "socks5" ? .socks5 : .http,
                    host: host,
                    port: port
                )
            }
        }
        let rebuilt = LocalProxyRules(
            snapshot: store.compileSnapshot(),
            systemUpstream: upstream,
            profiles: archive.proxyProfiles
        )
        lock.lock()
        localRules = rebuilt
        ruleGeneration = payload.generation
        lock.unlock()
        return true
    }

    // MARK: - Flow accounting

    func flowStarted() {
        lock.lock(); _activeFlows += 1; lock.unlock()
    }

    func flowFinished(_ sample: FlowEventSample) {
        lock.lock()
        _activeFlows = max(0, _activeFlows - 1)
        appendLocked(sample)
        lock.unlock()
    }

    /// Record a flow that never opened (blocked / refused) — exact evidence too.
    func flowRejected(_ sample: FlowEventSample) {
        lock.lock()
        appendLocked(sample)
        lock.unlock()
    }

    private func appendLocked(_ sample: FlowEventSample) {
        pendingEvents.append(sample)
        if pendingEvents.count > Self.maxBufferedEvents {
            pendingEvents.removeFirst(pendingEvents.count - Self.maxBufferedEvents)
        }
    }

    /// Hand all buffered events to the host and forget them.
    func drainEvents() -> [FlowEventSample] {
        lock.lock(); defer { lock.unlock() }
        let events = pendingEvents
        pendingEvents = []
        return events
    }

    var activeFlows: Int {
        lock.lock(); defer { lock.unlock() }
        return _activeFlows
    }

    func flush() {
        // Future: batch-write aggregator buckets to telemetry.sqlite via single writer.
    }

    func stopFilterAccounting() {
        flowRegistry.removeAll()
        aggregator.discardActiveFlows()
    }

    // MARK: - Flow identity

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

    /// App identity + destination for a transparent-proxy flow.
    ///
    /// Prefers `remoteHostname` (present when the app connected by name) so
    /// destination rules match domains and upstreams get a resolvable name even
    /// under fake-IP DNS; falls back to the numeric endpoint.
    func makeProxyTarget(from flow: NEAppProxyFlow) -> (app: AppIdentityKey, host: String, port: UInt16)? {
        let meta = flow.metaData
        let signing = ProcessAppIdentity.canonicalSigningID(meta.sourceAppSigningIdentifier)
        guard !signing.isEmpty else { return nil }
        let app = AppIdentityKey(teamIdentifier: nil, signingIdentifier: signing)

        var host = flow.remoteHostname
        var port: UInt16?
        if let endpoint = (flow as? NEAppProxyTCPFlow)?.remoteEndpoint as? NWHostEndpoint {
            if host == nil || host?.isEmpty == true {
                host = endpoint.hostname
            }
            port = UInt16(endpoint.port)
        }
        guard let host, !host.isEmpty, let port else { return nil }
        return (app, host, port)
    }

    func consume(report: NEFilterReport) {
        guard let flow = report.flow,
              let descriptor = makeDescriptor(from: flow) else {
            return
        }

        let route = rules.snapshot.evaluateRoute(descriptor).action
        let delta = flowRegistry.update(
            id: descriptor.id,
            cumulativeUp: UInt64(report.bytesOutboundCount),
            cumulativeDown: UInt64(report.bytesInboundCount)
        )

        switch report.event {
        case .statistics:
            aggregator.recordDelta(
                flowID: descriptor.id,
                app: descriptor.app,
                up: delta.up,
                down: delta.down,
                route: route,
                transport: descriptor.transport
            )
        case .flowClosed:
            aggregator.recordClose(
                flowID: descriptor.id,
                app: descriptor.app,
                finalUp: delta.up,
                finalDown: delta.down,
                route: route,
                transport: descriptor.transport
            )
            _ = flowRegistry.remove(id: descriptor.id)
        case .newFlow, .dataDecision:
            break
        @unknown default:
            break
        }
    }
}

final class ExtensionMetrics: @unchecked Sendable {
    var unclassifiedFlows: UInt64 = 0
}
