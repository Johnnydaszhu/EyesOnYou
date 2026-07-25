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
| Demo mode | Without a live system extension / telemetry DB, traffic & apps use a **deterministic demo seed** so evaluate/search still work |

## Commands

### `status`

```bash
eyesonyou --json status
```

Returns version, mode (`demo` \| `sqlite`), paths, favorites count.

### `apps`

```bash
eyesonyou --json apps --period week --limit 20
```

| Flag | Default | Values |
|---|---|---|
| `--period` | `week` | `hour` `today` `day` `week` `month` `year` |
| `--limit` | `20` | positive int |

Favorites are sorted to the top. Each app may include `segments` (websites / projects / sessions).

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

Lists policy rules + groups from the CLI policy store (demo defaults unless extended later).

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

## Live telemetry

If `~/Library/Application Support/EyesOnYou/telemetry.sqlite` exists (future host flush), CLI may switch mode to `sqlite`. Today the packaged CLI primarily uses the **demo aggregator** so agents have a reliable offline surface.

## Relationship to the GUI

| Surface | Role |
|---|---|
| Host app | SwiftUI dashboard, menu bar, system extension install |
| CLI | Scriptable query + evaluate + favorites for agents/CI |

Both share pure packages (`EyesOnYouCore`, `RuleEngine`, `Storage`, …) and the favorites key.
