# Filter / Transparent Proxy 双计数与关联策略

## 权威计量源

默认使用 Content Filter 的原始来源 flow 统计作为 App 上传/下载的唯一权威数据。Transparent Proxy 的 relay 字节只用于诊断和一致性校验。

## 为什么会双计数

选择性代理接管一条来源 flow 后，会创建新的上游连接。根据系统版本、Provider metadata 和回调顺序，Filter 可能看到：

1. 来源 App 的原始 flow；
2. system extension 创建的上游 flow；
3. 本地代理进程进一步创建的出口 flow。

若都归到来源 App，会重复累计；若都归到各自进程，用户又可能误解链路。

## 分类

每条 Filter flow 先分类为：

- `userOrigin`：来源 App 原始 flow，计入 App 总量；
- `ownProxyUpstream`：EyesOnYou 自己的上游 socket，不计入用户总量，只记诊断；
- `thirdPartyProxyIngress`：用户 App 到本地代理的连接，计入来源 App，同时标记代理证据；
- `thirdPartyProxyEgress`：本地代理到互联网的出口，归代理 App；Overview 提供“按来源需求”和“按实际进程”两种视图；
- `unknownSystemMediated`：系统代表 App 建连，按 source app 归属并保存 creating process。

## 自有上游识别

组合使用：

- source signing identifier 等于 EyesOnYou system extension；
- `NEAppProxyFlow.setMetadata(on:)` 传播的来源/内部标记；
- 上游 proxy profile endpoint；
- Provider 内部活跃 session 表；
- 单调时钟窗口。

任何单一条件都不够。不能只按 PID、端口或 loopback 判断。

## 不变量

- 同一逻辑来源 flow 在 `traffic_buckets` 只能有一个 accounting source；
- route event 可以有多条，但字节汇总必须守恒；
- 诊断 relay bytes 与用户统计分表/分字段；
- OS 兼容矩阵决定 accounting source，运行中不得为同一 flow 来回切换。

## 校准测试

对 1 MiB、100 MiB、长连接和双向传输，分别测 direct、EyesOnYou HTTP CONNECT、EyesOnYou SOCKS5、第三方本地代理、VPN。受控服务器 payload 计数与 EyesOnYou 统计的差异要记录协议开销口径。
