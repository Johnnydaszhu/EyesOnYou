# 主要技术资料

以下资料用于本设计的 API 边界和发布约束。开发时应以当前 Xcode SDK header、Apple 最新文档和实机测试为最终依据。

## Apple 官方

- System Extensions：<https://developer.apple.com/documentation/systemextensions/>
- Network Extensions entitlement：<https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension>
- NEFilterDataProvider `handleNewFlow`：<https://developer.apple.com/documentation/networkextension/nefilterdataprovider/handlenewflow(_:)> 
- NEFilterNewFlowVerdict statisticsReportFrequency：<https://developer.apple.com/documentation/networkextension/nefilternewflowverdict/statisticsreportfrequency>
- NEFilterReport：<https://developer.apple.com/documentation/networkextension/nefilterreport>
- NEFilterFlow sourceProcessAuditToken：<https://developer.apple.com/documentation/networkextension/nefilterflow/sourceprocessaudittoken>
- NEFilterFlow sourceAppAuditToken：<https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappaudittoken>
- NEFilterFlow sourceAppUniqueIdentifier：<https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappuniqueidentifier>
- NEFilterSettings rule limit：<https://developer.apple.com/documentation/networkextension/nefiltersettings/init(rules:defaultaction:)>
- NEFilterManager isEnabled：<https://developer.apple.com/documentation/networkextension/nefiltermanager/isenabled>
- NEFilterManager loadFromPreferences：<https://developer.apple.com/documentation/networkextension/nefiltermanager/loadfrompreferences(completionhandler:)>
- filterSockets：<https://developer.apple.com/documentation/networkextension/nefilterproviderconfiguration/filtersockets>
- Handling Flow Copying：<https://developer.apple.com/documentation/networkextension/handling-flow-copying>
- NETransparentProxyManager：<https://developer.apple.com/documentation/networkextension/netransparentproxymanager>
- NEAppProxyFlow：<https://developer.apple.com/documentation/networkextension/neappproxyflow>
- NEAppProxyProviderManager 限制：<https://developer.apple.com/documentation/networkextension/neappproxyprovidermanager>
- CFNetworkCopySystemProxySettings：<https://developer.apple.com/documentation/cfnetwork/cfnetworkcopysystemproxysettings()>
- SCDynamicStoreCopyProxies：<https://developer.apple.com/documentation/systemconfiguration/scdynamicstorecopyproxies(_:)> 
- CFNetwork PAC API：<https://developer.apple.com/documentation/cfnetwork/cfnetworkexecuteproxyautoconfigurationurl(_:_:_:_:)>
- SecCodeCopyGuestWithAttributes：<https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:)>
- URL Filters：<https://developer.apple.com/documentation/networkextension/url-filters>

## 开源参考

- LuLu：<https://github.com/objective-see/LuLu>，GPL-3.0。可研究 NetworkExtension、规则和安全 XPC 的架构思想；本项目为 MIT，应做干净室实现，不复制 GPL 源码。
- Sniffnet：<https://github.com/GyulyVGC/sniffnet>，Apache-2.0。可参考跨平台流量可视化和用户体验，但本项目核心应保持 macOS 原生 NetworkExtension 架构。

## 文档使用说明

Apple Web 文档偶尔会滞后于当前 SDK header，尤其是新统计字段、可用性和弃用 initializer。任何会影响计量准确性或路由语义的点，都必须通过 `docs/PHASE0_API_SPIKE.md` 实机校准，不能只依据网页描述。
