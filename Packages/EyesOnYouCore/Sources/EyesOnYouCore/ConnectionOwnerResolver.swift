import Foundation

/// Finds which process owns a loopback TCP connection, keyed by its client port.
///
/// When a client connects to our local proxy, the accepted socket's *peer* port is
/// the client's ephemeral source port. `lsof` lists that port against the owning PID,
/// so a reverse index (port → pid) tells us who is really talking — which is what
/// makes "route Chrome through the proxy" enforceable rather than cosmetic.
///
/// The index is rebuilt at most every `refreshInterval`; a single `lsof` covers all
/// ports, so per-connection lookups stay cheap.
public final class ConnectionOwnerResolver: @unchecked Sendable {
    public struct Owner: Equatable, Sendable {
        public let pid: Int32
        public let app: AppIdentityKey
        public let displayName: String
    }

    private let refreshInterval: TimeInterval
    private let lock = NSLock()
    private var portToPID: [UInt16: Int32] = [:]
    private var builtAt: Date?
    private var lastForcedAt: Date?
    private var ownerCache: [Int32: (startTime: UInt64?, owner: Owner)] = [:]
    private let sampler: () -> [(pid: Int32, localPort: UInt16)]

    public init(
        refreshInterval: TimeInterval = 1.0,
        sampler: @escaping () -> [(pid: Int32, localPort: UInt16)] = ConnectionOwnerResolver.lsofLoopbackClients
    ) {
        self.refreshInterval = refreshInterval
        self.sampler = sampler
    }

    /// Owner of the process holding `clientPort`, or `nil` when unknown.
    public func owner(clientPort: UInt16, now: Date = Date()) -> Owner? {
        refreshIfNeeded(now: now)

        lock.lock()
        var pid = portToPID[clientPort]
        lock.unlock()

        // A connection that arrives just after a refresh is not in the index yet —
        // which is exactly the case that matters, since we are asked about a socket
        // that was opened moments ago. Rebuild once on a miss, rate-limited so a
        // flood of unattributable connections cannot spawn an `lsof` per connection.
        if pid == nil, shouldForceRefresh(now: now) {
            rebuild(now: now, forced: true)
            lock.lock()
            pid = portToPID[clientPort]
            lock.unlock()
        }

        guard let pid else { return nil }
        return resolveOwner(pid: pid)
    }

    /// Force the next lookup to rebuild the port index.
    public func invalidate() {
        lock.lock()
        builtAt = nil
        lock.unlock()
    }

    private func refreshIfNeeded(now: Date) {
        lock.lock()
        let stale = builtAt.map { now.timeIntervalSince($0) >= refreshInterval } ?? true
        lock.unlock()
        guard stale else { return }
        rebuild(now: now, forced: false)
    }

    /// Minimum spacing between miss-triggered rebuilds.
    private static let forcedRefreshInterval: TimeInterval = 0.2

    private func shouldForceRefresh(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastForcedAt else { return true }
        return now.timeIntervalSince(last) >= Self.forcedRefreshInterval
    }

    private func rebuild(now: Date, forced: Bool) {
        let samples = sampler()
        var map: [UInt16: Int32] = [:]
        map.reserveCapacity(samples.count)
        for sample in samples {
            map[sample.localPort] = sample.pid
        }

        lock.lock()
        portToPID = map
        builtAt = now
        // Only a miss-triggered rebuild arms the rate limiter. A scheduled refresh
        // must not suppress the very retry that resolves a brand-new connection —
        // that mistake left every connection after the first one unattributed.
        if forced { lastForcedAt = now }
        lock.unlock()
    }

    private func resolveOwner(pid: Int32) -> Owner? {
        let startTime = ProcessRuntimeInfo.startTime(pid: pid)

        lock.lock()
        if let cached = ownerCache[pid], cached.startTime == startTime {
            lock.unlock()
            return cached.owner
        }
        lock.unlock()

        guard let resolved = ProcessAppIdentity.resolveOwning(pid: pid) else { return nil }
        let signing = ProcessAppIdentity.canonicalSigningID(resolved.identity.signingIdentifier)
        let owner = Owner(
            pid: pid,
            app: AppIdentityKey(teamIdentifier: nil, signingIdentifier: signing),
            displayName: resolved.identity.displayName
        )

        lock.lock()
        ownerCache[pid] = (startTime, owner)
        lock.unlock()
        return owner
    }

    // MARK: - lsof sampling

    /// All loopback TCP client sockets as (pid, localPort) pairs.
    ///
    /// `-iTCP@127.0.0.1` restricts to loopback so the scan is small — the only
    /// sockets that matter are clients dialing our proxy on localhost.
    public static func lsofLoopbackClients() -> [(pid: Int32, localPort: UInt16)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-w", "-iTCP@127.0.0.1", "-Fpn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseLsofFieldOutput(String(data: data, encoding: .utf8) ?? "")
    }

    /// Parse `lsof -F pn`: `p<pid>` lines introduce a process, `n<name>` name lines
    /// follow. We want the local port from `127.0.0.1:PORT->…` entries.
    public static func parseLsofFieldOutput(_ text: String) -> [(pid: Int32, localPort: UInt16)] {
        var result: [(pid: Int32, localPort: UInt16)] = []
        var currentPID: Int32?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
            case "n":
                guard let pid = currentPID,
                      let arrow = value.range(of: "->") else { continue }
                let local = value[..<arrow.lowerBound]
                guard let colon = local.lastIndex(of: ":"),
                      let port = UInt16(local[local.index(after: colon)...]) else { continue }
                result.append((pid, port))
            default:
                continue
            }
        }
        return result
    }
}
