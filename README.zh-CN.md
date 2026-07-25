# EyesOnYou

[English](./README.md) · [简体中文](./README.zh-CN.md)

原生 macOS 网络可观测、按应用防火墙与选择性代理。

<p align="center">
  <img src="docs/screenshots/overview.gif" alt="EyesOnYou 总览面板" width="860" />
</p>

## 功能

- 按应用流量：实时速率、合计与历史
- 选择性代理：按应用与分组路由（直连 / 系统代理 / SOCKS5 · HTTP CONNECT）
- 隐私优先：仅元数据与计数 — 不抓取载荷、不做 TLS 中间人
- 面向 Agent 的 JSON CLI（[docs/CLI.md](docs/CLI.md)）

## 下载

从 [GitHub Releases](https://github.com/Johnnydaszhu/EyesOnYou/releases) 安装（`EyesOnYou-<version>.dmg`）。

## 快速开始

```bash
swift test
swift run eyesonyou --json status

brew install xcodegen   # 仅需一次
xcodegen generate
xcodebuild -project EyesOnYou.xcodeproj -scheme EyesOnYou \
  -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
```

更多：[CONTRIBUTING.md](./CONTRIBUTING.md) · [docs/](./docs/) · [README.md](./README.md)

## 许可

[MIT](./LICENSE)
