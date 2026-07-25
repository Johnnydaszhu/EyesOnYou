import Foundation

/// How strongly a project attribution is evidenced.
public enum ProjectAttributionConfidence: String, Sendable, Equatable, CaseIterable {
    /// Read from the socket-holding process's own working directory.
    case processDirectory
    /// Read from the editor window this process belongs to (one window = one workspace).
    case windowLabel
    /// Read from an ancestor process (an MCP server inherits the agent's project).
    case ancestorDirectory
    /// Inferred from the app's most recent session on disk. The app was working on
    /// this project just now, but the bytes are not proven to belong to it.
    case recentSession
}

/// One socket-holding process, resolved to the app that owns it and the project it
/// is working in.
public struct AttributedProcess: Sendable, Equatable {
    public let pid: Int32
    /// Truncated `lsof` COMMAND, kept for diagnostics.
    public let command: String
    public let app: AppIdentityKey
    public let displayName: String
    public let project: ProjectIdentity?
    public let confidence: ProjectAttributionConfidence?
    /// True when the identity came from an ancestor (bare `node` → its editor).
    public let isRolledUp: Bool
    public let viaProxyConnections: Int
    public let directConnections: Int
    public let remoteHosts: [String]

    public init(
        pid: Int32,
        command: String,
        app: AppIdentityKey,
        displayName: String,
        project: ProjectIdentity? = nil,
        confidence: ProjectAttributionConfidence? = nil,
        isRolledUp: Bool = false,
        viaProxyConnections: Int = 0,
        directConnections: Int = 0,
        remoteHosts: [String] = []
    ) {
        self.pid = pid
        self.command = command
        self.app = app
        self.displayName = displayName
        self.project = project
        self.confidence = confidence
        self.isRolledUp = isRolledUp
        self.viaProxyConnections = viaProxyConnections
        self.directConnections = directConnections
        self.remoteHosts = remoteHosts
    }

    public var weightedConnections: Int {
        viaProxyConnections + directConnections
    }

    /// Drill key for this process's traffic: the project when known, else `nil` so the
    /// caller keeps hostname attribution.
    public var projectDestinationKey: String? {
        project?.destinationKey
    }
}

/// Joins socket samples with process identity and project, so live traffic can be
/// broken down by real sub-project instead of by a static guess.
///
/// Resolution order per process, strongest evidence first:
/// 1. its own working directory,
/// 2. the workspace label of the editor window it belongs to,
/// 3. the working directory of the ancestor that owns it,
/// 4. the app's most recently active session on disk (weak; agents/IDEs only).
public final class LiveAttributionResolver: @unchecked Sendable {
    private struct CacheEntry {
        var startTime: UInt64?
        var app: AppIdentityKey
        var displayName: String
        var project: ProjectIdentity?
        var confidence: ProjectAttributionConfidence?
        var isRolledUp: Bool
    }

    private let projectResolver: ProjectResolver
    private let discoveryOptions: WorkspaceDiscoveryOptions
    private let sessionFallbackMaxAge: TimeInterval
    private var cache: [Int32: CacheEntry] = [:]
    private var sessionProjects: [String: ProjectIdentity?] = [:]
    private let lock = NSLock()

    public init(
        projectResolver: ProjectResolver,
        discoveryOptions: WorkspaceDiscoveryOptions = .default,
        sessionFallbackMaxAge: TimeInterval = 900
    ) {
        self.projectResolver = projectResolver
        self.discoveryOptions = discoveryOptions
        self.sessionFallbackMaxAge = sessionFallbackMaxAge
    }

    /// Drop cached per-process and per-app results (call after rediscovery).
    public func invalidate() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        sessionProjects.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func attribute(
        _ samples: [SocketProcessSample],
        now: Date = Date()
    ) -> [AttributedProcess] {
        samples.map { attribute($0, now: now) }
    }

    public func attribute(
        _ sample: SocketProcessSample,
        now: Date = Date()
    ) -> AttributedProcess {
        let resolved = resolveCached(pid: sample.pid, command: sample.command, now: now)
        return AttributedProcess(
            pid: sample.pid,
            command: sample.command,
            app: resolved.app,
            displayName: resolved.displayName,
            project: resolved.project,
            confidence: resolved.confidence,
            isRolledUp: resolved.isRolledUp,
            viaProxyConnections: sample.viaProxyConnections,
            directConnections: sample.directConnections,
            remoteHosts: sample.remoteHosts
        )
    }

    // MARK: - Internals

    private func resolveCached(pid: Int32, command: String, now: Date) -> CacheEntry {
        let startTime = ProcessRuntimeInfo.startTime(pid: pid)

        lock.lock()
        // PIDs are recycled; a different start time means a different process.
        if let cached = cache[pid], cached.startTime == startTime {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let entry = resolve(pid: pid, command: command, startTime: startTime, now: now)

        lock.lock()
        cache[pid] = entry
        lock.unlock()
        return entry
    }

    private func resolve(
        pid: Int32,
        command: String,
        startTime: UInt64?,
        now: Date
    ) -> CacheEntry {
        let owned = ProcessAppIdentity.resolveOwning(pid: pid, lsofCommand: command)
        let signing = ProcessAppIdentity.canonicalSigningID(
            owned?.identity.signingIdentifier ?? "proc.\(command)"
        )
        let app = AppIdentityKey(teamIdentifier: nil, signingIdentifier: signing)
        let displayName = owned?.identity.displayName ?? command

        var project: ProjectIdentity?
        var confidence: ProjectAttributionConfidence?

        if let own = projectResolver.project(forPID: pid) {
            project = own
            confidence = .processDirectory
        } else if let label = AgentProcessCatalog.workspaceLabel(
            pid: pid,
            arguments: ProcessRuntimeInfo.arguments(pid: pid)
        ), let labelled = projectResolver.project(named: label) {
            project = labelled
            confidence = .windowLabel
        } else if let owningPID = owned?.owningPID,
                  owningPID != pid,
                  let inherited = projectResolver.project(forPID: owningPID) {
            project = inherited
            confidence = .ancestorDirectory
        } else if let recent = sessionProject(forSigningID: signing, now: now) {
            project = recent
            confidence = .recentSession
        }

        return CacheEntry(
            startTime: startTime,
            app: app,
            displayName: displayName,
            project: project,
            confidence: confidence,
            isRolledUp: owned?.isRolledUp ?? false
        )
    }

    /// Apps whose on-disk sessions describe work the app itself is doing right now.
    ///
    /// Deliberately short. A companion tool that merely *reads* Codex state (a
    /// menu-bar monitor) would otherwise inherit a project it is only watching, and
    /// an editor's shared network helper serves every open window at once — for
    /// those, no project is a better answer than a plausible one.
    public static let sessionFallbackApps: Set<String> = [
        "com.openai.codex",
        "com.anthropic.claude-code",
    ]

    /// Session-file fallback, memoized per app because it scans disk.
    private func sessionProject(forSigningID signing: String, now: Date) -> ProjectIdentity? {
        guard Self.sessionFallbackApps.contains(where: {
            $0.caseInsensitiveCompare(signing) == .orderedSame
        }) else { return nil }

        lock.lock()
        if let cached = sessionProjects[signing] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let workspace = WorkspaceDiscovery.recentlyActiveProject(
            forSigningIdentifier: signing,
            maxAge: sessionFallbackMaxAge,
            now: now,
            options: discoveryOptions
        )
        let identity = workspace.map {
            ProjectIdentity(name: $0.name, path: $0.path, marker: $0.primarySource.rawValue)
        }

        lock.lock()
        sessionProjects[signing] = identity
        lock.unlock()
        return identity
    }
}
