# ADR-0001：一个 System Extension 包承载两个 Provider

## 状态

提议；Phase 0 后确认。

## 决策

默认发行包使用一个 `.systemextension`，在 `NEProviderClasses` 中映射：

- `com.apple.networkextension.filter-data` → `FlowFilterDataProvider`
- `com.apple.networkextension.app-proxy` → `FlowTransparentProxyProvider`

代码模块不互相依赖，共享只读规则、身份缓存、遥测和 XPC 基础设施。Proxy 配置默认关闭。

## 原因

减少系统扩展安装对象、签名对象、磁盘体积和常驻进程；代理未启用时不产生 flow-copy 数据面。

## 风险

Provider 可能共享进程故障域；代理 bug 可能影响 Filter。Phase 0 必须注入 crash 评估。如果不可接受，构建系统支持拆分为两个 system extension 包。
