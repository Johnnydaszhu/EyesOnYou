# AGENTS.md — EyesOnYou for coding agents

This repository is optimized for **Codex**, **Claude Code**, and similar agents.

## Prefer the CLI for data and policy checks

```bash
# From repo root
swift run eyesonyou --json agent-manifest   # discover commands
swift run eyesonyou --json status
swift run eyesonyou --json apps --period week --limit 15
swift run eyesonyou --json workspaces --limit 20
swift run eyesonyou --json attribution --limit 25   # live: which app + project owns each socket
swift run eyesonyou --json route list               # per-app route policy
swift run eyesonyou --json enforce status           # system-proxy takeover state
swift run eyesonyou --json evaluate --app com.google.Chrome --host github.com
swift run eyesonyou --json search vscode
swift run eyesonyou --json favorites list
```

- **Always use `--json`** when you will parse output.
- **Do not** spawn the GUI for routine queries.
- Full contract: [`docs/CLI.md`](docs/CLI.md).

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Usage / validation |
| 2 | Runtime |
| 3 | Not found |

## Build / test (no entitlements)

```bash
swift test
swift build --product eyesonyou
```

Host app (GUI) requires Xcode:

```bash
xcodegen generate
xcodebuild -project EyesOnYou.xcodeproj -scheme EyesOnYou \
  -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
```

## Verify traffic enforcement without the GUI

The CLI is now the only way to enforce routes — the GUI observes and never touches
the system proxy. The local proxy is fully driveable from the CLI, so a change can
still be proven end to end on a real machine:

```bash
# 1. state a rule
swift run eyesonyou route block --app proc.curl --host example.com

# 2. serve on a port; touches nothing unless --system-proxy is passed
swift run eyesonyou --json enforce serve --port 18080 --seconds 45 &

# 3. drive it and assert
curl --proxy 127.0.0.1:18080 https://example.com     # => CONNECT tunnel failed, 403
curl --proxy 127.0.0.1:18080 https://www.apple.com   # => 200

# 4. clean up
swift run eyesonyou route allow --app proc.curl --host example.com
```

Each completed flow is printed as a JSON line with the resolved app, action, and byte
counts. Use `enforce restore` if a run with `--system-proxy` was interrupted.

## Keep macOS permissions across rebuilds

Ad-hoc signing gives every build a new code identity, so macOS throws away
Accessibility / app-data grants and prompts again — which stalls any unattended
run, because nobody is there to click Allow. Sign with a stable local certificate
instead:

```bash
scripts/dev-signing-identity.sh create   # once per machine; writes config/LocalSigning.xcconfig
xcodebuild -project EyesOnYou.xcodeproj -scheme EyesOnYou -configuration Debug build
```

The generated xcconfig is included by the project, so Xcode and `xcodebuild` both use
it without any environment variable.

Verify it is stable — this must not change between builds:

```bash
codesign -d -r- <path-to>/EyesOnYou.app     # "... certificate leaf = H\"...\"", not cdhash
```

Without the variable the build stays ad-hoc, exactly as before. Changing mode
needs one `xcodebuild ... clean`, otherwise the embedded extension keeps its old
signature and the build fails with "Embedded binary is not signed with the same
certificate as the parent app".

For runs that must never touch a permission-gated path at all:

```bash
EYESONYOU_SKIP_PROXY_CONFIG_SCAN=1 <launch the app>
```

## Architecture agents should respect

1. **Fail-open** — default allow / direct when rules missing.
2. **No TLS MITM / payload capture** — only metadata + counters.
3. Pure logic lives in `Packages/*` (testable without NetworkExtension).
4. Host UI is `App/EyesOnYou`; system extension is `NetworkExtension/`.
5. **No seeded data.** Traffic comes from live socket attribution only; disk columns stay zero until an IOKit source lands.
6. Telemetry persists to `~/Library/Application Support/EyesOnYou/telemetry.sqlite`; configuration to `policy.json` beside it.

## Where to change what

| Goal | Location |
|---|---|
| Counter math / aggregation | `Packages/EyesOnYouCore` |
| Codex / Cursor / Claude workspace discovery | `Packages/EyesOnYouCore` (`WorkspaceDiscovery`) |
| Process → owning app / project attribution | `Packages/EyesOnYouCore` (`LiveAttribution`, `ProjectResolver`, `ProcessRuntimeInfo`, `AgentProcessCatalog`) |
| Rules / groups / route toggle | `Packages/EyesOnYouRuleEngine` |
| SQLite telemetry / flushing | `Packages/EyesOnYouStorage` (`TelemetryStore`, `TelemetryFlusher`) |
| Persisted routes / rules / groups | `Packages/EyesOnYouProxyCore` (`PolicyPersistence`) |
| CLI commands | `Sources/EyesOnYouCLI` |
| Dashboard / sunburst / search UI | `App/EyesOnYou` |
| Filter / proxy providers | `NetworkExtension` |
| Local enforcement proxy + system-proxy takeover (CLI only) | `Packages/EyesOnYouProxyCore` (`LocalProxyServer`, `SystemProxyController`, `LocalProxyRules`). `App/EyesOnYou/ProxyEnforcementController.swift` is excluded from the app target in `project.yml` — the GUI observes only |

## Do not

- Import LuLu or other GPL code into this tree (breaks MIT compatibility).
- Add interactive `readLine` prompts to the CLI.
- Claim live system-extension capture works without signing + user approval.
