# AGENTS.md — EyesOnYou for coding agents

This repository is optimized for **Codex**, **Claude Code**, and similar agents.

## Prefer the CLI for data and policy checks

```bash
# From repo root
swift run eyesonyou --json agent-manifest   # discover commands
swift run eyesonyou --json status
swift run eyesonyou --json apps --period week --limit 15
swift run eyesonyou --json workspaces --limit 20
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

## Architecture agents should respect

1. **Fail-open** — default allow / direct when rules missing.
2. **No TLS MITM / payload capture** — only metadata + counters.
3. Pure logic lives in `Packages/*` (testable without NetworkExtension).
4. Host UI is `App/EyesOnYou`; system extension is `NetworkExtension/`.
5. Disk I/O in the UI may be demo-scaled until IOKit path lands; network path is the product core.

## Where to change what

| Goal | Location |
|---|---|
| Counter math / aggregation | `Packages/EyesOnYouCore` |
| Rules / groups / route toggle | `Packages/EyesOnYouRuleEngine` |
| SQLite telemetry | `Packages/EyesOnYouStorage` |
| CLI commands | `Sources/EyesOnYouCLI` |
| Dashboard / sunburst / search UI | `App/EyesOnYou` |
| Filter / proxy providers | `NetworkExtension` |

## Do not

- Import LuLu or other GPL code into this tree (breaks MIT compatibility).
- Add interactive `readLine` prompts to the CLI.
- Claim live system-extension capture works without signing + user approval.
