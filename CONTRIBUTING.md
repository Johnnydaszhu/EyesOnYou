# Contributing to FlowLens

FlowLens is a native macOS network observability, firewall, and selective-proxy tool. Thank you for helping build it.

## License

Contributions are accepted under the **MIT License**. Do **not** copy or adapt GPL-licensed code (including LuLu) into this tree if you want to keep MIT compatibility.

## Privacy: Apple Developer account material

**Never commit** anything that identifies or authenticates your Apple Developer account:

| Keep out of git | Examples |
|---|---|
| Team ID | `DEVELOPMENT_TEAM = ABCD123456` |
| Real App IDs / App Groups | anything other than `com.example.FlowLens*` placeholders |
| Signing secrets | `.p12`, `.p8`, `AuthKey_*.p8`, `.mobileprovision`, `.cer` |
| Local Xcode state | `xcuserdata/`, `*.xcuserstate` |
| Machine clutter | `.DS_Store`, absolute home-directory paths |

Tracked signing settings must stay **placeholder / ad-hoc**:

- `PRODUCT_BUNDLE_IDENTIFIER = com.example.FlowLens` (and `.NetworkExtension`)
- `DEVELOPMENT_TEAM = ""`
- `CODE_SIGN_IDENTITY = "-"`

Put real Team IDs only in **gitignored** files such as `config/Local.xcconfig` (see `config/FlowLens.xcconfig.example`).

Public Team IDs of *other* apps (e.g. Chrome in demo fixtures) are third-party metadata used for synthetic traffic — not this project’s Apple account.

## Repository layout

| Path | Role |
|---|---|
| `Packages/FlowLensCore` | App identity, flow models, counter math, in-memory telemetry aggregator |
| `Packages/FlowLensRuleEngine` | Rules, app groups, route/firewall snapshot evaluation |
| `Packages/FlowLensStorage` | SQLite WAL telemetry store (Foundation + SQLite3) |
| `Packages/FlowLensIPC` | Host ↔ system-extension message models |
| `Packages/FlowLensProxyCore` | Selective-proxy route helpers / profiles |
| `App/FlowLens` | Host app (SwiftUI + AppKit menu bar) |
| `NetworkExtension` | System extension with Filter + Transparent Proxy providers |
| `Sources/FlowLensCLI` | Agent-oriented CLI (`flowlens`) |
| `schema/` | SQL drafts for rules and telemetry |
| `docs/` | Spec, ADRs, Xcode bootstrap, CLI |
| `examples/` | Reference skeletons (not the shipping build targets) |
| `AGENTS.md` | Instructions for Codex / Claude Code |

Pure packages have **no NetworkExtension entitlements** and are tested with:

```bash
swift test
swift run flowlens --json agent-manifest
```

## Build the host app

```bash
# Generate Xcode project (requires xcodegen: brew install xcodegen)
xcodegen generate

# Build (ad-hoc / local team)
xcodebuild -project FlowLens.xcodeproj -scheme FlowLens \
  -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
  build
```

Network Extension features require a paid Apple Developer Team, matching App Group IDs, and user approval of the system extension. Without signing, the host still launches with **demo telemetry** so UI and package logic remain testable.

See [`docs/XCODE_BOOTSTRAP.md`](docs/XCODE_BOOTSTRAP.md) and [`config/`](config/) for entitlements.

## Development principles

1. **Fail-open** by default for firewall and proxy (do not brick the Mac).
2. **No payload inspection / TLS MITM** (ADR 0002).
3. Hot paths: no SQLite, DNS, icon lookup, or sync XPC.
4. Keep rule evaluation and aggregation in pure packages with unit tests.
5. One system extension package, two provider classes (ADR 0001).

## Tests

```bash
swift test 2>&1 | tee package-tests.log
```

Add tests next to the package they cover. Prefer driving real aggregator / storage / rule APIs over fixture-only stubs.

## Code style

- Swift 5.9+ / Swift 6 language mode where practical
- `Sendable` value types at package boundaries
- Prefer explicit types over magic strings for route/firewall enums
