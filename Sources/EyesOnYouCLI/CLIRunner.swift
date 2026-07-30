import Foundation
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouStorage
import EyesOnYouProxyCore

enum ExitCode: Int {
    case ok = 0
    case usage = 1
    case runtime = 2
    case notFound = 3
}

enum CLIRunner {
    static let version = "0.1.3"

    static func run(args: [String]) -> ExitCode {
        do {
            let opts = try GlobalOptions.parse(args)
            if opts.wantHelp && opts.command == nil {
                print(helpText(json: opts.json))
                return .ok
            }
            guard let command = opts.command else {
                print(helpText(json: opts.json))
                return .usage
            }
            return try dispatch(command: command, opts: opts)
        } catch let err as CLIError {
            emitError(err, json: args.contains("--json"))
            return err.exitCode
        } catch {
            emitError(CLIError.runtime(error.localizedDescription), json: args.contains("--json"))
            return .runtime
        }
    }

    private static func dispatch(command: String, opts: GlobalOptions) throws -> ExitCode {
        switch command {
        case "help", "--help", "-h":
            print(helpText(json: opts.json))
            return .ok
        case "version", "--version", "-V":
            emit(["name": "eyesonyou", "version": version, "platform": "macOS"], json: opts.json) {
                print("eyesonyou \(version)")
            }
            return .ok
        case "status":
            return try cmdStatus(opts: opts)
        case "apps":
            return try cmdApps(opts: opts)
        case "traffic":
            return try cmdTraffic(opts: opts)
        case "evaluate", "eval":
            return try cmdEvaluate(opts: opts)
        case "rules":
            return try cmdRules(opts: opts)
        case "search":
            return try cmdSearch(opts: opts)
        case "favorites", "fav":
            return try cmdFavorites(opts: opts)
        case "agent-manifest", "manifest":
            emit(agentManifest(), json: true)
            return .ok
        case "paths":
            return cmdPaths(opts: opts)
        case "workspaces", "projects":
            return try cmdWorkspaces(opts: opts)
        case "attribution", "attr":
            return try cmdAttribution(opts: opts)
        case "route", "routes":
            return try cmdRoute(opts: opts)
        case "enforce":
            return try cmdEnforce(opts: opts)
        case "clash":
            return try cmdClash(opts: opts)
        default:
            throw CLIError.usage("unknown command: \(command)\nRun `eyesonyou help` for usage.")
        }
    }
}

// MARK: - Global options

struct GlobalOptions {
    var json: Bool = false
    var command: String?
    var rest: [String] = []
    var wantHelp: Bool = false
    var flags: [String: String] = [:]
    var positionals: [String] = []

    static func parse(_ args: [String]) throws -> GlobalOptions {
        var o = GlobalOptions()
        var i = 0
        var seenCommand = false
        while i < args.count {
            let a = args[i]
            if a == "--json" {
                o.json = true
            } else if a == "--help" || a == "-h" {
                o.wantHelp = true
            } else if a == "--version" || a == "-V" {
                o.command = "version"
                seenCommand = true
            } else if a.hasPrefix("--"), a.contains("=") {
                let parts = a.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { o.flags[parts[0]] = parts[1] }
            } else if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                    o.flags[key] = args[i + 1]
                    i += 1
                } else {
                    o.flags[key] = "true"
                }
            } else if !seenCommand {
                o.command = a
                seenCommand = true
            } else {
                o.positionals.append(a)
            }
            i += 1
        }
        return o
    }

    func flag(_ name: String, default def: String? = nil) -> String? {
        flags[name] ?? def
    }

    func flagInt(_ name: String, default def: Int) -> Int {
        if let s = flags[name], let v = Int(s) { return v }
        return def
    }

    func flagBool(_ name: String) -> Bool {
        guard let s = flags[name] else { return false }
        return s == "true" || s == "1" || s == "yes"
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case runtime(String)
    case notFound(String)

    var description: String {
        switch self {
        case .usage(let m), .runtime(let m), .notFound(let m): return m
        }
    }

    var exitCode: ExitCode {
        switch self {
        case .usage: return .usage
        case .runtime: return .runtime
        case .notFound: return .notFound
        }
    }
}

// MARK: - Output helpers

func emit(_ value: Any, json: Bool, text: (() -> Void)? = nil) {
    if json {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        } else {
            print("{\"error\":\"not_json_serializable\"}")
        }
    } else if let text {
        text()
    } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func emitError(_ err: CLIError, json: Bool) {
    if json {
        emit([
            "ok": false,
            "error": err.description,
            "code": err.exitCode.rawValue
        ], json: true)
    } else {
        fputs("error: \(err.description)\n", stderr)
    }
}

// MARK: - Paths

enum EyesOnYouPaths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("EyesOnYou", isDirectory: true)
    }

    static var telemetryDB: URL {
        supportDir.appendingPathComponent("telemetry.sqlite")
    }

    static var favoritesFile: URL {
        supportDir.appendingPathComponent("favorites.json")
    }

    /// Same path the host app uses, so CLI and GUI share one restore point.
    static var systemProxyBackup: URL {
        supportDir.appendingPathComponent("system-proxy-backup.json")
    }

    /// Same key as the host app (`AppModel`).
    static let favoritesDefaultsKey = "eyesonyou.favoriteAppKeys"

    static func ensureSupportDir() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }
}

// MARK: - Help / agent manifest

func helpText(json: Bool) -> String {
    if json {
        if let data = try? JSONSerialization.data(withJSONObject: agentManifest(), options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
    }
    return """
    eyesonyou — EyesOnYou CLI for humans and coding agents (Codex, Claude Code, …)

    USAGE
      eyesonyou [--json] <command> [options]

    GLOBAL
      --json              Machine-readable JSON on stdout (always preferred for agents)
      -h, --help          Show this help
      -V, --version       Print version

    COMMANDS
      status              Runtime / data-path status
      apps                List apps by traffic (period-scoped)
      traffic             Totals (optional --app)
      evaluate            Evaluate firewall + route for a flow
      rules               List saved policy rules and groups
      search <query>      Search apps / destinations / rules
      favorites           list | add <signing.id> | remove <signing.id>
      workspaces          Discover local Codex / Cursor / VS Code / Claude projects
      attribution         Live per-process owner app + project for open sockets
      route               list | set | clear | block | allow  (per-app routing policy)
      enforce             status | serve | restore  (local enforcement proxy)
      clash               Measured per-app routes from a local Clash controller API
      paths               Print data directories used by CLI
      agent-manifest      Full command schema as JSON (for agent tool registration)
      help                This help

    EXAMPLES (agent-friendly)
      eyesonyou --json status
      eyesonyou --json apps --period week --limit 20
      eyesonyou --json workspaces --limit 20
      eyesonyou --json workspaces --source codex --limit 15
      eyesonyou --json attribution --limit 25
      eyesonyou route set --app com.google.Chrome --route system
      eyesonyou --json enforce serve --port 18080 --seconds 60
      eyesonyou --json traffic --app com.google.Chrome --period day
      eyesonyou --json evaluate --app com.google.Chrome --host github.com --port 443
      eyesonyou --json search chrome
      eyesonyou --json favorites list
      eyesonyou --json favorites add com.microsoft.VSCode
      eyesonyou --json agent-manifest

    EXIT CODES
      0 ok · 1 usage · 2 runtime · 3 not found

    Docs: docs/CLI.md
    """
}

func agentManifest() -> [String: Any] {
    [
        "name": "eyesonyou",
        "version": CLIRunner.version,
        "description": "Native macOS network observability CLI for EyesOnYou. Prefer --json for agent use.",
        "install": "swift run eyesonyou   # from repo root; or: swift build -c release && .build/release/eyesonyou",
        "global_flags": [
            ["name": "--json", "type": "bool", "description": "JSON stdout"],
            ["name": "--help", "type": "bool"]
        ],
        "exit_codes": [
            "0": "ok",
            "1": "usage/validation",
            "2": "runtime",
            "3": "not found"
        ],
        "commands": [
            [
                "name": "status",
                "summary": "Health, paths, favorite count",
                "flags": []
            ],
            [
                "name": "apps",
                "summary": "Apps ranked by traffic for a period",
                "flags": [
                    ["name": "period", "type": "enum", "values": ["hour", "today", "day", "week", "month", "year"], "default": "week"],
                    ["name": "limit", "type": "int", "default": 20]
                ]
            ],
            [
                "name": "traffic",
                "summary": "Aggregate upload/download totals",
                "flags": [
                    ["name": "app", "type": "string", "description": "signing identifier"],
                    ["name": "period", "type": "enum", "values": ["hour", "today", "day", "week", "month", "year"], "default": "week"]
                ]
            ],
            [
                "name": "evaluate",
                "summary": "Firewall + route decision for a synthetic flow",
                "flags": [
                    ["name": "app", "type": "string", "required": true],
                    ["name": "host", "type": "string", "required": true],
                    ["name": "port", "type": "int", "default": 443],
                    ["name": "team", "type": "string", "required": false]
                ]
            ],
            [
                "name": "rules",
                "summary": "Active policy rules"
            ],
            [
                "name": "search",
                "summary": "Search apps, destinations, rules",
                "positionals": ["query"]
            ],
            [
                "name": "favorites",
                "summary": "list | add <signing.id> | remove <signing.id>",
                "positionals": ["subcommand", "signing_id?"]
            ],
            [
                "name": "agent-manifest",
                "summary": "Emit this schema as JSON"
            ],
            [
                "name": "paths",
                "summary": "Print on-disk paths"
            ],
            [
                "name": "workspaces",
                "summary": "Discover local project folders (Codex desktop/sessions, CodexMonitor, Cursor, VS Code, Claude Code)",
                "aliases": ["projects"],
                "flags": [
                    ["name": "source", "type": "enum", "values": ["all", "codex", "cursor", "vscode", "claude", "codexmonitor"], "default": "all"],
                    ["name": "limit", "type": "int", "default": 40],
                    ["name": "app", "type": "string", "description": "optional signing id filter (e.g. com.openai.codex)"]
                ]
            ],
            [
                "name": "route",
                "summary": "Read and edit per-app routing policy (written to policy.json, shared with the GUI)",
                "aliases": ["routes"],
                "positionals": ["subcommand: list|set|clear|block|allow"],
                "flags": [
                    ["name": "app", "type": "string", "description": "signing identifier"],
                    ["name": "route", "type": "enum", "values": ["direct", "system", "proxy", "inherit"]],
                    ["name": "profile", "type": "string", "description": "proxy profile for --route proxy"],
                    ["name": "host", "type": "string", "description": "hostname suffix for block/allow"],
                    ["name": "team", "type": "string", "required": false]
                ]
            ],
            [
                "name": "enforce",
                "summary": "Run/inspect the local enforcement proxy; serve streams one JSON line per completed flow so routing can be verified with curl",
                "positionals": ["subcommand: status|serve|restore"],
                "flags": [
                    ["name": "port", "type": "int", "default": 0],
                    ["name": "seconds", "type": "int", "default": 20],
                    ["name": "system-proxy", "type": "bool", "description": "also take over the macOS system proxy (restored on exit)"],
                    ["name": "upstream", "type": "string", "description": "host:port to chain to; defaults to the current system proxy"],
                    ["name": "upstream-kind", "type": "enum", "values": ["http", "socks5"], "default": "http"]
                ]
            ],
            [
                "name": "attribution",
                "summary": "Live per-process attribution: owning app (helpers rolled up via ppid) plus the project each socket-holding process is working in",
                "aliases": ["attr"],
                "flags": [
                    ["name": "limit", "type": "int", "default": 25],
                    ["name": "all", "type": "bool", "description": "include local proxy client processes"]
                ]
            ],
            [
                "name": "clash",
                "summary": "Measured per-connection routes from a local Clash/mihomo external controller (exact proxied-vs-direct per process); reports unavailable when no controller exists (e.g. Shadowrocket)",
                "flags": [
                    ["name": "controller", "type": "string", "description": "host:port override; defaults to external-controller from the Clash config"],
                    ["name": "secret", "type": "string", "description": "API secret; defaults to the one in the Clash config"],
                    ["name": "limit", "type": "int", "default": 20]
                ]
            ]
        ],
        "notes_for_agents": [
            "Always pass --json when parsing stdout.",
            "Do not use interactive prompts; none are offered.",
            "There is no seeded data: apps/traffic report only what the host app recorded, and are empty until it has run.",
            "`attribution` samples live processes directly and works without recorded history.",
            "Favorites share the host app UserDefaults key eyesonyou.favoriteAppKeys when available.",
            "Fail-open: evaluate defaults to allow/direct when no matching rule."
        ]
    ]
}
