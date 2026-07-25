import Foundation
import Darwin

/// Resolve a process PID (and truncated `lsof` COMMAND) to a stable app identity.
///
/// macOS `lsof -nP` truncates COMMAND to ~9 characters, so Chrome Helpers appear as
/// `Google` rather than `Chrome`. Helper PIDs also often fail `NSRunningApplication`.
/// This type walks `proc_pidpath` up to the outermost `.app` bundle instead.
public enum ProcessAppIdentity {
    public struct Resolved: Equatable, Sendable {
        public var signingIdentifier: String
        public var displayName: String

        public init(signingIdentifier: String, displayName: String) {
            self.signingIdentifier = signingIdentifier
            self.displayName = displayName
        }
    }

    /// Map helper / networking subprocess IDs onto the installable parent app.
    public static func canonicalSigningID(_ raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return id }
        if let mapped = parentAliases[id] {
            return mapped
        }
        let lower = id.lowercased()
        for suffix in helperSuffixes {
            if lower.hasSuffix(suffix) {
                return String(id.dropLast(suffix.count))
            }
        }
        return id
    }

    /// Best-effort resolve from PID + optional truncated lsof command.
    public static func resolve(pid: Int32, lsofCommand: String = "") -> Resolved? {
        if let path = executablePath(pid: pid),
           let fromPath = resolve(executablePath: path, lsofCommand: lsofCommand) {
            return fromPath
        }
        return resolveFromTruncatedCommand(lsofCommand)
    }

    /// Pure path / plist resolution (testable without a live PID).
    public static func resolve(executablePath path: String, lsofCommand: String = "") -> Resolved? {
        guard let appURL = outermostAppBundleURL(fromExecutablePath: path) else {
            return resolveFromTruncatedCommand(lsofCommand)
        }
        let info = readInfoDictionary(at: appURL)
        let rawID = (info["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let signing = canonicalSigningID(rawID.isEmpty ? guessSigningID(appURL: appURL, lsofCommand: lsofCommand) : rawID)
        guard !signing.isEmpty else { return nil }

        let display = preferredDisplayName(info: info, appURL: appURL, signingID: signing, lsofCommand: lsofCommand)
        return Resolved(signingIdentifier: signing, displayName: display)
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Prefer the outermost `.app` (Chrome Helper lives inside Google Chrome.app).
    public static func outermostAppBundleURL(fromExecutablePath path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        var found: URL?
        while url.path != "/" {
            if url.pathExtension.lowercased() == "app" {
                found = url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return found
    }

    // MARK: - Internals

    private static let helperSuffixes = [
        ".helper.renderer",
        ".helper.plugin",
        ".helper.gpu",
        ".helper",
        ".webkit.networking",
        ".networking",
        ".webcontent",
        ".plugincontainer",
    ]

    private static let parentAliases: [String: String] = [
        "com.apple.WebKit.Networking": "com.apple.Safari",
        "com.apple.WebKit.WebContent": "com.apple.Safari",
        "com.apple.Safari.WebApp": "com.apple.Safari",
        "com.google.Chrome.helper": "com.google.Chrome",
        "com.google.Chrome.helper.renderer": "com.google.Chrome",
        "com.google.Chrome.helper.gpu": "com.google.Chrome",
        "com.google.Chrome.helper.plugin": "com.google.Chrome",
        "com.microsoft.edgemac.helper": "com.microsoft.edgemac",
        "org.mozilla.plugincontainer": "org.mozilla.firefox",
        "com.hnc.Discord.helper": "com.hnc.Discord",
        "com.tinyspeck.slackmacgap.helper": "com.tinyspeck.slackmacgap",
        "com.spotify.client.helper": "com.spotify.client",
    ]

    private static let truncatedCommandHints: [String: (signing: String, display: String)] = [
        "Google": ("com.google.Chrome", "Google Chrome"),
        "Chrome": ("com.google.Chrome", "Google Chrome"),
        "Chromium": ("org.chromium.Chromium", "Chromium"),
        "Firefox": ("org.mozilla.firefox", "Firefox"),
        "Safari": ("com.apple.Safari", "Safari"),
        "Microsoft": ("com.microsoft.edgemac", "Microsoft Edge"),
        "Brave": ("com.brave.Browser", "Brave Browser"),
        "Arc": ("company.thebrowser.Browser", "Arc"),
    ]

    private static func resolveFromTruncatedCommand(_ command: String) -> Resolved? {
        let key = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hint = truncatedCommandHints[key] else { return nil }
        return Resolved(signingIdentifier: hint.signing, displayName: hint.display)
    }

    private static func guessSigningID(appURL: URL, lsofCommand: String) -> String {
        let name = appURL.deletingPathExtension().lastPathComponent.lowercased()
        if name.contains("chrome") { return "com.google.Chrome" }
        if name.contains("chromium") { return "org.chromium.Chromium" }
        if name.contains("firefox") { return "org.mozilla.firefox" }
        if name.contains("safari") { return "com.apple.Safari" }
        if name.contains("edge") { return "com.microsoft.edgemac" }
        if name.contains("brave") { return "com.brave.Browser" }
        if let fromCommand = resolveFromTruncatedCommand(lsofCommand) {
            return fromCommand.signingIdentifier
        }
        return ""
    }

    private static func preferredDisplayName(
        info: [String: Any],
        appURL: URL,
        signingID: String,
        lsofCommand: String
    ) -> String {
        if let display = info["CFBundleDisplayName"] as? String,
           !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return display
        }
        if let name = info["CFBundleName"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Avoid advertising the helper binary name when we already canonicalized.
            let lower = name.lowercased()
            if !(lower.contains("helper") || lower.contains("renderer")) {
                return name
            }
        }
        if let hint = truncatedCommandHints[lsofCommand] {
            return hint.display
        }
        if signingID == "com.google.Chrome" {
            return "Google Chrome"
        }
        let leaf = appURL.deletingPathExtension().lastPathComponent
        if leaf.lowercased().contains("helper") {
            return leaf.replacingOccurrences(of: " Helper", with: "")
        }
        return leaf
    }

    // MARK: - Ownership rollup

    /// An identity plus the process it was read from.
    public struct Owned: Equatable, Sendable {
        public var identity: Resolved
        /// PID the identity came from — the socket holder itself, or an ancestor.
        public var owningPID: Int32
        /// True when the socket holder was a generic runtime and we climbed to its owner.
        public var isRolledUp: Bool

        public init(identity: Resolved, owningPID: Int32, isRolledUp: Bool) {
            self.identity = identity
            self.owningPID = owningPID
            self.isRolledUp = isRolledUp
        }
    }

    /// Resolve the app that *owns* a socket-holding process.
    ///
    /// MCP servers, language servers, and build tools are spawned as bare `node` /
    /// `python` children of an editor or agent. Reporting them as `node` fragments one
    /// app into a dozen meaningless rows, so a generic runtime defers to its nearest
    /// non-generic ancestor.
    public static func resolveOwning(
        pid: Int32,
        lsofCommand: String = "",
        maxDepth: Int = 6
    ) -> Owned? {
        if let own = identify(pid: pid, lsofCommand: lsofCommand), !own.isGeneric {
            return Owned(identity: own.identity, owningPID: pid, isRolledUp: false)
        }
        for ancestor in ProcessRuntimeInfo.ancestors(of: pid, maxDepth: maxDepth) {
            if let parent = identify(pid: ancestor, lsofCommand: ""), !parent.isGeneric {
                return Owned(identity: parent.identity, owningPID: ancestor, isRolledUp: true)
            }
        }
        // Nothing better upstream — keep whatever the process itself reported.
        if let own = identify(pid: pid, lsofCommand: lsofCommand) {
            return Owned(identity: own.identity, owningPID: pid, isRolledUp: false)
        }
        return nil
    }

    private struct Candidate {
        var identity: Resolved
        var isGeneric: Bool
    }

    private static func identify(pid: Int32, lsofCommand: String) -> Candidate? {
        let execPath = executablePath(pid: pid)
            ?? ProcessRuntimeInfo.executablePathFromArgs(pid: pid)

        // A real `.app` bundle is the strongest signal, including Electron editors
        // whose helper binaries are themselves called `node`.
        if let execPath,
           outermostAppBundleURL(fromExecutablePath: execPath) != nil,
           let resolved = resolve(executablePath: execPath, lsofCommand: lsofCommand) {
            return Candidate(identity: resolved, isGeneric: false)
        }

        let arguments = ProcessRuntimeInfo.arguments(pid: pid)
        if let match = AgentProcessCatalog.match(executablePath: execPath, arguments: arguments) {
            return Candidate(
                identity: Resolved(
                    signingIdentifier: match.signingIdentifier,
                    displayName: match.displayName
                ),
                isGeneric: false
            )
        }

        if AgentProcessCatalog.isGenericRuntime(executablePath: execPath) {
            let name = execPath.map { ($0 as NSString).lastPathComponent } ?? lsofCommand
            return Candidate(
                identity: Resolved(signingIdentifier: "proc.\(name)", displayName: name),
                isGeneric: true
            )
        }

        if let resolved = resolve(pid: pid, lsofCommand: lsofCommand) {
            return Candidate(identity: resolved, isGeneric: false)
        }

        // A plain command-line tool (curl, ssh, a compiled binary) has no bundle and
        // no catalog entry, but it is still a distinct program the user can write a
        // rule for. Name it after its executable rather than discarding it — every
        // caller previously had to invent this fallback, and they disagreed.
        if let name = execPath.map({ ($0 as NSString).lastPathComponent }), !name.isEmpty {
            return Candidate(
                identity: Resolved(signingIdentifier: "proc.\(name)", displayName: name),
                isGeneric: false
            )
        }
        let command = lsofCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty {
            return Candidate(
                identity: Resolved(signingIdentifier: "proc.\(command)", displayName: command),
                isGeneric: false
            )
        }
        return nil
    }

    private static func readInfoDictionary(at appURL: URL) -> [String: Any] {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else { return [:] }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard
            let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            ),
            let dict = object as? [String: Any]
        else {
            return [:]
        }
        return dict
    }
}
