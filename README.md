# EyesOnYou

[English](./README.md) · [简体中文](./README.zh-CN.md)

Native macOS network observability, per-app firewall, and selective proxy.

> Formerly EyesOnYou. Verify trademark and domain before a public launch.

## Screenshots

<p align="center">
  <img src="docs/screenshots/overview.gif" alt="EyesOnYou overview dashboard" width="860" />
</p>

Overview dashboard: period totals, live traffic, proxy routing mix, sunburst traffic map, and per-app ranking (favorites, groups, selective proxy).

## Features (v0.1)

- **Per-app traffic** — live rates, totals, history rollups (today / week / month / last 30 days)
- **Direct vs proxy rates** — menu-bar mini chart splits upload/download by path and share
- **Selective proxy** — per-app and named-group routes (direct / system / SOCKS5 · HTTP CONNECT)
- **Native stack** — SwiftUI + AppKit host, system extension with Filter + Transparent Proxy providers
- **Privacy first** — metadata and counters only; no payload capture, no TLS MITM
- **Agent-friendly CLI** — JSON output for scripts and coding agents (`docs/CLI.md`)
- **In-app updates** — checks [GitHub Releases](https://github.com/Johnnydaszhu/EyesOnYou/releases) automatically; footer version label for manual check / download

## Download / DMG

GitHub Releases host the installable disk image (`EyesOnYou-<version>.dmg`).

```bash
# Local: build DMG into dist/
./scripts/build-dmg.sh

# Local: build + publish Release (requires gh auth)
./scripts/publish-release.sh 0.1.0

# Or push a tag — Actions builds and uploads the DMG
git tag -a v0.1.0 -m "EyesOnYou 0.1.0"
git push origin v0.1.0
```

Full notes: [`docs/RELEASE.md`](docs/RELEASE.md). CI builds are ad-hoc signed (demo telemetry); Developer ID + notarization is documented for maintainer machines.

## Quick start

```bash
# Unit tests (Core / RuleEngine / Storage) — no signing required
swift test

# Agent / script CLI (JSON-friendly)
swift run eyesonyou --json status
swift run eyesonyou --json apps --period week
swift run eyesonyou --json evaluate --app com.google.Chrome --host github.com
# Full CLI contract: docs/CLI.md · AGENTS.md

# Generate Xcode project and build host app
brew install xcodegen   # once
xcodegen generate
xcodebuild -project EyesOnYou.xcodeproj -scheme EyesOnYou \
  -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
```

The host launches with **demo telemetry** when the system extension is not installed or signed, so the dashboard and menu-bar popover stay usable for development. The CLI uses the same pure packages with a deterministic demo seed for offline agent use.

## Repository layout

| Path | Role |
|---|---|
| `Packages/EyesOnYouCore` | Identity, flows, counter math, in-memory aggregator |
| `Packages/EyesOnYouRuleEngine` | Rules, groups, snapshot evaluate API |
| `Packages/EyesOnYouStorage` | SQLite WAL telemetry store |
| `Packages/EyesOnYouIPC` | Host ↔ extension messages |
| `Packages/EyesOnYouProxyCore` | Proxy route helpers / profiles |
| `App/EyesOnYou` | Host UI (dashboard + menu bar) |
| `NetworkExtension` | Filter + Transparent Proxy providers |
| `Sources/EyesOnYouCLI` | `eyesonyou` CLI |
| `schema/` | SQL drafts |
| `docs/` | Spec, ADRs, Xcode bootstrap, CLI, screenshots |
| `examples/` | Earlier design skeletons (reference only) |

## Docs

1. Spec: [`EyesOnYou_macOS_原生网络工具开发规格_v0.1.md`](./EyesOnYou_macOS_原生网络工具开发规格_v0.1.md)
2. Phase 0 API spike: [`docs/PHASE0_API_SPIKE.md`](./docs/PHASE0_API_SPIKE.md)
3. Double-counting: [`docs/DOUBLE_COUNTING_AND_CORRELATION.md`](./docs/DOUBLE_COUNTING_AND_CORRELATION.md)
4. Xcode bootstrap: [`docs/XCODE_BOOTSTRAP.md`](./docs/XCODE_BOOTSTRAP.md)
5. Contributing: [`CONTRIBUTING.md`](./CONTRIBUTING.md)
6. Release / DMG: [`docs/RELEASE.md`](./docs/RELEASE.md)
7. Chinese README: [`README.zh-CN.md`](./README.zh-CN.md)

## System extension

One `.systemextension` embeds two provider classes:

- `FlowFilterDataProvider` — observe / stats / allow / block (fail-open default allow)
- `FlowTransparentProxyProvider` — selective proxy (default off; unclaimed flows stay with the OS)

Live capture needs a Developer Team, matching App Groups, entitlements under [`config/`](config/), and user approval in System Settings. See [CONTRIBUTING.md](./CONTRIBUTING.md) for signing limits.

## License

[MIT](./LICENSE) — free to use, modify, and redistribute with attribution.

Do **not** import GPL-licensed code (for example LuLu) into this tree if you want to keep MIT compatibility. Architecture ideas may be studied; source must remain a clean-room implementation.
