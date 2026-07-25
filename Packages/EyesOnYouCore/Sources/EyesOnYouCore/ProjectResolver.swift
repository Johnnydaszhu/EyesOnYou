import Foundation

/// A project a process is actually working in, resolved from a real filesystem path.
public struct ProjectIdentity: Sendable, Equatable, Hashable {
    /// Display title (repo folder name, or the workspace title an IDE gave it).
    public let name: String
    /// Absolute project root.
    public let path: String
    /// Marker that established the root (`git`, `swift`, `node`, …); `nil` when the
    /// path was accepted as a plain folder under a known code directory.
    public let marker: String?

    public init(name: String, path: String, marker: String? = nil) {
        self.name = name
        self.path = path
        self.marker = marker
    }

    /// Drill destination key shared with `DiscoveredWorkspace` (`project:<name>`).
    public var destinationKey: String {
        DestinationKey.makeLabeled(prefix: "project", title: name)
    }
}

/// Maps a process working directory onto the project root that owns it.
///
/// A coding agent is usually launched *inside* a subdirectory, so the raw cwd
/// (`…/EyesOnYou/Packages/EyesOnYouCore`) is not the unit a user thinks in. This
/// walks up to the nearest repository marker and prefers the title an IDE already
/// gave that folder, which is what makes the sub-project rows match reality.
public final class ProjectResolver: @unchecked Sendable {
    /// Version-control roots. Checked first and innermost-wins, matching
    /// `git rev-parse --show-toplevel` — the folder a developer calls "the project".
    public static let vcsMarkers: [(file: String, marker: String)] = [
        (".git", "git"),
        (".hg", "hg"),
        (".svn", "svn"),
    ]

    /// Build-manifest roots, used only when nothing in the chain is under version
    /// control. A nested `Package.swift` never outranks the enclosing repo.
    public static let buildMarkers: [(file: String, marker: String)] = [
        ("Package.swift", "swift"),
        ("go.mod", "go"),
        ("Cargo.toml", "rust"),
        ("pyproject.toml", "python"),
        ("package.json", "node"),
        ("pom.xml", "java"),
        ("build.gradle", "gradle"),
        ("Gemfile", "ruby"),
    ]

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let excludedPrefixes: [String]
    /// Workspace titles keyed by normalized path, e.g. a Codex project renamed in the UI.
    /// Known workspaces keyed by lowercased path, holding the original-cased path
    /// alongside the title its IDE gave it.
    private var workspaceNames: [String: (name: String, path: String)]
    private var cache: [String: ProjectIdentity?] = [:]
    private let lock = NSLock()

    public init(
        workspaces: [DiscoveredWorkspace] = [],
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        excludedPathPrefixes: [String] = ProjectResolver.defaultExcludedPrefixes,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.excludedPrefixes = excludedPathPrefixes.map { $0.lowercased() }
        self.workspaceNames = Self.index(workspaces)
    }

    /// Refresh the workspace title overlay after a rediscovery pass.
    public func updateWorkspaces(_ workspaces: [DiscoveredWorkspace]) {
        lock.lock()
        defer { lock.unlock() }
        let updated = Self.index(workspaces)
        guard updated.mapValues(\.name) != workspaceNames.mapValues(\.name) else { return }
        workspaceNames = updated
        // Titles feed the cached identities, so drop them rather than serve stale names.
        cache.removeAll(keepingCapacity: true)
    }

    /// Resolve the project owning `path`, or `nil` when the path is not project-like.
    public func project(forPath path: String) -> ProjectIdentity? {
        let normalized = Self.normalize(path)
        guard !normalized.isEmpty else { return nil }

        lock.lock()
        if let cached = cache[normalized] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = computeProject(forNormalizedPath: normalized)

        lock.lock()
        cache[normalized] = resolved
        lock.unlock()
        return resolved
    }

    /// Resolve the project a running process is working in.
    public func project(forPID pid: Int32) -> ProjectIdentity? {
        guard let cwd = ProcessRuntimeInfo.workingDirectory(pid: pid) else { return nil }
        return project(forPath: cwd)
    }

    /// Resolve a project from a workspace *name* (an editor window label).
    ///
    /// Matches a discovered workspace so the row carries a real path; otherwise the
    /// label stands on its own — the window is genuinely showing that project even
    /// when discovery has not indexed it.
    public func project(named label: String) -> ProjectIdentity? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        lock.lock()
        let match = workspaceNames.values
            .first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        lock.unlock()

        if let match {
            return ProjectIdentity(name: match.name, path: match.path, marker: "workspace")
        }
        return ProjectIdentity(name: trimmed, path: "", marker: "window")
    }

    public func invalidate() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Internals

    private func computeProject(forNormalizedPath path: String) -> ProjectIdentity? {
        guard !isUninformative(path) else { return nil }

        var chain: [URL] = []
        var cursor = URL(fileURLWithPath: path)
        while cursor.path != "/" {
            chain.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        let candidates = chain.filter { !isUninformative($0.path) }
        // Innermost VCS root first (what `git rev-parse --show-toplevel` returns), so a
        // monorepo reports the repo and never a nested package inside it.
        for url in candidates {
            if let marker = markerName(at: url, in: Self.vcsMarkers) {
                return identity(for: url, marker: marker)
            }
        }
        for url in candidates {
            if let marker = markerName(at: url, in: Self.buildMarkers) {
                return identity(for: url, marker: marker)
            }
            if hasXcodeBundle(at: url) {
                return identity(for: url, marker: "xcode")
            }
        }
        // No marker anywhere: a folder an IDE already knows by name is still a project.
        if lookupWorkspaceName(for: path) != nil {
            return identity(for: URL(fileURLWithPath: path), marker: nil)
        }
        return nil
    }

    private func identity(for url: URL, marker: String?) -> ProjectIdentity {
        let name = lookupWorkspaceName(for: url.path) ?? url.lastPathComponent
        return ProjectIdentity(name: name, path: url.path, marker: marker)
    }

    private func lookupWorkspaceName(for path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return workspaceNames[path.lowercased()]?.name
    }

    private func markerName(at url: URL, in markers: [(file: String, marker: String)]) -> String? {
        for entry in markers
        where fileManager.fileExists(atPath: url.appendingPathComponent(entry.file).path) {
            return entry.marker
        }
        return nil
    }

    /// An `.xcodeproj` / `.xcworkspace` bundle in the folder also marks a root.
    private func hasXcodeBundle(at url: URL) -> Bool {
        guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else { return false }
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    /// Paths that would produce a meaningless bucket: `/`, `$HOME`, system prefixes,
    /// caches, and temp dirs. Agents launched outside a project land here.
    private func isUninformative(_ path: String) -> Bool {
        if path.isEmpty || path == "/" { return true }
        if path == Self.normalize(homeDirectory.path) { return true }

        let lower = path.lowercased()
        for prefix in excludedPrefixes where lower == prefix || lower.hasPrefix(prefix + "/") {
            return true
        }
        let home = Self.normalize(homeDirectory.path).lowercased()
        for suffix in Self.excludedHomeSubpaths {
            let full = home + "/" + suffix
            if lower == full || lower.hasPrefix(full + "/") { return true }
        }
        return false
    }

    /// System, package-manager, and per-user temp trees. A checkout never lives here,
    /// and a bucket named after one is noise.
    public static let defaultExcludedPrefixes = [
        "/system", "/usr", "/bin", "/sbin", "/opt/homebrew", "/private/var", "/var", "/tmp",
        "/applications", "/library", "/volumes/macintosh hd/system",
    ]

    private static let excludedHomeSubpaths = [
        "library", ".cache", ".npm", ".cargo/registry", ".rustup", ".nvm", ".pyenv",
    ]

    private static func index(
        _ workspaces: [DiscoveredWorkspace]
    ) -> [String: (name: String, path: String)] {
        var map: [String: (name: String, path: String)] = [:]
        for workspace in workspaces {
            let normalized = normalize(workspace.path)
            guard !normalized.isEmpty else { continue }
            let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            map[normalized.lowercased()] = (name: name, path: normalized)
        }
        return map
    }

    private static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = trimmed.hasPrefix("~") ? (trimmed as NSString).expandingTildeInPath : trimmed
        var resolved = URL(fileURLWithPath: expanded).standardizedFileURL.path
        // `/tmp` and `/var` are symlinks into `/private`; normalize so cwd and
        // discovery paths compare equal.
        if resolved.hasPrefix("/private/tmp") {
            resolved = String(resolved.dropFirst("/private".count))
        }
        while resolved.count > 1, resolved.hasSuffix("/") {
            resolved.removeLast()
        }
        return resolved
    }
}
