# Xcode 工程从零搭建

本文给出项目落地顺序。Xcode 的菜单名称和模板可能随版本变化，Provider 方法签名与 entitlement 应以当前正式 SDK 为准。

## 1. 建立 Workspace

建议先创建空目录和 Swift packages，再创建 Xcode workspace：

```text
EyesOnYou/
├─ EyesOnYou.xcworkspace
├─ App/
├─ NetworkExtension/
├─ Packages/
│  ├─ EyesOnYouCore/
│  ├─ EyesOnYouRuleEngine/
│  ├─ EyesOnYouStorage/
│  ├─ EyesOnYouIPC/
│  └─ EyesOnYouProxyCore/
├─ Tests/
├─ docs/
└─ Config/
```

不要一开始把所有代码放在 App target。规则、数据库、协议解析和纯模型必须进入独立 package，确保无需 entitlement 就能在 CI 测试。

## 2. 创建 Host App Target

- 平台：macOS；
- 生命周期：SwiftUI App；
- 最低系统：macOS 13；
- Bundle ID：例如 `com.example.EyesOnYou`；
- Hardened Runtime：开启；
- App Group：`$(TeamIdentifierPrefix)com.example.EyesOnYou`；
- System Extension capability：开启；
- Network Extension capability：加入 content filter 和 app proxy 对应值；
- 首个 Developer ID 版本建议先不依赖 App Sandbox；若以后进入 Mac App Store，使用单独构建配置验证 sandbox。

所有 ID 写入 `.xcconfig`，代码中只通过 Info.plist 或生成的 `BuildConstants.swift` 读取。

## 3. 创建 Network Extension System Extension Target

从当前 Xcode 提供的 macOS System Extension/Network Extension 模板开始，而不是从 command-line tool target 改造。

目标产物：

```text
EyesOnYou.app/Contents/Library/SystemExtensions/
└─ com.example.EyesOnYou.NetworkExtension.systemextension
```

System Extension：

- Bundle ID：`com.example.EyesOnYou.NetworkExtension`；
- 与 Host 相同 Team ID；
- 与 Host 相同 App Group；
- Network Extension entitlement 同时含 content filter 和 app proxy；
- `Info.plist` 的 `NEProviderClasses` 映射两个 Provider；
- executable 入口尽早调用 `NEProvider.startSystemExtensionMode()`。

## 4. Development 与 Developer ID entitlement 分开

不要在日常调试中直接使用 Developer ID 后缀 entitlement。维护四个文件：

```text
EyesOnYouApp.Development.entitlements
EyesOnYouApp.DeveloperID.entitlements
EyesOnYouNetworkExtension.Development.entitlements
EyesOnYouNetworkExtension.DeveloperID.entitlements
```

Development/App Store 值：

```text
content-filter-provider
app-proxy-provider
```

Developer ID 直接发行值：

```text
content-filter-provider-systemextension
app-proxy-provider-systemextension
```

用 build configuration 决定 `CODE_SIGN_ENTITLEMENTS`。归档后用 `codesign -d --entitlements :-` 检查最终 App 和 system extension，而不是只看工程文件。

## 5. Provider 启动顺序

System extension `main`：

1. `NEProvider.startSystemExtensionMode()`；
2. 初始化最小 OSLog；
3. 初始化共享 runtime；
4. 启动签名校验 XPC listener；
5. `dispatchMain()`。

Filter `startFilter`：

1. 加载 last-known-good rule snapshot；
2. 打开 telemetry DB；
3. 创建一个 broad outbound filter rule；
4. `apply(settings)`；
5. completion。

Proxy `startProxy`：

1. 加载 route snapshot 和 profile；
2. 构建 included/excluded rules；
3. `setTunnelNetworkSettings`；
4. completion。

任何 start completion 都不能无限等待数据库维护、网络探测或 PAC 下载。

## 6. Host 安装状态机

```text
notInstalled
 -> activationRequested
 -> needsUserApproval
 -> extensionActive
 -> configuringFilter
 -> filterEnabled
 -> providerReachable
```

UI 不能只根据 activation request 成功就显示“正在保护”。最终健康条件至少包括：

- system extension 实际运行版本；
- `NEFilterManager.isEnabled`；
- XPC 可达；
- Provider active rule generation；
- telemetry writer healthy。

## 7. 调试建议

- 使用独立测试用户和测试 Mac/VM；
- 日志按 subsystem/category 过滤；
- 给 Provider main、start、apply settings、first flow、first stats、XPC accept 分别加 first-light 日志；
- 测试期间不要同时安装多个同类 content filter，除非正在做冲突测试；
- 修改 `NEMachServiceName`、Provider class mapping 或 entitlement 后执行完整 deactivate/reinstall；
- 不要把 SIP 关闭当成正常开发流程；仅按 Apple 官方调试指引在隔离机器上临时操作。

## 8. Release 检查命令示意

```bash
codesign --verify --deep --strict --verbose=4 EyesOnYou.app
codesign -d --entitlements :- EyesOnYou.app
codesign -d --entitlements :- \
  EyesOnYou.app/Contents/Library/SystemExtensions/*.systemextension
spctl --assess --type execute --verbose=4 EyesOnYou.app
xcrun stapler validate EyesOnYou.app
```

还要验证 notarization ticket、DMG/PKG、更新包签名和干净系统安装。不同 Xcode 版本对 Developer ID Network Extension 导出处理可能变化，发布脚本必须固定工具链并在升级工具链时重新做全流程验证。
