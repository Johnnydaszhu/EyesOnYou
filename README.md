# FlowLens

[English](./README.md) · [简体中文](./README.zh-CN.md)

Native macOS network observability, per-app firewall, and selective proxy.

> Working codename — verify trademark and domain before a public launch.

## Features (v0.1)

- **Per-app traffic** — live rates, totals, history rollups (today / week / month / last 30 days)
- **Direct vs proxy rates** — menu-bar mini chart splits upload/download by path and share
- **Selective proxy** — per-app and named-group routes (direct / system / SOCKS5 · HTTP CONNECT)
- **Native stack** — SwiftUI + AppKit host, system extension with Filter + Transparent Proxy providers
- **Privacy first** — metadata and counters only; no payload capture, no TLS MITM
- **Agent-friendly CLI** — JSON output for scripts and coding agents (`docs/CLI.md`)

## Quick start

```bash
# Unit tests (Core / RuleEngine / Storage) — no signing required
swift test

# Agent / script CLI (JSON-friendly)
swift run flowlens --json status
swift run flowlens --json apps --period week
swift run flowlens --json evaluate --app com.google.Chrome --host github.com
# Full CLI contract: docs/CLI.md · AGENTS.md

# Generate Xcode project and build host app
brew install xcodegen   # once
xcodegen generate
xcodebuild -project FlowLens.xcodeproj -scheme FlowLens \
  -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
```

The host launches with **demo telemetry** when the system extension is not installed or signed, so the dashboard and menu-bar popover stay usable for development. The CLI uses the same pure packages with a deterministic demo seed for offline agent use.

## Repository layout

| Path | Role |
|---|---|
| `Packages/FlowLensCore` | Identity, flows, counter math, in-memory aggregator |
| `Packages/FlowLensRuleEngine` | Rules, groups, snapshot evaluate API |
| `Packages/FlowLensStorage` | SQLite WAL telemetry store |
| `Packages/FlowLensIPC` | Host ↔ extension messages |
| `Packages/FlowLensProxyCore` | Proxy route helpers / profiles |
| `App/FlowLens` | Host UI (dashboard + menu bar) |
| `NetworkExtension` | Filter + Transparent Proxy providers |
| `Sources/FlowLensCLI` | `flowlens` CLI |
| `schema/` | SQL drafts |
| `docs/` | Spec, ADRs, Xcode bootstrap, CLI |
| `examples/` | Earlier design skeletons (reference only) |

## Docs

1. Spec: [`FlowLens_macOS_原生网络工具开发规格_v0.1.md`](./FlowLens_macOS_原生网络工具开发规格_v0.1.md)
2. Phase 0 API spike: [`docs/PHASE0_API_SPIKE.md`](./docs/PHASE0_API_SPIKE.md)
3. Double-counting: [`docs/DOUBLE_COUNTING_AND_CORRELATION.md`](./docs/DOUBLE_COUNTING_AND_CORRELATION.md)
4. Xcode bootstrap: [`docs/XCODE_BOOTSTRAP.md`](./docs/XCODE_BOOTSTRAP.md)
5. Contributing: [`CONTRIBUTING.md`](./CONTRIBUTING.md)
6. Chinese README: [`README.zh-CN.md`](./README.zh-CN.md)

## System extension

One `.systemextension` embeds two provider classes:

- `FlowFilterDataProvider` — observe / stats / allow / block (fail-open default allow)
- `FlowTransparentProxyProvider` — selective proxy (default off; unclaimed flows stay with the OS)

Live capture needs a Developer Team, matching App Groups, entitlements under [`config/`](config/), and user approval in System Settings. See [CONTRIBUTING.md](./CONTRIBUTING.md) for signing limits.

## License

[MIT](./LICENSE) — free to use, modify, and redistribute with attribution.

Do **not** import GPL-licensed code (for example LuLu) into this tree if you want to keep MIT compatibility. Architecture ideas may be studied; source must remain a clean-room implementation.
