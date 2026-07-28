# EyesOnYou CLI

Agent-oriented command-line interface for EyesOnYou. Designed for **Codex**, **Claude Code**, and other coding agents: non-interactive, stable exit codes, optional **JSON** stdout.

## Install / run

From the repo root (no extra dependencies):

```bash
# Debug
swift run eyesonyou --help

# Release binary
swift build -c release --product eyesonyou
./.build/release/eyesonyou --json status

# Optional: put on PATH
ln -sf "$(pwd)/.build/release/eyesonyou" /usr/local/bin/eyesonyou
```

## Agent contract

| Rule | Detail |
|---|---|
| Prefer JSON | Always pass `--json` when parsing |
| No prompts | Commands never ask for interactive input |
| Exit codes | `0` ok · `1` usage · `2` runtime · `3` not found |
| Schema discovery | `eyesonyou --json agent-manifest` |
| Real data only | There is no seeded or demo traffic. Every figure comes from what the host app recorded; if it has not run, results are empty |

## Commands

### `status`

```bash
eyesonyou --json status
```

Returns version, paths, favorites count, whether a policy file exists, and telemetry
statistics (bucket count, app count, and the time span actually recorded).

An empty `telemetry` block means nothing has been captured yet — run the host app.

### `apps`

```bash
eyesonyou --json apps --period week --limit 20
```

| Flag | Default | Values |
|---|---|---|
| `--period` | `week` | `hour` `today` `day` `week` `month` `year` |
| `--limit` | `20` | positive int |

Favorites are sorted to the top. Each app carries `proxy_percent` (share of its bytes
that went through a proxy; `null` when nothing was recorded) and may include
`segments` — websites, `project:` entries for IDEs/agents, and `path:proxy` /
`path:direct` aggregates when traffic went through a local proxy client whose
per-site destinations are invisible.

### `workspaces` (alias `projects`)

```bash
eyesonyou --json workspaces --limit 20
eyesonyou --json workspaces --source codex --limit 15
eyesonyou --json workspaces --app com.openai.codex
```

| Flag | Default | Values |
|---|---|---|
| `--source` | `all` | `all` `codex` `cursor` `vscode` `claude` `codexmonitor` |
| `--limit` | `40` | positive int |
| `--app` | — | signing id filter (e.g. `com.todesktop.230313mzl4w4u92`) |

Reads local metadata (no MITM):

- Codex desktop: `~/.codex/.codex-global-state.json` (`local-projects`)
- Codex sessions: recent `~/.codex/sessions/**/*.jsonl` `cwd`
- CodexMonitor: `~/Library/Application Support/com.dimillian.codexmonitor/workspaces.json`
- Cursor / VS Code: `storage.json` + `~/.cursor/projects`
- Claude Code: `~/.claude/projects`

### `attribution` (alias `attr`)

Live per-process attribution for every open TCP socket: which app owns it, and which
project that process is working in. This is the ground truth behind the dashboard's
sub-project rows.

```bash
eyesonyou --json attribution --limit 25
eyesonyou --json attribution --all     # also list local proxy client processes
```

| Flag | Default | Values |
|---|---|---|
| `--limit` | `25` | positive int |
| `--all` | off | include local proxy client processes |

Two things happen per process:

- **Owner rollup.** A generic runtime (`node`, `npm`, `python`, a shell) is attributed
  to its nearest non-generic ancestor, so an MCP server appears under the agent that
  spawned it instead of as its own `node` row. `rolled_up_to_owner` marks these.
- **Project resolution**, reported with a `project_confidence` you should not ignore:

| Confidence | Source | Strength |
|---|---|---|
| `processDirectory` | the process's own `cwd`, walked up to the repo root | exact |
| `windowLabel` | the editor window's workspace label (one window = one workspace) | exact |
| `ancestorDirectory` | the `cwd` of the ancestor that owns the process | exact |
| `recentSession` | the app's most recent session on disk | **weak** — the app touched this project just now; the bytes are not proven to be its |

Processes with no evidence carry no project at all rather than a plausible guess.

### `route`

Configure the per-app routes the app enforces. Writes the same `policy.json` the GUI
uses, so a rule set here takes effect in a running app.

```bash
eyesonyou --json route list
eyesonyou route set --app com.google.Chrome --route system    # force through the proxy
eyesonyou route set --app com.google.Chrome --route direct    # force bypass
eyesonyou route clear --app com.google.Chrome                 # back to follow-system
eyesonyou route block --app com.google.Chrome --host ads.example.com
eyesonyou route allow --app com.google.Chrome --host ads.example.com
```

| Flag | Values |
|---|---|
| `--app` | signing identifier (`com.google.Chrome`, `proc.curl`, …) |
| `--route` | `direct` `system` `proxy` `inherit` |
| `--profile` | proxy profile name/UUID (with `--route proxy`) |
| `--host` | hostname suffix for `block` / `allow` |

### `enforce`

Run and inspect the local enforcement proxy headlessly — this is how to verify
routing actually works without the GUI.

```bash
eyesonyou --json enforce status                          # takeover state + live settings
eyesonyou --json enforce serve --port 18080 --seconds 60 # bind and stream flow events
eyesonyou enforce restore                                # undo a takeover (crash recovery)
```

| Flag (`serve`) | Default | Meaning |
|---|---|---|
| `--port` | `0` (kernel-assigned) | loopback port to bind |
| `--seconds` | `20` | how long to serve before exiting |
| `--system-proxy` | off | also point the macOS system proxy at it (restored on exit) |
| `--upstream` | system proxy | `host:port` to chain to |
| `--upstream-kind` | `http` | `http` or `socks5` |

`serve` prints a `listening` record with the port first, then one JSON line per
completed flow (`app`, `host`, `action`, `bytes_up`, `bytes_down`), then a summary.
Without `--system-proxy` it touches nothing — point a client at it explicitly:

```bash
curl --proxy 127.0.0.1:18080 https://example.com
```

### `traffic`

```bash
eyesonyou --json traffic --period day
eyesonyou --json traffic --app com.google.Chrome --period week
```

Optional `--team` with `--app` for full identity.

### `evaluate` (alias `eval`)

```bash
eyesonyou --json evaluate --app com.google.Chrome --host github.com --port 443
```

Returns firewall action, route action, and whether the transparent proxy should claim the flow (fail-open defaults).

### `rules`

```bash
eyesonyou --json rules
```

Lists the policy rules and groups the host app saved to
`~/Library/Application Support/EyesOnYou/policy.json`. Empty until you configure one.

### `search`

```bash
eyesonyou --json search chrome
eyesonyou --json search "github"
```

Searches display names, signing IDs, destinations, and rule notes.

### `favorites`

```bash
eyesonyou --json favorites list
eyesonyou --json favorites add com.microsoft.VSCode
eyesonyou --json favorites remove com.microsoft.VSCode
```

Persists to:

- `UserDefaults` key `eyesonyou.favoriteAppKeys` (same as the host app)
- `~/Library/Application Support/EyesOnYou/favorites.json`

### `paths`

Print support directory and DB paths.

### `agent-manifest`

Full machine-readable command schema (for tool registration in agents).

## Suggested agent workflow

1. `eyesonyou --json agent-manifest` — register tools once  
2. `eyesonyou --json status` — check mode / paths  
3. `eyesonyou --json apps --period week` — top consumers  
4. `eyesonyou --json evaluate --app … --host …` — policy check before suggesting a rule  
5. `eyesonyou --json favorites add …` — pin an app for the user  

## Where the data comes from

The CLI is a reader. The host app samples live sockets, attributes them to apps and
projects, and flushes to shared files; the CLI opens the same paths read-only.

| File | Written by | Contents |
|---|---|---|
| `~/Library/Application Support/EyesOnYou/telemetry.sqlite` | host app | minute / hour / day traffic buckets per app + destination |
| `~/Library/Application Support/EyesOnYou/policy.json` | host app | routes, rules, groups, proxy profiles |
| `~/Library/Application Support/EyesOnYou/favorites.json` | either | pinned apps |

Retention: minute buckets for 7 days, hour buckets for a year, day buckets kept.

`attribution` is the exception — it samples live processes itself and needs no
recorded history, which makes it useful the moment you install the CLI.

## Relationship to the GUI

| Surface | Role |
|---|---|
| Host app | SwiftUI dashboard, menu bar, per-app HTTP / HTTPS route control |
| CLI | Scriptable query + evaluate + favorites for agents/CI |

Both share pure packages (`EyesOnYouCore`, `RuleEngine`, `Storage`, …) and the favorites key.
