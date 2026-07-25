import Foundation

/// Where a discovered workspace / project folder came from.
public enum WorkspaceSource: String, Sendable, Codable, CaseIterable {
    /// ChatGPT / Codex desktop `local-projects` in `~/.codex/.codex-global-state.json`.
    case codexDesktop
    /// Aggregated from `~/.codex/sessions/**/*.jsonl` `session_meta.cwd`.
    case codexSession
    /// Dimillian/CodexMonitor `workspaces.json`.
    case codexMonitor
    /// Cursor `~/.cursor/projects` + VS Code-style storage.json.
    case cursor
    /// Visual Studio Code recent / profileAssociations.
    case vsCode
    /// Claude Code `~/.claude/projects` hyphen-encoded folders.
    case claudeCode
}

/// A local folder attributed to an IDE / agent app (Codex project, Cursor workspace, …).
public struct DiscoveredWorkspace: Sendable, Equatable, Identifiable {
    public var id: String { path.lowercased() }
    public let name: String
    public let path: String
    public let sources: Set<WorkspaceSource>
    public let lastActiveAt: Date?
    public let sessionCount: Int
    public let isPinned: Bool
    public let isActive: Bool

    public init(
        name: String,
        path: String,
        sources: Set<WorkspaceSource>,
        lastActiveAt: Date? = nil,
        sessionCount: Int = 0,
        isPinned: Bool = false,
        isActive: Bool = false
    ) {
        self.name = name
        self.path = path
        self.sources = sources
        self.lastActiveAt = lastActiveAt
        self.sessionCount = sessionCount
        self.isPinned = isPinned
        self.isActive = isActive
    }

    /// Stable drill destination key (`project:<name>`).
    public var destinationKey: String {
        DestinationKey.makeLabeled(prefix: "project", title: name)
    }

    public var primarySource: WorkspaceSource {
        let order: [WorkspaceSource] = [
            .codexDesktop, .codexMonitor, .cursor, .vsCode, .claudeCode, .codexSession
        ]
        for source in order where sources.contains(source) {
            return source
        }
        return sources.first ?? .codexSession
    }
}

public struct WorkspaceDiscoveryOptions: Sendable {
    public var homeDirectory: URL
    public var codexHome: URL?
    public var cursorHome: URL?
    public var claudeHome: URL?
    public var applicationSupport: URL?
    /// Cap how many recent Codex session files to open (first-line meta only).
    public var maxCodexSessionsToScan: Int
    /// Cap returned projects after merge/rank.
    public var limit: Int

    public init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        codexHome: URL? = nil,
        cursorHome: URL? = nil,
        claudeHome: URL? = nil,
        applicationSupport: URL? = nil,
        maxCodexSessionsToScan: Int = 600,
        limit: Int = 40
    ) {
        self.homeDirectory = homeDirectory
        self.codexHome = codexHome
        self.cursorHome = cursorHome
        self.claudeHome = claudeHome
        self.applicationSupport = applicationSupport
        self.maxCodexSessionsToScan = maxCodexSessionsToScan
        self.limit = limit
    }

    public static var `default`: WorkspaceDiscoveryOptions { WorkspaceDiscoveryOptions() }

    fileprivate var fileManager: FileManager { .default }
}

/// Discovers real local project folders for Codex / Cursor / VS Code / Claude Code.
///
/// Inspired by CodexMonitor: bind activity to workspace `cwd` / root paths rather than inventing chat titles.
public enum WorkspaceDiscovery {
    public static func discover(
        options: WorkspaceDiscoveryOptions = .default
    ) -> [DiscoveredWorkspace] {
        var byPath: [String: MutableWorkspace] = [:]

        let codexHome = options.codexHome
            ?? options.homeDirectory.appendingPathComponent(".codex")
        let cursorHome = options.cursorHome
            ?? options.homeDirectory.appendingPathComponent(".cursor")
        let claudeHome = options.claudeHome
            ?? options.homeDirectory.appendingPathComponent(".claude")
        let appSupport = options.applicationSupport
            ?? options.homeDirectory
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")

        ingestCodexDesktop(codexHome: codexHome, into: &byPath, options: options)
        ingestCodexSessions(codexHome: codexHome, into: &byPath, options: options)
        ingestCodexMonitor(appSupport: appSupport, into: &byPath, options: options)
        ingestCursor(cursorHome: cursorHome, appSupport: appSupport, into: &byPath, options: options)
        ingestVSCode(appSupport: appSupport, into: &byPath, options: options)
        ingestClaudeCode(claudeHome: claudeHome, into: &byPath, options: options)

        var merged = byPath.values.map { $0.frozen() }
        merged.sort(by: rankSort)
        if options.limit > 0, merged.count > options.limit {
            return Array(merged.prefix(options.limit))
        }
        return merged
    }

    /// Projects relevant to a host app signing identifier.
    public static func projects(
        forSigningIdentifier signingID: String,
        options: WorkspaceDiscoveryOptions = .default
    ) -> [DiscoveredWorkspace] {
        let id = signingID.lowercased()
        let all = discover(options: options)
        let allowed: Set<WorkspaceSource>
        if id.contains("codex") || id.contains("openai") || id.contains("chatgpt") {
            allowed = [.codexDesktop, .codexSession, .codexMonitor]
        } else if id.contains("cursor") || id.contains("todesktop") {
            allowed = [.cursor]
        } else if id.contains("vscode") || (id.contains("microsoft") && id.contains("code")) {
            allowed = [.vsCode]
        } else if id.contains("claude") || id.contains("anthropic") {
            allowed = [.claudeCode]
        } else {
            return []
        }
        return all.filter { !$0.sources.isDisjoint(with: allowed) }
    }

    // MARK: - Codex desktop

    private static func ingestCodexDesktop(
        codexHome: URL,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        let stateURL = codexHome.appendingPathComponent(".codex-global-state.json")
        guard let root = readJSONObject(at: stateURL) else { return }

        let pinned = Set((root["pinned-project-ids"] as? [String]) ?? [])
        var activePaths = Set(
            ((root["active-workspace-roots"] as? [String]) ?? [])
                .map(normalizePath)
        )
        if let selected = root["selected-project"] as? [String: Any],
           let projectID = selected["projectId"] as? String,
           let projects = root["local-projects"] as? [String: Any],
           let entry = projects[projectID] as? [String: Any] {
            for path in rootPaths(from: entry) {
                activePaths.insert(normalizePath(path))
            }
        }

        if let projects = root["local-projects"] as? [String: Any] {
            for (projectID, value) in projects {
                guard let entry = value as? [String: Any] else { continue }
                let paths = rootPaths(from: entry)
                guard let primary = paths.first else { continue }
                let rawName = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let display = rawName.isEmpty
                    ? URL(fileURLWithPath: primary).lastPathComponent
                    : rawName
                let updatedMs = entry["updatedAt"] as? Double ?? entry["createdAt"] as? Double
                let updated = updatedMs.map { Date(timeIntervalSince1970: $0 / 1000.0) }
                let key = normalizePath(primary)
                merge(
                    into: &byPath,
                    path: key,
                    name: display,
                    source: .codexDesktop,
                    lastActiveAt: updated,
                    sessionCount: 0,
                    isPinned: pinned.contains(projectID),
                    isActive: activePaths.contains(key)
                )
                for extra in paths.dropFirst() {
                    let extraKey = normalizePath(extra)
                    merge(
                        into: &byPath,
                        path: extraKey,
                        name: URL(fileURLWithPath: extra).lastPathComponent,
                        source: .codexDesktop,
                        lastActiveAt: updated,
                        sessionCount: 0,
                        isPinned: pinned.contains(projectID),
                        isActive: activePaths.contains(extraKey)
                    )
                }
            }
        }

        for path in (root["electron-saved-workspace-roots"] as? [String]) ?? [] {
            let key = normalizePath(path)
            merge(
                into: &byPath,
                path: key,
                name: URL(fileURLWithPath: path).lastPathComponent,
                source: .codexDesktop,
                lastActiveAt: nil,
                sessionCount: 0,
                isPinned: false,
                isActive: activePaths.contains(key)
            )
        }
    }

    // MARK: - Codex sessions (cwd activity)

    private static func ingestCodexSessions(
        codexHome: URL,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        let sessionsRoot = codexHome.appendingPathComponent("sessions")
        guard options.fileManager.fileExists(atPath: sessionsRoot.path) else { return }

        let files = recentJSONLFiles(
            under: sessionsRoot,
            limit: options.maxCodexSessionsToScan,
            fileManager: options.fileManager
        )
        for file in files {
            guard let meta = readSessionMeta(from: file) else { continue }
            guard let cwd = meta.cwd, !cwd.isEmpty else { continue }
            let key = normalizePath(cwd)
            // Skip bare home — not a meaningful project bucket.
            if key == normalizePath(options.homeDirectory.path) { continue }
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            merge(
                into: &byPath,
                path: key,
                name: name,
                source: .codexSession,
                lastActiveAt: meta.timestamp ?? fileModificationDate(file, fileManager: options.fileManager),
                sessionCount: 1,
                isPinned: false,
                isActive: false
            )
        }
    }

    // MARK: - CodexMonitor

    private static func ingestCodexMonitor(
        appSupport: URL,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        let url = appSupport
            .appendingPathComponent("com.dimillian.codexmonitor")
            .appendingPathComponent("workspaces.json")
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        for entry in array {
            guard let path = entry["path"] as? String, !path.isEmpty else { continue }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? URL(fileURLWithPath: path).lastPathComponent
            merge(
                into: &byPath,
                path: normalizePath(path),
                name: name,
                source: .codexMonitor,
                lastActiveAt: nil,
                sessionCount: 0,
                isPinned: false,
                isActive: false
            )
        }
    }

    // MARK: - Cursor

    private static func ingestCursor(
        cursorHome: URL,
        appSupport: URL,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        let storage = appSupport
            .appendingPathComponent("Cursor")
            .appendingPathComponent("User")
            .appendingPathComponent("globalStorage")
            .appendingPathComponent("storage.json")
        ingestVSCodeStyleStorage(at: storage, source: .cursor, into: &byPath, options: options)

        let projectsDir = cursorHome.appendingPathComponent("projects")
        ingestHyphenEncodedProjectDirs(
            at: projectsDir,
            source: .cursor,
            into: &byPath,
            options: options
        )
    }

    // MARK: - VS Code

    private static func ingestVSCode(
        appSupport: URL,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        let storage = appSupport
            .appendingPathComponent("Code")
            .appendingPathComponent("User")
            .appendingPathComponent("globalStorage")
            .appendingPathComponent("storage.json")
        ingestVSCodeStyleStorage(at: storage, source: .vsCode, into: &byPath, options: options)
    }

    private static func ingestVSCodeStyleStorage(
        at url: URL,
        source: WorkspaceSource,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        guard let root = readJSONObject(at: url) else { return }

        if let associations = root["profileAssociations"] as? [String: Any],
           let workspaces = associations["workspaces"] as? [String: Any] {
            for key in workspaces.keys {
                if let path = pathFromFileURLString(key) {
                    merge(
                        into: &byPath,
                        path: normalizePath(path),
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        source: source,
                        lastActiveAt: nil,
                        sessionCount: 0,
                        isPinned: false,
                        isActive: false
                    )
                }
            }
        }

        if let backup = root["backupWorkspaces"] as? [String: Any] {
            if let folders = backup["folders"] as? [[String: Any]] {
                for folder in folders {
                    if let uri = folder["folderUri"] as? String, let path = pathFromFileURLString(uri) {
                        merge(
                            into: &byPath,
                            path: normalizePath(path),
                            name: URL(fileURLWithPath: path).lastPathComponent,
                            source: source,
                            lastActiveAt: nil,
                            sessionCount: 0,
                            isPinned: false,
                            isActive: false
                        )
                    }
                }
            }
        }

        if let windows = root["windowsState"] as? [String: Any] {
            if let last = windows["lastActiveWindow"] as? [String: Any],
               let folder = last["folder"] as? String,
               let path = pathFromFileURLString(folder) {
                merge(
                    into: &byPath,
                    path: normalizePath(path),
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    source: source,
                    lastActiveAt: nil,
                    sessionCount: 0,
                    isPinned: false,
                    isActive: true
                )
            }
            if let opened = windows["openedWindows"] as? [[String: Any]] {
                for window in opened {
                    if let folder = window["folder"] as? String, let path = pathFromFileURLString(folder) {
                        merge(
                            into: &byPath,
                            path: normalizePath(path),
                            name: URL(fileURLWithPath: path).lastPathComponent,
                            source: source,
                            lastActiveAt: nil,
                            sessionCount: 0,
                            isPinned: false,
                            isActive: true
                        )
                    }
                }
            }
        }
    }

    // MARK: - Claude Code

    private static func ingestClaudeCode(
        claudeHome: URL,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        let projectsDir = claudeHome.appendingPathComponent("projects")
        ingestHyphenEncodedProjectDirs(
            at: projectsDir,
            source: .claudeCode,
            into: &byPath,
            options: options
        )
    }

    private static func ingestHyphenEncodedProjectDirs(
        at projectsDir: URL,
        source: WorkspaceSource,
        into byPath: inout [String: MutableWorkspace],
        options: WorkspaceDiscoveryOptions
    ) {
        guard let names = try? options.fileManager.contentsOfDirectory(atPath: projectsDir.path) else {
            return
        }
        for name in names {
            if name.hasPrefix(".") { continue }
            if name == "empty-window" { continue }
            // Skip pure numeric / hash scratch dirs.
            if name.allSatisfy({ $0.isNumber }) { continue }
            if name.count == 32, name.allSatisfy({ $0.isHexDigit }) { continue }

            guard let resolved = HyphenPathDecoder.decode(
                name,
                homeDirectory: options.homeDirectory,
                fileManager: options.fileManager
            ) else { continue }

            let key = normalizePath(resolved)
            let mtime = fileModificationDate(
                projectsDir.appendingPathComponent(name),
                fileManager: options.fileManager
            )
            merge(
                into: &byPath,
                path: key,
                name: URL(fileURLWithPath: resolved).lastPathComponent,
                source: source,
                lastActiveAt: mtime,
                sessionCount: 0,
                isPinned: false,
                isActive: false
            )
        }
    }

    // MARK: - Merge / rank

    private static func merge(
        into byPath: inout [String: MutableWorkspace],
        path: String,
        name: String,
        source: WorkspaceSource,
        lastActiveAt: Date?,
        sessionCount: Int,
        isPinned: Bool,
        isActive: Bool
    ) {
        let key = normalizePath(path)
        guard !key.isEmpty, key != "/" else { return }
        var entry = byPath[key] ?? MutableWorkspace(path: key, name: name)
        // Prefer explicit project titles (desktop / monitor / IDE) over session cwd basenames.
        if source != .codexSession || entry.sources.isEmpty {
            entry.name = name
        }
        entry.sources.insert(source)
        entry.sessionCount += sessionCount
        entry.isPinned = entry.isPinned || isPinned
        entry.isActive = entry.isActive || isActive
        if let lastActiveAt {
            if let existing = entry.lastActiveAt {
                entry.lastActiveAt = max(existing, lastActiveAt)
            } else {
                entry.lastActiveAt = lastActiveAt
            }
        }
        byPath[key] = entry
    }

    private static func rankSort(_ a: DiscoveredWorkspace, _ b: DiscoveredWorkspace) -> Bool {
        if a.isActive != b.isActive { return a.isActive && !b.isActive }
        if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
        if a.sessionCount != b.sessionCount { return a.sessionCount > b.sessionCount }
        let aDate = a.lastActiveAt ?? .distantPast
        let bDate = b.lastActiveAt ?? .distantPast
        if aDate != bDate { return aDate > bDate }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    // MARK: - IO helpers

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func rootPaths(from entry: [String: Any]) -> [String] {
        if let paths = entry["rootPaths"] as? [String] {
            return paths.filter { !$0.isEmpty }
        }
        if let path = entry["path"] as? String, !path.isEmpty {
            return [path]
        }
        return []
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded: String
        if path.hasPrefix("~") {
            expanded = (path as NSString).expandingTildeInPath
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func pathFromFileURLString(_ value: String) -> String? {
        guard let url = URL(string: value), url.isFileURL else {
            if value.hasPrefix("/") { return value }
            return nil
        }
        return url.path
    }

    private static func fileModificationDate(_ url: URL, fileManager: FileManager) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private static func recentJSONLFiles(
        under root: URL,
        limit: Int,
        fileManager: FileManager
    ) -> [URL] {
        guard limit > 0 else { return [] }
        // Prefer Codex dated layout sessions/YYYY/MM/DD to avoid walking thousands of archives.
        let dated = recentJSONLFilesFromDatedLayout(
            under: root,
            limit: limit,
            fileManager: fileManager
        )
        if !dated.isEmpty { return dated }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var scored: [(URL, Date)] = []
        scored.reserveCapacity(min(limit * 2, 2_000))
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "jsonl" else { continue }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let date = values?.contentModificationDate ?? .distantPast
            scored.append((item, date))
        }
        scored.sort { $0.1 > $1.1 }
        if scored.count > limit {
            return scored.prefix(limit).map(\.0)
        }
        return scored.map(\.0)
    }

    private static func recentJSONLFilesFromDatedLayout(
        under root: URL,
        limit: Int,
        fileManager: FileManager
    ) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        var day = calendar.startOfDay(for: Date())
        var collected: [URL] = []
        // Walk ~120 days back; enough for ranking weight without full archive scan.
        for _ in 0..<120 {
            let y = calendar.component(.year, from: day)
            let m = calendar.component(.month, from: day)
            let d = calendar.component(.day, from: day)
            let folder = root
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))
            if let names = try? fileManager.contentsOfDirectory(atPath: folder.path) {
                let jsonl = names
                    .filter { $0.hasSuffix(".jsonl") }
                    .sorted(by: >)
                    .map { folder.appendingPathComponent($0) }
                collected.append(contentsOf: jsonl)
                if collected.count >= limit {
                    return Array(collected.prefix(limit))
                }
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return collected
    }

    private struct SessionMeta {
        var cwd: String?
        var timestamp: Date?
    }

    private static func readSessionMeta(from url: URL) -> SessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // First JSONL record is session_meta; `instructions` can make that line very large.
        guard let lineData = readFirstLine(from: handle, maxBytes: 1_048_576),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { return nil }

        let payload: [String: Any]
        if let nested = obj["payload"] as? [String: Any] {
            payload = nested
        } else {
            payload = obj
        }
        let cwd = payload["cwd"] as? String
        var timestamp: Date?
        if let raw = payload["timestamp"] as? String ?? obj["timestamp"] as? String {
            timestamp = ISO8601DateFormatter.eyesonyou.date(from: raw)
                ?? ISO8601DateFormatter.eyesonyouFractional.date(from: raw)
        }
        return SessionMeta(cwd: cwd, timestamp: timestamp)
    }

    private static func readFirstLine(from handle: FileHandle, maxBytes: Int) -> Data? {
        var buffer = Data()
        let chunkSize = 32_768
        while buffer.count < maxBytes {
            let chunk = handle.readData(ofLength: min(chunkSize, maxBytes - buffer.count))
            if chunk.isEmpty { break }
            if let nl = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                buffer.append(chunk.subdata(in: chunk.startIndex..<nl))
                return buffer.isEmpty ? nil : buffer
            }
            buffer.append(chunk)
        }
        return buffer.isEmpty ? nil : buffer
    }
}

// MARK: - Mutable merge cell

private struct MutableWorkspace {
    var path: String
    var name: String
    var sources: Set<WorkspaceSource> = []
    var lastActiveAt: Date?
    var sessionCount: Int = 0
    var isPinned: Bool = false
    var isActive: Bool = false

    func frozen() -> DiscoveredWorkspace {
        DiscoveredWorkspace(
            name: name,
            path: path,
            sources: sources,
            lastActiveAt: lastActiveAt,
            sessionCount: sessionCount,
            isPinned: isPinned,
            isActive: isActive
        )
    }
}

// MARK: - Hyphen path decoder

/// Decodes Cursor / Claude Code project directory names into absolute paths.
///
/// Cursor: `Users-me-Documents-GitHub-App`
/// Claude: `-Users-me-Documents-GitHub-App`
///
/// Folder names that themselves contain `-` are resolved by longest existing path match.
enum HyphenPathDecoder {
    static func decode(
        _ encoded: String,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Multi-root workspace hashes / ephemeral dirs — skip.
        if trimmed.contains("workspace-json") { return nil }
        if trimmed.hasPrefix("var-folders-") { return nil }

        var absolute = false
        var body = trimmed
        if body.hasPrefix("-") {
            absolute = true
            body.removeFirst()
        } else if body.hasPrefix("Users-") || body.hasPrefix("home-") {
            absolute = true
        }

        let tokens = body.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        if absolute {
            return resolveUnder(
                root: URL(fileURLWithPath: "/"),
                tokens: tokens,
                fileManager: fileManager
            )?.path
        }
        return resolveUnder(root: homeDirectory, tokens: tokens, fileManager: fileManager)?.path
    }

    private static func resolveUnder(
        root: URL,
        tokens: [String],
        fileManager: FileManager
    ) -> URL? {
        var url = root
        var index = 0
        while index < tokens.count {
            let children: [String]
            if let listed = try? fileManager.contentsOfDirectory(atPath: url.path) {
                children = listed
            } else {
                // Path does not exist yet — join remainder literally.
                let rest = tokens[index...].joined(separator: "-")
                url = url.appendingPathComponent(rest)
                return url
            }

            var bestName: String?
            var bestLen = 0
            for length in 1...(tokens.count - index) {
                let candidate = tokens[index..<(index + length)].joined(separator: "-")
                if children.contains(candidate), length >= bestLen {
                    bestName = candidate
                    bestLen = length
                }
            }
            if let bestName, bestLen > 0 {
                url = url.appendingPathComponent(bestName)
                index += bestLen
            } else {
                let rest = tokens[index...].joined(separator: "-")
                url = url.appendingPathComponent(rest)
                return fileManager.fileExists(atPath: url.path) ? url : nil
            }
        }
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}

private extension ISO8601DateFormatter {
    static let eyesonyou: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let eyesonyouFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
