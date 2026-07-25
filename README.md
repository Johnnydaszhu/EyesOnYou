# EyesOnYou

[English](./README.md) · [简体中文](./README.zh-CN.md)

Native macOS network observability, per-app firewall, and selective proxy.

<p align="center">
  <img src="docs/screenshots/overview.gif" alt="EyesOnYou overview dashboard" width="860" />
</p>

## Features

- Per-app traffic: live rates, totals, and history
- Selective proxy: per-app and group routes (direct / system / SOCKS5 · HTTP CONNECT)
- Privacy first: metadata and counters only — no payload capture, no TLS MITM
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

## License

[MIT](./LICENSE)
