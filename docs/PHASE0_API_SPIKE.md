# Phase 0：NetworkExtension API 校准实验

本阶段只回答“Apple API 在我们支持的真实 macOS 上到底如何工作”。不得在通过本阶段之前投入正式数据库、完整 UI 或代理协议栈。

## 1. 测试环境

至少准备：

- 最低支持 macOS（建议 13.x 的最新补丁）；
- 当前正式版 macOS；
- 下一版 beta 测试机或独立卷；
- Apple Silicon；若计划支持 Intel，再加 Intel；
- 独立测试 App：TCP upload/download、UDP、长连接、connect-by-name、connect-by-IP、helper 代表主 App 建连；
- 受控测试服务器，能够记录应用 payload 字节、socket 字节和连接时间。

每次实验记录：OS build、Xcode build、SDK、硬件、签名方式、entitlement、extension 版本。

## 2. P0-01 System Extension 生命周期

验证：

- activation request；
- 首次用户批准；
- already active；
- replacement；
- 用户推迟替换；
- deactivation；
- 删除 App 后残留状态；
- reboot、logout/login、fast user switching。

通过标准：状态机可重复，App 能准确显示“请求版本”和“实际运行版本”。

## 3. P0-02 Filter Flow Metadata

对每类测试 flow 记录（脱敏）：

- flow UUID；
- sourceAppIdentifier；
- sourceAppUniqueIdentifier/CDHash；
- sourceAppAuditToken；
- sourceProcessAuditToken；
- remote hostname/address/port；
- direction；
- transport；
- URL 是否存在。

重点：系统服务代表 App 建连时两种 token 的差异；App helper 的归属；connect-by-IP 时 hostname 缺失比例。

## 4. P0-03 Statistics Semantics

分别用 `.none/.low/.medium/.high`：

- 记录 report event、时间戳、入站/出站计数；
- 比较计数是累计还是增量；
- 比较 statistics 与 flowClosed 是否重复；
- TCP/UDP、IPv4/IPv6、localhost；
- 1 KB、1 MB、1 GB；
- 长连接；
- sleep/wake；
- 网络切换；
- blocked flow。

通过标准：形成版本化兼容表，并实现自动校准测试。若某 OS 的实时计数不可用，产品能力表必须降级。

## 5. P0-04 Filter Verdict

测试：

- allow；
- drop；
- 默认 allow；
- 规则 snapshot 缺失；
- Provider crash；
- startFilter 失败；
- stop 时活跃 flow。

通过标准：普通模式失败不让整机长期断网；Lockdown 行为单独验证。

## 6. P0-05 Content Filter 冲突

安装另一个 content filter：

- 启用 EyesOnYou 时系统是否禁用对方；
- UI/系统通知；
- 禁用 EyesOnYou 后能否恢复；
- App 是否能检测现状而不是声称双方同时生效。

通过标准：安装前告知，诊断页能解释，卸载后不残留错误配置。

## 7. P0-06 单 System Extension 多 Provider

Info.plist 同时映射 filter-data 和 app-proxy。验证：

- 只启 Filter 时 Proxy Provider 不启动；
- 只启 Proxy；
- 两者同时；
- 任一 Provider 主动 crash 时另一个的行为；
- XPC listener 生命周期；
- 内存差异。

决策门：若故障耦合不可接受，启用 split-extension 构建拓扑。

## 8. P0-07 Transparent Proxy Semantics

验证：

- `handleNewFlow -> false` 是否由 OS 正常直连；
- `true` 后 flow open/copy 生命周期；
- TCP、UDP 回调；
- remote hostname；
- source app metadata；
- `setMetadata(on:)` 对上游连接归因；
- included/excluded rule；
- upstream recursion；
- Filter 是否再次看到代理上游 flow；
- 统计是否双计数。

通过标准：能设计唯一计数来源，并证明不会递归。

## 9. P0-08 System Proxy/PAC

测试：

- HTTP proxy；
- HTTPS proxy；
- SOCKS；
- PAC URL；
- inline PAC；
- bypass list；
- simple hostname；
- network change；
- 本地代理重启。

记录 CFNetwork 和 SystemConfiguration 返回值、执行时间、线程要求、错误行为。

## 10. 输出

Phase 0 PR 必须提交：

- `CompatibilityMatrix.md`；
- 原始测试脚本和受控服务器；
- 可脱敏的 JSON 结果；
- 已知限制；
- 是否保持一个 system extension 包的 ADR；
- stats 算法最终说明；
- proxy/filter 去重方案；
- 性能基线。
