import Foundation
import SwiftUI
import Combine

// MARK: - Language preference

/// User-facing language choice. `.system` follows macOS preferred languages.
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case english
    case chineseSimplified

    public var id: String { rawValue }

    /// Resolved BCP-47 code used for lookups (`en` / `zh-Hans`).
    public func resolvedCode(systemLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .english:
            return "en"
        case .chineseSimplified:
            return "zh-Hans"
        case .system:
            let first = systemLanguages.first ?? "en"
            if first.hasPrefix("zh") { return "zh-Hans" }
            return "en"
        }
    }

    public var settingsLabelKey: String {
        switch self {
        case .system: return "lang.system"
        case .english: return "lang.english"
        case .chineseSimplified: return "lang.chinese"
        }
    }
}

// MARK: - Store

@MainActor
final class LocalizationStore: ObservableObject {
    static let shared = LocalizationStore()

    private static let preferenceKey = "flowlens.languagePreference"

    /// User preference (System / English / 简体中文).
    @Published var preference: AppLanguage {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.preferenceKey)
            refreshResolved()
        }
    }

    /// Active catalog code after resolving `.system`.
    @Published private(set) var resolvedCode: String = "en"

    /// Bumps when language changes so SwiftUI views refresh.
    @Published private(set) var revision: UInt64 = 0

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.preferenceKey),
           let pref = AppLanguage(rawValue: raw) {
            preference = pref
        } else {
            preference = .system
        }
        refreshResolved()
    }

    func setPreference(_ language: AppLanguage) {
        preference = language
    }

    /// Translate a key; falls back to English then the key itself.
    func t(_ key: String) -> String {
        if let value = Self.tables[resolvedCode]?[key] { return value }
        if let value = Self.tables["en"]?[key] { return value }
        return key
    }

    /// Format helper with one string argument.
    func t(_ key: String, _ arg: CVarArg) -> String {
        String(format: t(key), arg)
    }

    private func refreshResolved() {
        resolvedCode = preference.resolvedCode()
        revision &+= 1
        objectWillChange.send()
    }

    // MARK: - Catalogs

    private static let tables: [String: [String: String]] = [
        "en": en,
        "zh-Hans": zhHans
    ]

    private static let en: [String: String] = [
        // Language
        "lang.system": "System",
        "lang.english": "English",
        "lang.chinese": "简体中文",
        "lang.section": "Language",
        "lang.picker": "App Language",
        "lang.hint": "System follows macOS language settings. Changing language updates the UI immediately.",
        "lang.current": "Current: %@",

        // Tabs
        "tab.overview": "Overview",
        "tab.apps": "Apps",
        "tab.rules": "Rules",
        "tab.proxy": "Proxy",
        "tab.history": "History",

        // Status chips
        "status.filterOn": "Filter On",
        "status.filterOff": "Filter Off",
        "status.proxySelective": "Proxy Selective",
        "status.proxyOff": "Proxy Off",
        "status.running": "Running",
        "status.paused": "Paused",
        "status.stable": "Stable",
        "status.wifi": "Wi-Fi",
        "status.proxyMode.help": "Proxy status",
        "status.proxyMode.proxy": "Proxy",
        "status.proxyMode.configured": "Configured",
        "status.proxyMode.direct": "Direct",
        "status.proxyMode.none": "None",
        "status.path.direct": "Direct",
        "status.path.proxy": "Proxy",
        "status.path.total": "Total",
        "status.path.down": "Down",
        "status.path.up": "Up",

        // Overview
        "overview.totals": "TOTALS",
        "overview.networkTraffic": "Network",
        "overview.diskIO": "Disk I/O",
        "overview.netDown": "Download",
        "overview.netUp": "Upload",
        "overview.diskRead": "Read",
        "overview.diskWrite": "Write",
        "overview.period.hour": "1H",
        "overview.period.today": "Today",
        "overview.period.day": "24H",
        "overview.period.week": "Week",
        "overview.period.month": "This Month",
        "overview.period.last30Days": "Last 30 Days",
        "overview.period.year": "Year",
        "overview.period.custom": "Custom",
        "overview.period.from": "From",
        "overview.period.to": "To",
        "overview.period.range": "%@ – %@",
        "time.global": "Time range",
        "sunburst.apps": "Apps",
        "sunburst.back": "Back",
        "sunburst.root": "All",
        "sunburst.hint": "Hover to highlight · click app to drill into sites / projects",
        "sunburst.centerBack": "Click center to go back",
        "sunburst.trafficMix": "TRAFFIC MIX",
        "sunburst.topShares": "Top shares",
        "sunburst.shareHint": "Top %d",
        "drill.websites": "Websites",
        "drill.projects": "Projects",
        "drill.sessions": "Sessions",
        "drill.destinations": "Destinations",
        "overview.projectsCount": "%d projects",
        "overview.sessionsCount": "%d sessions",
        "overview.destinationsCount": "%d destinations",
        "search.placeholder": "Search apps, sites, rules…",
        "search.empty": "No matches",
        "search.kind.app": "App",
        "search.kind.site": "Site",
        "search.kind.rule": "Rule",
        "search.kind.group": "Group",
        "favorite.pin": "Favorite",
        "favorite.unpin": "Unfavorite",
        "menuBar.togglePanel": "Toggle Menu Bar Panel",
        "overview.liveTraffic": "LIVE TRAFFIC",
        "overview.proxyRouting": "PROXY ROUTING",
        "overview.ranking": "APP RANKING",
        "overview.rankingSearch": "Filter apps…",
        "overview.rankingSearch.help": "Combined search: chrome route:direct · status:block · group:Media · proxy:on · 收藏",
        "ranking.archiveTitle": "ARCHIVED APPS",
        "ranking.archiveEmpty": "No archived apps",
        "ranking.archive": "Archive",
        "ranking.unarchive": "Unarchive",
        "ranking.archive.help": "Show archived apps",
        "ranking.block": "Block",
        "ranking.unblock": "Unblock",
        "ranking.revealFinder": "Reveal in Finder",
        "ranking.delete": "Delete from Ranking",
        "ranking.filterCards": "Filter Overview Cards",
        "ranking.clearFilter": "Clear Filter",
        "ranking.clearFilter.help": "Show totals for all apps again",
        "ranking.drill": "Drill into Destinations",
        "overview.colSpacing": "Column spacing",
        "overview.colSpacing.help": "Spacing between ranking column titles and cells",
        "overview.colSpacing.hint": "Adjusts horizontal gap between app ranking headers and tags (route, status, group…). Saved automatically.",
        "overview.colSpacing.decrease": "Decrease column spacing",
        "overview.colSpacing.increase": "Increase column spacing",
        "overview.colSpacing.reset": "Reset to default",
        "overview.colSpacing.dragHelp": "Drag to adjust spacing between metrics and tags",
        "groups.manage": "Manage Groups",
        "groups.manage.help": "Create, edit, reorder, and delete groups",
        "groups.done": "Done",
        "groups.empty": "No groups yet. Create one below.",
        "groups.namePlaceholder": "Group name",
        "groups.create": "Create",
        "groups.createNew": "New Group…",
        "groups.rename": "Rename",
        "groups.save": "Save",
        "groups.delete": "Delete group",
        "groups.assign": "Assign Group",
        "groups.assign.help": "Move this app to a group",
        "groups.defaultRoute": "Default route for group",
        "overview.share": "Share",
        "overview.pieTitle": "TRAFFIC MIX",
        "overview.pieEmpty": "No traffic in this period",
        "overview.activeRules": "Active Rules",
        "overview.showAllApps": "Show All Apps ›",
        "overview.sitesCount": "%d sites",
        "overview.colApp": "App",
        "overview.colDown": "Down",
        "overview.colUp": "Up",
        "overview.colDiskRead": "Disk Read",
        "overview.colDiskWrite": "Disk Write",
        "overview.colGroup": "Group",
        "overview.colRoute": "Route",
        "overview.colRequests": "Requests",
        "overview.colStatus": "Status",
        "overview.colProxy": "Proxy",
        "overview.ungrouped": "—",
        "overview.allowed": "Allowed",
        "overview.blocked": "Blocked",
        "overview.routeDirect": "Direct",
        "overview.routeSystemProxy": "System Proxy",
        "overview.routeCustomProxy": "Custom Proxy",
        "footer.tagline": "Per-app traffic, blocking & proxy routing",
        "footer.network": "Network: Wi-Fi",

        // Apps
        "apps.title": "Applications",
        "apps.subtitle": "Toggle proxy per app. Browsers expand by website (hostname). Groups share a default route.",
        "apps.colAppSite": "App / Site",
        "apps.colDown": "Down",
        "apps.colUp": "Up",
        "apps.colRoute": "Route",
        "apps.colUseProxy": "Use Proxy",
        "apps.groups": "Groups",
        "apps.appsCount": "· %d apps",
        "apps.browser": "Browser",
        "apps.siteHint": "website · no full URL (no TLS MITM)",
        "apps.websitesCount": "%d websites",

        // Rules
        "rules.title": "Rules",
        "rules.meta": "%d rules · gen %llu",
        "rules.empty": "No rules configured.",
        "rules.anyDestination": "Any destination",

        // Proxy
        "proxy.title": "Proxy",
        "proxy.selective": "Selective Transparent Proxy",
        "proxy.profiles": "Profiles",
        "proxy.enabled": "Enabled",
        "proxy.disabled": "Disabled",
        "proxy.failOpen": "Default-off fail-open: when proxy is disabled, no flow is claimed and the OS handles traffic directly.",

        // History
        "history.title": "History",
        "history.range": "Range",
        "history.hour": "1 Hour",
        "history.day": "24 Hours",
        "history.week": "7 Days",
        "history.month": "30 Days",
        "history.colApp": "App",
        "history.colDown": "Down",
        "history.colUp": "Up",
        "history.colTotal": "Total",
        "history.colFlows": "Flows",

        // Settings
        "settings.title": "Settings",
        "settings.filterEnabled": "Filter enabled",
        "settings.proxyEnabled": "Proxy enabled",
        "settings.alertsEnabled": "Alerts enabled",
        "settings.extensionNote": "System extension signing is required for live capture. Demo data is used when the extension is unavailable.",
        "settings.general": "General",
        "settings.protection": "Protection",
        "settings.protection.hint": "These toggles control filter / proxy / alerts in the host app. Live enforcement still requires a signed system extension.",
        "settings.tab.general": "General",
        "settings.tab.appearance": "Appearance",
        "settings.tab.protection": "Protection",
        "settings.tab.ranking": "Ranking",
        "settings.tab.updates": "Updates",
        "settings.tab.about": "About",
        "settings.about.tagline": "Network observability, firewall rules, and selective proxy for macOS.",
        "settings.about.data": "Data source",
        "appearance.section": "Appearance",
        "appearance.help": "Appearance: Auto, Light, or Dark",
        "appearance.system": "Auto",
        "appearance.light": "Light",
        "appearance.dark": "Dark",
        "appearance.picker": "Theme",
        "appearance.hint": "Auto follows macOS. Light and Dark match the cream / charcoal design refs.",

        // Menu bar
        "menu.liveTraffic": "LIVE TRAFFIC",
        "menu.topApps": "TOP APPS",
        "menu.routes": "ROUTES",
        "menu.protection": "PROTECTION",
        "menu.blocked": "Blocked",
        "menu.blockedToday": "Blocked Today",
        "menu.activeRules": "Active Rules",
        "menu.recentConnections": "RECENT CONNECTIONS",
        "menu.openDashboard": "Open Panel",
        "menu.pauseFiltering": "Pause Filtering",
        "menu.rules": "Rules",
        "menu.quit": "Quit",
        "menu.filter": "Filter",
        "menu.proxy": "Proxy",
        "menu.alerts": "Alerts",
        "menu.direct": "Direct",
        "menu.systemProxy": "System Proxy",
        "menu.socks5": "SOCKS5",
        "menu.menuStyle": "Menu Style",
        "menu.style.section": "Menu Bar",
        "menu.style.hint": "Choose how rates appear in the menu bar.",
        "menu.style.back": "Back",
        "menu.style.dualPath": "Direct / Proxy chart",
        "menu.style.dualPath.detail": "Mini sparkline with direct and proxy rates",
        "menu.style.compactRates": "Compact rates",
        "menu.style.compactRates.detail": "Up / down rates with path share",
        "menu.style.iconOnly": "Icon only",
        "menu.style.iconOnly.detail": "Show only the FlowLens icon",
        "update.available": "Update available",
        "update.version": "Version %@",
        "update.action": "Update",
        "update.action.help": "Download the latest release or open GitHub",
        "update.check.help": "Check GitHub for updates",
        "update.downloading": "Downloading…",
        "update.status.upToDate": "You’re up to date",
        "update.status.noRelease": "No release published yet",
        "update.status.failed": "Update check failed",
        "update.status.downloading": "Downloading update…",
        "update.status.downloaded": "Saved to Downloads",
        "update.section": "Updates",
        "update.checkNow": "Check for Updates",
        "update.openReleases": "Open Releases on GitHub",
        "update.hint": "FlowLens checks GitHub Releases automatically about once a day. You can also check manually from the footer version label.",

        // Route chips (shared)
        "route.direct": "Direct",
        "route.system": "System",
        "route.proxy": "SOCKS5",
        "route.inherit": "Inherit",
        "route.blocked": "Blocked",
    ]

    private static let zhHans: [String: String] = [
        "lang.system": "跟随系统",
        "lang.english": "English",
        "lang.chinese": "简体中文",
        "lang.section": "语言",
        "lang.picker": "应用语言",
        "lang.hint": "选择「跟随系统」时使用 macOS 系统语言。切换后界面立即更新。",
        "lang.current": "当前：%@",

        "tab.overview": "总览",
        "tab.apps": "应用",
        "tab.rules": "规则",
        "tab.proxy": "代理",
        "tab.history": "历史",

        "status.filterOn": "过滤已开",
        "status.filterOff": "过滤已关",
        "status.proxySelective": "选择性代理",
        "status.proxyOff": "代理已关",
        "status.running": "运行中",
        "status.paused": "已暂停",
        "status.stable": "稳定",
        "status.wifi": "Wi-Fi",
        "status.proxyMode.help": "代理状态",
        "status.proxyMode.proxy": "代理",
        "status.proxyMode.configured": "配置",
        "status.proxyMode.direct": "直连",
        "status.proxyMode.none": "无",
        "status.path.direct": "直连",
        "status.path.proxy": "代理",
        "status.path.total": "合计",
        "status.path.down": "下载",
        "status.path.up": "上传",

        "overview.totals": "合计",
        "overview.networkTraffic": "网络流量",
        "overview.diskIO": "磁盘读写",
        "overview.netDown": "下载",
        "overview.netUp": "上传",
        "overview.diskRead": "读取",
        "overview.diskWrite": "写入",
        "overview.period.hour": "1小时",
        "overview.period.today": "今天",
        "overview.period.day": "24小时",
        "overview.period.week": "本周",
        "overview.period.month": "本月",
        "overview.period.last30Days": "近 30 天",
        "overview.period.year": "本年",
        "overview.period.custom": "自定义",
        "overview.period.from": "开始",
        "overview.period.to": "结束",
        "overview.period.range": "%@ – %@",
        "time.global": "时间范围",
        "sunburst.apps": "应用",
        "sunburst.back": "返回",
        "sunburst.root": "全部",
        "sunburst.hint": "悬停高亮 · 点击应用下钻到网站 / 项目 / 会话",
        "sunburst.centerBack": "点击中心返回",
        "sunburst.trafficMix": "流量构成",
        "sunburst.topShares": "份额 Top",
        "sunburst.shareHint": "前 %d 名",
        "drill.websites": "网站",
        "drill.projects": "项目",
        "drill.sessions": "会话",
        "drill.destinations": "目的地",
        "overview.projectsCount": "%d 个项目",
        "overview.sessionsCount": "%d 个会话",
        "overview.destinationsCount": "%d 个目的地",
        "search.placeholder": "搜索应用、网站、规则…",
        "search.empty": "无匹配结果",
        "search.kind.app": "应用",
        "search.kind.site": "网站",
        "search.kind.rule": "规则",
        "search.kind.group": "分组",
        "favorite.pin": "收藏",
        "favorite.unpin": "取消收藏",
        "menuBar.togglePanel": "切换菜单栏面板",
        "overview.liveTraffic": "实时流量",
        "overview.proxyRouting": "代理路由",
        "overview.ranking": "应用排行",
        "overview.rankingSearch": "筛选应用…",
        "overview.rankingSearch.help": "组合搜索：chrome route:直连 · status:屏蔽 · group:媒体 · proxy:on · 收藏",
        "ranking.archiveTitle": "已归档应用",
        "ranking.archiveEmpty": "暂无归档应用",
        "ranking.archive": "归档",
        "ranking.unarchive": "取消归档",
        "ranking.archive.help": "查看已归档应用",
        "ranking.block": "屏蔽",
        "ranking.unblock": "取消屏蔽",
        "ranking.revealFinder": "在 Finder 中显示",
        "ranking.delete": "从排行中删除",
        "ranking.filterCards": "筛选概览卡片",
        "ranking.clearFilter": "清除筛选",
        "ranking.clearFilter.help": "恢复显示全部应用的合计与实时流量",
        "ranking.drill": "下钻目的地",
        "overview.colSpacing": "列间距",
        "overview.colSpacing.help": "应用排行列标题与标签之间的间距",
        "overview.colSpacing.hint": "调整应用排行表头与路由/状态/分组等列之间的水平间距，自动保存。",
        "overview.colSpacing.decrease": "减小列间距",
        "overview.colSpacing.increase": "增大列间距",
        "overview.colSpacing.reset": "恢复默认",
        "overview.colSpacing.dragHelp": "拖拽调整数值列与标签列之间的间距",
        "groups.manage": "管理分组",
        "groups.manage.help": "新建、编辑、排序与删除分组",
        "groups.done": "完成",
        "groups.empty": "暂无分组，可在下方新建",
        "groups.namePlaceholder": "分组名称",
        "groups.create": "新建",
        "groups.createNew": "新建分组…",
        "groups.rename": "重命名",
        "groups.save": "保存",
        "groups.delete": "删除分组",
        "groups.assign": "分配分组",
        "groups.assign.help": "将此应用移到某个分组",
        "groups.defaultRoute": "分组默认路由",
        "overview.share": "占比",
        "overview.pieTitle": "流量构成",
        "overview.pieEmpty": "该时段暂无流量",
        "overview.activeRules": "生效规则",
        "overview.showAllApps": "查看全部应用 ›",
        "overview.sitesCount": "%d 个网站",
        "overview.colApp": "应用",
        "overview.colDown": "下载",
        "overview.colUp": "上传",
        "overview.colDiskRead": "磁盘读",
        "overview.colDiskWrite": "磁盘写",
        "overview.colGroup": "分组",
        "overview.colRoute": "路由",
        "overview.colRequests": "请求数",
        "overview.colStatus": "状态",
        "overview.colProxy": "代理",
        "overview.ungrouped": "—",
        "overview.allowed": "已允许",
        "overview.blocked": "已拦截",
        "overview.routeDirect": "直连",
        "overview.routeSystemProxy": "系统代理",
        "overview.routeCustomProxy": "自定义代理",
        "footer.tagline": "按应用统计流量、拦截与代理路由",
        "footer.network": "网络：Wi-Fi",

        "apps.title": "应用程序",
        "apps.subtitle": "可按应用开关代理。浏览器按网站（主机名）展开。分组共享默认路由。",
        "apps.colAppSite": "应用 / 网站",
        "apps.colDown": "下载",
        "apps.colUp": "上传",
        "apps.colRoute": "路由",
        "apps.colUseProxy": "使用代理",
        "apps.groups": "分组",
        "apps.appsCount": "· %d 个应用",
        "apps.browser": "浏览器",
        "apps.siteHint": "网站 · 无完整 URL（不做 TLS 中间人）",
        "apps.websitesCount": "%d 个网站",

        "rules.title": "规则",
        "rules.meta": "%d 条规则 · 代数 %llu",
        "rules.empty": "尚未配置规则。",
        "rules.anyDestination": "任意目的地",

        "proxy.title": "代理",
        "proxy.selective": "选择性透明代理",
        "proxy.profiles": "配置文件",
        "proxy.enabled": "已启用",
        "proxy.disabled": "已禁用",
        "proxy.failOpen": "默认关闭且故障开放：代理关闭时不接管任何流量，由系统直接处理。",

        "history.title": "历史",
        "history.range": "范围",
        "history.hour": "1 小时",
        "history.day": "24 小时",
        "history.week": "7 天",
        "history.month": "30 天",
        "history.colApp": "应用",
        "history.colDown": "下载",
        "history.colUp": "上传",
        "history.colTotal": "合计",
        "history.colFlows": "连接数",

        "settings.title": "设置",
        "settings.filterEnabled": "启用过滤",
        "settings.proxyEnabled": "启用代理",
        "settings.alertsEnabled": "启用提醒",
        "settings.extensionNote": "实时抓包需要系统扩展签名。未安装扩展时使用演示数据。",
        "settings.general": "通用",
        "settings.protection": "防护",
        "settings.protection.hint": "这些开关控制主应用内的过滤 / 代理 / 提醒。真正生效仍需要已签名的系统扩展。",
        "settings.tab.general": "通用",
        "settings.tab.appearance": "外观",
        "settings.tab.protection": "防护",
        "settings.tab.ranking": "排行",
        "settings.tab.updates": "更新",
        "settings.tab.about": "关于",
        "settings.about.tagline": "面向 macOS 的网络观测、防火墙规则与选择性代理。",
        "settings.about.data": "数据来源",
        "appearance.section": "外观",
        "appearance.help": "外观：自动、白天或黑夜",
        "appearance.system": "自动",
        "appearance.light": "白天",
        "appearance.dark": "黑夜",
        "appearance.picker": "主题",
        "appearance.hint": "自动跟随系统。白天 / 黑夜对应浅奶油与深炭灰设计稿。",

        "menu.liveTraffic": "实时流量",
        "menu.topApps": "热门应用",
        "menu.routes": "路由",
        "menu.protection": "防护",
        "menu.blocked": "已拦截",
        "menu.blockedToday": "今日拦截",
        "menu.activeRules": "生效规则",
        "menu.recentConnections": "最近连接",
        "menu.openDashboard": "打开面板",
        "menu.pauseFiltering": "暂停过滤",
        "menu.rules": "规则",
        "menu.quit": "退出",
        "menu.filter": "过滤",
        "menu.proxy": "代理",
        "menu.alerts": "提醒",
        "menu.direct": "直连",
        "menu.systemProxy": "系统代理",
        "menu.socks5": "SOCKS5",
        "menu.menuStyle": "菜单样式",
        "menu.style.section": "菜单栏",
        "menu.style.hint": "选择菜单栏如何展示网速。",
        "menu.style.back": "返回",
        "menu.style.dualPath": "直连 / 代理迷你图",
        "menu.style.dualPath.detail": "迷你折线 + 直连 / 代理速率",
        "menu.style.compactRates": "紧凑速率",
        "menu.style.compactRates.detail": "上下行速率与路径占比",
        "menu.style.iconOnly": "仅图标",
        "menu.style.iconOnly.detail": "只显示 FlowLens 图标",
        "update.available": "有可用更新",
        "update.version": "版本 %@",
        "update.action": "更新",
        "update.action.help": "下载最新发布包或打开 GitHub",
        "update.check.help": "检查 GitHub 是否有新版本",
        "update.downloading": "下载中…",
        "update.status.upToDate": "已是最新版本",
        "update.status.noRelease": "尚未发布 GitHub Release",
        "update.status.failed": "检查更新失败",
        "update.status.downloading": "正在下载更新…",
        "update.status.downloaded": "已保存到下载文件夹",
        "update.section": "更新",
        "update.checkNow": "检查更新",
        "update.openReleases": "在 GitHub 打开 Releases",
        "update.hint": "FlowLens 大约每天自动检查一次 GitHub Releases。也可点击左下角版本号手动检查。",

        "route.direct": "直连",
        "route.system": "系统",
        "route.proxy": "SOCKS5",
        "route.inherit": "继承",
        "route.blocked": "拦截",
    ]
}

// MARK: - SwiftUI helpers

/// Reads localized string and re-renders when language changes.
struct LText: View {
    @EnvironmentObject private var l10n: LocalizationStore
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(l10n.t(key))
            .id(l10n.revision)
    }
}

extension View {
    /// Inject localization store (idempotent if already present).
    func withLocalization(_ store: LocalizationStore = .shared) -> some View {
        environmentObject(store)
    }
}

extension LocalizationStore {
    func tabTitle(_ tab: AppModel.Tab) -> String {
        switch tab {
        case .overview: return t("tab.overview")
        case .apps: return t("tab.apps")
        case .rules: return t("tab.rules")
        case .proxy: return t("tab.proxy")
        case .history: return t("tab.history")
        }
    }

    func historyRangeTitle(_ range: AppModel.HistoryRange) -> String {
        switch range {
        case .hour: return t("history.hour")
        case .day: return t("history.day")
        case .week: return t("history.week")
        case .month: return t("history.month")
        }
    }

    func overviewPeriodTitle(_ period: AppModel.OverviewPeriod) -> String {
        switch period {
        case .hour: return t("overview.period.hour")
        case .today: return t("overview.period.today")
        case .day: return t("overview.period.day")
        case .week: return t("overview.period.week")
        case .month: return t("overview.period.month")
        case .last30Days: return t("overview.period.last30Days")
        case .year: return t("overview.period.year")
        case .custom: return t("overview.period.custom")
        }
    }

    func overviewRangeCaption(start: Date, end: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: resolvedCode == "zh-Hans" ? "zh_CN" : "en_US_POSIX")
        let span = end.timeIntervalSince(start)
        if span <= 48 * 3600 {
            df.dateFormat = resolvedCode == "zh-Hans" ? "M月d日 HH:mm" : "MMM d HH:mm"
        } else {
            df.dateFormat = resolvedCode == "zh-Hans" ? "yyyy年M月d日" : "MMM d, yyyy"
        }
        return String(format: t("overview.period.range"), df.string(from: start), df.string(from: end))
    }

    func routeChip(_ label: String) -> String {
        switch label.lowercased() {
        case "direct": return t("route.direct")
        case "system", "system proxy": return t("route.system")
        case "socks5", "proxy", "custom proxy": return t("route.proxy")
        case "inherit": return t("route.inherit")
        case "blocked": return t("route.blocked")
        default: return label
        }
    }
}
