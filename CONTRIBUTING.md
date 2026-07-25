# Contributing to EyesOnYou

EyesOnYou is a native macOS network observability, firewall, and selective-proxy tool. Thank you for helping build it.

## License

Contributions are accepted under the **MIT License**. Do **not** copy or adapt GPL-licensed code (including LuLu) into this tree if you want to keep MIT compatibility.

## Privacy: Apple Developer account material

**Never commit** anything that identifies or authenticates your Apple Developer account:

| Keep out of git | Examples |
|---|---|
| Team ID | `DEVELOPMENT_TEAM = ABCD123456` |
| Real App IDs / App Groups | anything other than `com.example.EyesOnYou*` placeholders |
| Signing secrets | `.p12`, `.p8`, `AuthKey_*.p8`, `.mobileprovision`, `.cer` |
| Local Xcode state | `xcuserdata/`, `*.xcuserstate` |
| Machine clutter | `.DS_Store`, absolute home-directory paths |

Tracked signing settings must stay **placeholder / ad-hoc**:

- `PRODUCT_BUNDLE_IDENTIFIER = com.example.EyesOnYou` (and `.NetworkExtension`)
- `DEVELOPMENT_TEAM = ""`
- `CODE_SIGN_IDENTITY = "-"`

Put real Team IDs only in **gitignored** files such as `config/Local.xcconfig` (see `config/EyesOnYou.xcconfig.example`).

Public Team IDs of *other* apps (e.g. Chrome in demo fixtures) are third-party metadata used for synthetic traffic — not this project’s Apple account.

## Repository layout

| Path | Role |
|---|---|
| `Packages/EyesOnYouCore` | App identity, flow models, counter math, in-memory telemetry aggregator |
| `Packages/EyesOnYouRuleEngine` | Rules, app groups, route/firewall snapshot evaluation |
| `Packages/EyesOnYouStorage` | SQLite WAL telemetry store (Foundation + SQLite3) |
| `Packages/EyesOnYouIPC` | Host ↔ system-extension message models |
| `Packages/EyesOnYouProxyCore` | Selective-proxy route helpers / profiles |
| `App/EyesOnYou` | Host app (SwiftUI + AppKit menu bar) |
| `NetworkExtension` | System extension with Filter + Transparent Proxy providers |
| `Sources/EyesOnYouCLI` | Agent-oriented CLI (`eyesonyou`) |
| `schema/` | SQL drafts for rules and telemetry |
| `docs/` | Spec, ADRs, Xcode bootstrap, CLI |
| `examples/` | Reference skeletons (not the shipping build targets) |
| `AGENTS.md` | Instructions for Codex / Claude Code |

Pure packages have **no NetworkExtension entitlements** and are tested with:

```bash
swift test
swift run eyesonyou --json agent-manifest
```

## Build the host app

```bash
# Generate Xcode project (requires xcodegen: brew install xcodegen)
xcodegen generate

# Build (ad-hoc / local team)
xcodebuild -project EyesOnYou.xcodeproj -scheme EyesOnYou \
  -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
  build
```

### Keeping macOS permissions across rebuilds

Ad-hoc signing (`CODE_SIGN_IDENTITY="-"`) produces a new code identity on every
build, so macOS treats each build as a different app and re-asks for Accessibility
and "access data from other apps". Sign with a stable local certificate to avoid
that:

```bash
scripts/dev-signing-identity.sh create        # once per machine
```

That writes `config/LocalSigning.xcconfig` (git-ignored), which the project includes,
so **Xcode builds pick it up too** — no environment variable needed. Verify with:

```bash
codesign -d -r- <path-to>/EyesOnYou.app   # "certificate leaf = ...", not "cdhash ..."
```

A `cdhash` requirement means the build is still ad-hoc and macOS will re-ask for
Accessibility after every rebuild. Override per-invocation with
`EYESONYOU_CODE_SIGN_IDENTITY=-` if you want ad-hoc back.

Subsequent builds keep the same designated requirement, so a permission granted
once stays granted. Leaving the variable unset keeps the old ad-hoc behaviour.
Switching between ad-hoc and the stable identity leaves the embedded network
extension signed the old way, and the next build fails with "Embedded binary is
not signed with the same certificate as the parent app". Run `xcodebuild ... clean`
once when you change mode.

Network Extension features require a paid Apple Developer Team, matching App Group IDs, and user approval of the system extension. Without signing, the host app still runs and records **real** traffic through socket-level attribution — there is no demo telemetry.

See [`docs/XCODE_BOOTSTRAP.md`](docs/XCODE_BOOTSTRAP.md) and [`config/`](config/) for entitlements.

## Release DMG

```bash
./scripts/build-dmg.sh           # → dist/EyesOnYou-<version>.dmg
./scripts/publish-release.sh     # upload to GitHub Releases (gh auth required)
```

Pushing `v*` tags also runs [`.github/workflows/release.yml`](.github/workflows/release.yml). Details: [`docs/RELEASE.md`](docs/RELEASE.md).

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
