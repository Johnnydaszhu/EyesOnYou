# EyesOnYou

[English](./README.md) · [简体中文](./README.zh-CN.md)

Native macOS network observability: per-app traffic, measured egress, and live connections.

<p align="center">
  <img src="docs/screenshots/overview.gif" alt="EyesOnYou overview dashboard" width="860" />
</p>

## Features

- Per-app traffic: live rates, totals, and history
- Per-project drill-down: Claude Code / Codex / Cursor / VS Code traffic splits by the
  project actually being worked on — read from process working directories and editor
  window workspaces, not estimated — and `node` / `npm` children roll up into the app
  that spawned them
- Persistent history: traffic is written to SQLite and reloaded on launch, so totals
  and per-project breakdowns survive restarts; routes and rules persist too
- Measured egress: each app shows whether its bytes actually left direct or through a
  local proxy client, with the split when both paths carried traffic — observed, never
  a rule
- Live connections: each app shows whether it is holding established sockets right now
- Per-app HTTP / HTTPS routing: use each ranking row’s menu to follow the system,
  force direct, or force a proxy. Enforcement is an explicit Settings opt-in and
  restores the previous macOS proxy settings when disabled or when the app quits
- Intent and evidence stay separate: route rules describe what should happen, while
  the egress column continues to show only what was measured
- Privacy first: metadata and counters only — no payload capture, no TLS MITM
  (browser page-title labelling is opt-in and off by default)
- Traffic alerts: daily / cumulative / per-app budgets, burst detection, and
  first-seen-app notices — thresholds configurable, each condition notifies once
  per period rather than repeatedly
- Agent-friendly CLI with JSON output ([docs/CLI.md](docs/CLI.md))

## Download

Install from [GitHub Releases](https://github.com/Johnnydaszhu/EyesOnYou/releases) (`EyesOnYou-<version>.dmg`).

## Quick start

```bash
swift test
swift run eyesonyou --json status

brew install xcodegen   # once
xcodegen generate
xcodebuild -project EyesOnYou.xcodeproj -scheme EyesOnYou \
  -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
```

More: [CONTRIBUTING.md](./CONTRIBUTING.md) · [docs/](./docs/) · [README.zh-CN.md](./README.zh-CN.md)

## Data

Everything shown is measured on your machine — there is no seeded or sample traffic.

| File (`~/Library/Application Support/EyesOnYou/`) | Contents |
|---|---|
| `telemetry.sqlite` | minute / hour / day traffic buckets per app and destination |
| `policy.json` | routes, rules, groups, proxy profiles |
| `favorites.json` | pinned apps |

Retention: minute buckets 7 days, hour buckets 1 year, day buckets kept. Nothing
leaves the machine.

## License

[MIT](./LICENSE)
