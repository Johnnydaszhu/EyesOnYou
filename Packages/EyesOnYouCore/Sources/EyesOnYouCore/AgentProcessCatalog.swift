import Foundation

/// Recognizes coding-agent CLIs and the generic runtimes they hide behind.
///
/// Agent CLIs are the loudest unattributed traffic on a developer's machine and the
/// hardest to name: `codex` from Homebrew has no `.app` bundle, and an MCP server
/// shows up only as `npm exec …`. Without this, both land in a `proc.node` bucket.
public enum AgentProcessCatalog {
    public struct Match: Equatable, Sendable {
        /// Signing identifier of the desktop app this CLI belongs to, so a Homebrew
        /// `codex` and ChatGPT.app's embedded one aggregate into one row.
        public let signingIdentifier: String
        public let displayName: String

        public init(signingIdentifier: String, displayName: String) {
            self.signingIdentifier = signingIdentifier
            self.displayName = displayName
        }
    }

    /// Executable basename → owning app. Keys are matched case-insensitively.
    private static let knownAgents: [String: Match] = [
        "claude": Match(signingIdentifier: "com.anthropic.claude-code", displayName: "Claude Code"),
        "claude-code": Match(signingIdentifier: "com.anthropic.claude-code", displayName: "Claude Code"),
        "codex": Match(signingIdentifier: "com.openai.codex", displayName: "Codex"),
        "gemini": Match(signingIdentifier: "com.google.gemini-cli", displayName: "Gemini CLI"),
        "opencode": Match(signingIdentifier: "dev.opencode.cli", displayName: "opencode"),
        "cursor-agent": Match(signingIdentifier: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
        "aider": Match(signingIdentifier: "io.aider.cli", displayName: "Aider"),
        "ollama": Match(signingIdentifier: "com.ollama.ollama", displayName: "Ollama"),
        "goose": Match(signingIdentifier: "dev.block.goose", displayName: "Goose"),
        "amp": Match(signingIdentifier: "com.sourcegraph.amp", displayName: "Amp"),
    ]

    /// Interpreters and package runners that reveal nothing about who is talking.
    /// Traffic from these is attributed to the ancestor process that spawned them.
    private static let genericRuntimes: Set<String> = [
        "node", "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno",
        "python", "python2", "python3", "pipx", "uv", "uvx", "ruby", "perl",
        "java", "sh", "bash", "zsh", "fish", "env", "xargs",
    ]

    /// Identify a process from its executable path plus `argv`.
    ///
    /// `argv` matters because package runners name the real tool only there
    /// (`npm exec xcodebuildmcp@latest`, `uv run aider`).
    public static func match(executablePath: String?, arguments: [String] = []) -> Match? {
        if let executablePath, let direct = knownAgents[basename(executablePath)] {
            return direct
        }
        // argv[0] can differ from the executable when launched through a shim.
        for argument in arguments.prefix(4) {
            let name = basename(argument)
            if let match = knownAgents[name] { return match }
        }
        return nil
    }

    /// True when the executable is an interpreter or package runner, meaning the
    /// meaningful owner is an ancestor process rather than this one.
    public static func isGenericRuntime(executablePath: String?) -> Bool {
        guard let executablePath else { return false }
        return genericRuntimes.contains(basename(executablePath))
    }

    /// Environment variables that name the workspace an editor window is showing.
    ///
    /// Deliberately narrow: a process environment also holds API keys, and
    /// `ProcessRuntimeInfo.environmentValues` only ever returns the keys named here.
    public static let workspaceLabelEnvironmentKeys: Set<String> = [
        "CURSOR_WORKSPACE_LABEL",
        "VSCODE_WORKSPACE_LABEL",
        "WINDSURF_WORKSPACE_LABEL",
    ]

    /// Workspace name from an Electron editor's extension-host process title.
    ///
    /// VS Code-family editors rename that process per window:
    /// `Cursor Helper (Plugin): extension-host EyesOnYou [1-3]`.
    /// One window = one workspace, which makes this a per-window fact rather than a
    /// guess about what the app was doing recently.
    public static func workspaceLabel(fromProcessTitle title: String) -> String? {
        guard let range = title.range(of: "extension-host ") else { return nil }
        var label = String(title[range.upperBound...])
        // Trim the trailing `[window-instance]` marker and process-title padding.
        if let bracket = label.range(of: " [", options: .backwards) {
            label = String(label[..<bracket.lowerBound])
        }
        label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        // A window with no folder open reports a generic label, not a project.
        let lower = label.lowercased()
        if lower == "empty window" || lower == "untitled" { return nil }
        return label
    }

    /// Workspace name for a process, from its environment first and its title second.
    public static func workspaceLabel(pid: Int32, arguments: [String] = []) -> String? {
        let environment = ProcessRuntimeInfo.environmentValues(
            pid: pid,
            keys: workspaceLabelEnvironmentKeys
        )
        for key in workspaceLabelEnvironmentKeys {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        for argument in arguments.prefix(2) {
            if let label = workspaceLabel(fromProcessTitle: argument) { return label }
        }
        return nil
    }

    private static func basename(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).lastPathComponent.lowercased()
    }
}
