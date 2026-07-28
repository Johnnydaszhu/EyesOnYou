# EyesOnYou

[English](./README.md) · [简体中文](./README.zh-CN.md)

原生 macOS 网络可观测、按应用防火墙与选择性代理。

<p align="center">
  <img src="docs/screenshots/overview.gif" alt="EyesOnYou 总览面板" width="860" />
</p>

## 功能

- 按应用流量：实时速率、合计与历史
- 按项目下钻：Claude Code / Codex / Cursor / VS Code 的流量按真实项目拆分，取自进程工作目录与编辑器窗口工作区，而非估算；`node` / `npm` 等子进程归并到派生它们的应用
- 数据持久化：流量写入 SQLite 并在启动时恢复，重启后统计与按项目下钻不丢失；路由与规则同样持久化
- 实测出口：每个应用显示它的字节到底是直连出去的还是经过了本机代理客户端，两条路径都有流量时显示占比 —— 全部是观测结果，不是规则
- 实时联网：每个应用显示此刻是否持有已建立的连接
- 按应用控制 HTTP / HTTPS 路由：在排行中可选择跟随系统、强制直连或强制代理。该功能需要在设置中明确开启；
  关闭功能或退出应用时会恢复此前的 macOS 代理设置
- 规则与实测分开：路由规则表示希望如何连接，出口一列仍然只显示实际观测结果
- 隐私优先：仅元数据与计数 — 不抓取载荷、不做 TLS 中间人（浏览器页面标题标注为可选功能，默认关闭）
- 流量提醒：每日 / 累计 / 单应用阈值、突发检测、新应用首次联网提示 —— 阈值可调，每个条件每周期只提醒一次
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

## 数据

界面上的所有数字都来自本机实测 —— 没有任何演示或示例数据。

| 文件（`~/Library/Application Support/EyesOnYou/`） | 内容 |
|---|---|
| `telemetry.sqlite` | 按应用与目标聚合的分钟 / 小时 / 天流量桶 |
| `policy.json` | 路由、规则、分组、代理配置 |
| `favorites.json` | 收藏的应用 |

保留策略：分钟桶 7 天，小时桶 1 年，天桶长期保留。数据不会离开本机。

## 许可

[MIT](./LICENSE)
