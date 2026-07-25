import Foundation
import Combine
import SwiftUI
import AppKit
import FlowLensCore
import FlowLensRuleEngine
import FlowLensIPC
import FlowLensProxyCore

@MainActor
final class AppModel: ObservableObject {
    /// Tab identity keys (display names come from LocalizationStore).
    enum Tab: String, CaseIterable, Identifiable {
        case overview
        case apps
        case rules
        case proxy
        case history
        var id: String { rawValue }
    }

    /// Global proxy posture shown in the dashboard header.
    /// - proxy: custom / selective proxy is active
    /// - configured: profiles exist (or system proxy) but not actively proxying via custom path
    /// - direct: traffic is direct
    /// - none: no proxy configuration and proxy subsystem off
    enum GlobalProxyStatus: String, Equatable {
        case proxy
        case configured
        case direct
        case none

        var localizationKey: String { "status.proxyMode.\(rawValue)" }

        var systemImage: String {
            switch self {
            case .proxy: return "arrow.triangle.branch"
            case .configured: return "gearshape.2"
            case .direct: return "arrow.left.arrow.right"
            case .none: return "slash.circle"
            }
        }
    }

    @Published var selectedTab: Tab = .overview
    @Published var filterEnabled: Bool = true
    @Published var proxyEnabled: Bool = true
    @Published var alertsEnabled: Bool = true
    @Published var isRunning: Bool = true

    @Published var rateDownBps: Double = 0
    @Published var rateUpBps: Double = 0
    /// Live rates split by path (direct vs any proxy). iStat-style header/menu bar.
    @Published var directDownBps: Double = 0
    @Published var directUpBps: Double = 0
    @Published var proxyDownBps: Double = 0
    @Published var proxyUpBps: Double = 0
    /// Share of total bandwidth on each path (0...1), sums to ~1 when traffic exists.
    @Published var directShare: Double = 1
    @Published var proxyShare: Double = 0
    @Published var topApps: [AppTrafficSnapshot] = []
    @Published var liveConnections: [LiveConnection] = []
    /// Unified ranking rows for Overview bento (traffic + disk + group + status).
    @Published var rankingRows: [AppRankingRow] = []
    /// DaisyDisk-style sunburst root (apps → optional sites).
    @Published var sunburstRoot: SunburstNode = .empty
    /// Shared hover id between sunburst and ranking table (`AppRankingRow.id` / node.id).
    @Published var hoverNodeID: String? = nil
    /// Ranking-row hover that temporarily filters the pie to that app's destinations.
    /// Separate from `hoverNodeID` so pie pointer moves don't cancel the preview.
    @Published var rankingHoverFilterID: String? = nil
    /// Drill-down path of node ids; empty = top-level apps.
    @Published var sunburstPath: [String] = []
    @Published var routeMix: RouteMix = RouteMix()
    @Published var blockedToday: UInt64 = 0
    @Published var allowedConnections: UInt64 = 0
    @Published var sparklineDown: [Double] = []
    @Published var sparklineUp: [Double] = []
    /// Path total (down+up) history for compact dual sparkline.
    @Published var sparklineDirect: [Double] = []
    @Published var sparklineProxy: [Double] = []
    /// Route-mix share history (percent 0...100) for proxy routing area chart.
    @Published var sparklineRouteDirect: [Double] = []
    @Published var sparklineRouteSystem: [Double] = []
    @Published var sparklineRouteCustom: [Double] = []
    /// Period trend series for totals card mini charts (upload / download).
    @Published var periodTrendDown: [Double] = []
    @Published var periodTrendUp: [Double] = []

    /// Selected ranking app; nil = all apps. Filters totals / live / proxy cards with time range.
    @Published var selectedApp: AppIdentityKey? = nil
    /// Show archived apps panel (from ranking search-bar archive icon).
    @Published var isArchivePanelPresented: Bool = false

    /// Overview totals time range (presets + custom).
    @Published var overviewPeriod: OverviewPeriod = .week {
        didSet { refreshPublishedState() }
    }
    /// Inclusive start for `.custom` (wall clock).
    @Published var customRangeStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() {
        didSet {
            if overviewPeriod == .custom { refreshPublishedState() }
        }
    }
    /// Inclusive end for `.custom`.
    @Published var customRangeEnd: Date = Date() {
        didSet {
            if overviewPeriod == .custom { refreshPublishedState() }
        }
    }
    /// Resolved range used by totals / ranking (for UI caption).
    @Published private(set) var periodRangeStart: Date = Date()
    @Published private(set) var periodRangeEnd: Date = Date()
    /// Network totals for the selected overview period.
    @Published var periodNetworkUp: UInt64 = 0
    @Published var periodNetworkDown: UInt64 = 0
    /// Disk I/O totals for the selected overview period (demo facade until IOKit path).
    @Published var periodDiskRead: UInt64 = 0
    @Published var periodDiskWrite: UInt64 = 0

    @Published var rules: [NetworkPolicyRule] = []
    @Published var groups: [AppGroup] = []
    @Published var proxyProfiles: [ProxyProfile] = []
    @Published var historyRange: HistoryRange = .day
    @Published var historyRows: [AppTrafficSnapshot] = []

    // MARK: Favorites, archive, block & global search

    /// Favorited app storage keys (`AppIdentityKey.storageKey`); pinned to ranking top.
    @Published private(set) var favoriteKeys: Set<String> = []
    /// Archived apps — hidden from main ranking (viewable via archive panel).
    @Published private(set) var archivedKeys: Set<String> = []
    /// Explicitly blocked apps (firewall) — still visible in ranking unless also archived.
    @Published private(set) var blockedKeys: Set<String> = []
    /// Snapshot of archived ranking rows for the archive panel (includes zero-traffic).
    @Published private(set) var archivedRankingRows: [AppRankingRow] = []

    @Published var searchQuery: String = "" {
        didSet { recomputeSearchResults() }
    }
    @Published var isSearchPresented: Bool = false
    @Published private(set) var searchResults: [SearchHit] = []
    /// Ranking filter query (supports combined tokens; see `RankingQuery`).
    @Published var rankingFilterQuery: String = ""

    let aggregator = TelemetryAggregator()
    let policyStore = PolicyStore()
    private var tickTimer: Timer?
    private var demoClock: TimeInterval = 0
    private let demoMode: Bool
    /// Rolling live rate (down+up) history keyed by `AppIdentityKey.storageKey`.
    private var appRateHistory: [String: [Double]] = [:]
    private static let appRateHistoryLimit = 28
    private static let favoritesDefaultsKey = "flowlens.favoriteAppKeys"
    private static let archivedDefaultsKey = "flowlens.archivedAppKeys"
    private static let blockedDefaultsKey = "flowlens.blockedAppKeys"
    /// How many apps to materialize into the ranking table.
    private static let rankingLimit = 64

    /// History range identity (titles come from LocalizationStore).
    enum HistoryRange: String, CaseIterable, Identifiable {
        case hour
        case day
        case week
        case month
        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .hour: return 3600
            case .day: return 86_400
            case .week: return 604_800
            case .month: return 2_592_000
            }
        }
    }

    /// Overview totals time range presets + custom interval.
    enum OverviewPeriod: String, CaseIterable, Identifiable {
        case hour
        case today
        case day
        case week
        case month
        /// Rolling last 30 days (distinct from calendar month).
        case last30Days
        case year
        case custom
        var id: String { rawValue }

        /// Relative lookback for non-calendar presets (`.today` / `.custom` / calendar ranges ignore this).
        var interval: TimeInterval {
            switch self {
            case .hour: return 3_600
            case .today: return 86_400 // upper bound; real start is startOfDay
            case .day: return 86_400
            case .week: return 604_800
            case .month: return 2_592_000
            case .last30Days: return 2_592_000
            case .year: return 31_536_000
            case .custom: return 604_800
            }
        }

        /// Scale factor for demo disk I/O relative to a week baseline.
        var diskScale: Double {
            switch self {
            case .hour: return 1.0 / 168.0
            case .today, .day: return 1.0 / 7.0
            case .week: return 1
            case .month, .last30Days: return 4.3
            case .year: return 52
            case .custom: return 1
            }
        }

        /// Demo network multiplier vs live 24h window.
        var networkScale: UInt64 {
            switch self {
            case .hour: return 1
            case .today, .day: return 1
            case .week: return 1
            case .month, .last30Days: return 4
            case .year: return 48
            case .custom: return 1
            }
        }

        static var presets: [OverviewPeriod] {
            [.hour, .today, .day, .week, .month, .last30Days, .year, .custom]
        }

        /// Compact picker for menu bar popover: 今天 / 本周 / 本月 / 近 30 天.
        static var menuQuickPeriods: [OverviewPeriod] {
            [.today, .week, .month, .last30Days]
        }
    }

    /// Menu bar status item density / layout (settings + popover quick cycle).
    enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
        case dualPath
        case compactRates
        case iconOnly
        var id: String { rawValue }
        var localizationKey: String { "menu.style.\(rawValue)" }
    }

    /// Window / UI appearance: follow system, force light, or force dark.
    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark
        var id: String { rawValue }
        var localizationKey: String { "appearance.\(rawValue)" }

        var systemImage: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
            }
        }

        /// `nil` = follow macOS appearance.
        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    private static let menuBarStyleKey = "flowlens.menuBarDisplayStyle"
    private static let rankingColumnSpacingKey = "flowlens.rankingColumnSpacing"
    private static let rankingHiddenColumnsKey = "flowlens.rankingHiddenColumns"
    private static let appearanceModeKey = "flowlens.appearanceMode"
    private static let colorThemeTemplateKey = "flowlens.colorThemeTemplate"
    private static let themeAccentsKey = "flowlens.themeAccents"

    /// Optional ranking table columns the user can hide via header context menu.
    enum RankingColumnID: String, CaseIterable, Identifiable, Sendable {
        case down
        case up
        case diskRead
        case diskWrite
        case trend
        case lastSeen
        case requests
        case route
        case status
        case group
        case proxy

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .down: return "overview.colDown"
            case .up: return "overview.colUp"
            case .diskRead: return "overview.colDiskRead"
            case .diskWrite: return "overview.colDiskWrite"
            case .trend: return "overview.colTrend"
            case .lastSeen: return "overview.colLastSeen"
            case .requests: return "overview.colRequests"
            case .route: return "overview.colRoute"
            case .status: return "overview.colStatus"
            case .group: return "overview.colGroup"
            case .proxy: return "overview.colProxy"
            }
        }
    }

    @Published var menuBarDisplayStyle: MenuBarDisplayStyle = .dualPath {
        didSet {
            UserDefaults.standard.set(menuBarDisplayStyle.rawValue, forKey: Self.menuBarStyleKey)
        }
    }

    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
            Self.applyAppearance(appearanceMode)
        }
    }

    /// Color template: forest / ocean / ember / violet / mono / custom.
    @Published private(set) var colorThemeTemplate: ColorThemeTemplate = .forest

    /// Adjustable accent tokens (persisted). For `.mono`, non-proxy accents are forced to grayscale on apply.
    @Published private(set) var themeAccents: ThemeAccentSet = .forest

    /// Bumped when colors change so SwiftUI roots can `.id` refresh.
    @Published private(set) var themeRevision: Int = 0

    private var isLoadingColorTheme = false

    /// Horizontal spacing between ranking table columns / header labels (points).
    /// User-adjustable and persisted; clamped to ``rankingColumnSpacingRange``.
    @Published var rankingColumnSpacing: Double = 4 {
        didSet {
            let clamped = Self.clampRankingColumnSpacing(rankingColumnSpacing)
            if clamped != rankingColumnSpacing {
                rankingColumnSpacing = clamped
                return
            }
            UserDefaults.standard.set(rankingColumnSpacing, forKey: Self.rankingColumnSpacingKey)
        }
    }

    /// Hidden optional ranking columns (`RankingColumnID.rawValue`); persisted.
    @Published private(set) var hiddenRankingColumns: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(hiddenRankingColumns).sorted(), forKey: Self.rankingHiddenColumnsKey)
        }
    }

    static let rankingColumnSpacingRange: ClosedRange<Double> = 2...24
    static let rankingColumnSpacingDefault: Double = 4

    static func clampRankingColumnSpacing(_ value: Double) -> Double {
        min(rankingColumnSpacingRange.upperBound, max(rankingColumnSpacingRange.lowerBound, value.rounded()))
    }

    func isRankingColumnVisible(_ column: RankingColumnID) -> Bool {
        !hiddenRankingColumns.contains(column.rawValue)
    }

    func setRankingColumnHidden(_ column: RankingColumnID, hidden: Bool) {
        var next = hiddenRankingColumns
        if hidden {
            next.insert(column.rawValue)
        } else {
            next.remove(column.rawValue)
        }
        if next != hiddenRankingColumns {
            hiddenRankingColumns = next
        }
    }

    func toggleRankingColumnHidden(_ column: RankingColumnID) {
        setRankingColumnHidden(column, hidden: isRankingColumnVisible(column))
    }

    func resetRankingColumns() {
        if !hiddenRankingColumns.isEmpty {
            hiddenRankingColumns = []
        }
    }

    var hasHiddenRankingColumns: Bool {
        !hiddenRankingColumns.isEmpty
    }

    /// Soft update banner on the main window (nil / false → show nothing in the top bar).
    @Published var appUpdateAvailable: Bool = false
    @Published var appUpdateVersion: String? = nil
    @Published var appUpdateHTMLURL: URL? = nil
    @Published var appUpdateAssetURL: URL? = nil
    @Published var appUpdateAssetName: String? = nil
    @Published var appVersion: String = AppUpdateService.currentAppVersion()
    @Published var isCheckingForUpdates: Bool = false
    @Published var isDownloadingUpdate: Bool = false
    @Published var updateCheckMessage: String? = nil
    private var lastUpdateCheckAt: Date? = nil
    /// Debounce for accidental duplicate auto checks in the same session.
    private static let updateCheckDebounce: TimeInterval = 60
    private static let lastUpdateCheckKey = "flowlens.lastUpdateCheckAt"

    /// Absolute `[start, end)` for the active overview period.
    func overviewDateRange(now: Date = Date()) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        switch overviewPeriod {
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, now)
        case .week:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                return (interval.start, now)
            }
            return (now.addingTimeInterval(-604_800), now)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: comps) ?? calendar.startOfDay(for: now)
            return (start, now)
        case .last30Days:
            return (now.addingTimeInterval(-2_592_000), now)
        case .custom:
            let a = min(customRangeStart, customRangeEnd)
            let b = max(customRangeStart, customRangeEnd)
            // End of selected end-day so the full day is included.
            let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: b)) ?? b
            return (calendar.startOfDay(for: a), min(endExclusive, now.addingTimeInterval(1)))
        default:
            return (now.addingTimeInterval(-overviewPeriod.interval), now)
        }
    }

    func cycleMenuBarDisplayStyle() {
        let all = MenuBarDisplayStyle.allCases
        guard let idx = all.firstIndex(of: menuBarDisplayStyle) else {
            menuBarDisplayStyle = .dualPath
            return
        }
        menuBarDisplayStyle = all[(idx + 1) % all.count]
    }

    /// One row in the fused Overview ranking table.
    struct AppRankingRow: Identifiable, Equatable {
        /// Unique row id (app storage key at root; `app|dest` when drilled).
        let id: String
        let snapshot: AppTrafficSnapshot
        let diskRead: UInt64
        let diskWrite: UInt64
        let groupName: String?
        /// Share of network total (0...1) for pie chart.
        let share: Double
        /// Last wall-clock time this app recorded traffic.
        let lastTrafficAt: Date?
        /// Mini area-chart series (combined up+down rates or period bytes).
        let rateSeries: [Double]

        init(
            id: String? = nil,
            snapshot: AppTrafficSnapshot,
            diskRead: UInt64,
            diskWrite: UInt64,
            groupName: String?,
            share: Double,
            lastTrafficAt: Date? = nil,
            rateSeries: [Double] = []
        ) {
            self.id = id ?? snapshot.id
            self.snapshot = snapshot
            self.diskRead = diskRead
            self.diskWrite = diskWrite
            self.groupName = groupName
            self.share = share
            self.lastTrafficAt = lastTrafficAt
            self.rateSeries = rateSeries
        }
    }

    /// Hierarchical node for DaisyDisk-style sunburst.
    struct SunburstNode: Identifiable, Equatable {
        let id: String
        let title: String
        let value: UInt64
        /// Stable hue seed 0..<1
        let hue: Double
        var children: [SunburstNode]

        static let empty = SunburstNode(id: "root", title: "Root", value: 0, hue: 0.55, children: [])

        var hasChildren: Bool { !children.isEmpty }

        func node(path: [String]) -> SunburstNode {
            var current = self
            for step in path {
                guard let next = current.children.first(where: { $0.id == step }) else { break }
                current = next
            }
            return current
        }
    }

    func setHoverNode(_ id: String?) {
        if hoverNodeID != id { hoverNodeID = id }
    }

    func setRankingHoverFilter(_ id: String?) {
        if rankingHoverFilterID != id { rankingHoverFilterID = id }
    }

    func drillInto(nodeID: String) {
        // Only drill if that node exists under current view and has children.
        let current = sunburstRoot.node(path: sunburstPath)
        guard let child = current.children.first(where: { $0.id == nodeID }), child.hasChildren else {
            return
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            sunburstPath.append(nodeID)
            hoverNodeID = nil
            rankingHoverFilterID = nil
        }
    }

    func sunburstGoBack() {
        guard !sunburstPath.isEmpty else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            _ = sunburstPath.popLast()
            hoverNodeID = nil
            rankingHoverFilterID = nil
        }
    }

    func sunburstReset() {
        guard !sunburstPath.isEmpty else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            sunburstPath.removeAll()
            hoverNodeID = nil
            rankingHoverFilterID = nil
        }
    }

    init(demoMode: Bool = true) {
        self.demoMode = demoMode
        if let raw = UserDefaults.standard.string(forKey: Self.menuBarStyleKey),
           let style = MenuBarDisplayStyle(rawValue: raw) {
            menuBarDisplayStyle = style
        }
        if UserDefaults.standard.object(forKey: Self.rankingColumnSpacingKey) != nil {
            rankingColumnSpacing = Self.clampRankingColumnSpacing(
                UserDefaults.standard.double(forKey: Self.rankingColumnSpacingKey)
            )
        } else {
            rankingColumnSpacing = Self.rankingColumnSpacingDefault
        }
        if let arr = UserDefaults.standard.array(forKey: Self.rankingHiddenColumnsKey) as? [String] {
            let valid = Set(RankingColumnID.allCases.map(\.rawValue))
            hiddenRankingColumns = Set(arr.filter { valid.contains($0) })
        }
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceModeKey),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        Self.applyAppearance(appearanceMode)
        loadColorThemePreferences()
        applyColorTheme()
        loadFavorites()
        loadArchivedAndBlocked()
        seedPolicies()
        if demoMode {
            seedDemoTraffic()
        }
        refreshPublishedState()
        startTicker()
        scheduleInitialUpdateCheck()
    }

    // MARK: - App updates (GitHub Releases)

    private func scheduleInitialUpdateCheck() {
        if let ts = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? TimeInterval {
            lastUpdateCheckAt = Date(timeIntervalSince1970: ts)
        }
        // Defer network until after first UI paint.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            self.checkForUpdates(manual: false)
        }
    }

    /// Check GitHub for a newer release. Manual checks always hit the network.
    func checkForUpdates(manual: Bool) {
        if isCheckingForUpdates || isDownloadingUpdate { return }
        if !manual, let last = lastUpdateCheckAt,
           Date().timeIntervalSince(last) < Self.updateCheckDebounce {
            return
        }

        isCheckingForUpdates = true
        if manual {
            updateCheckMessage = nil
        }

        let local = appVersion
        AppUpdateService.fetchLatestRelease { result in
            self.isCheckingForUpdates = false
            self.lastUpdateCheckAt = Date()
            UserDefaults.standard.set(
                Date().timeIntervalSince1970,
                forKey: Self.lastUpdateCheckKey
            )

            switch result {
            case .success(let release):
                let newer = AppUpdateService.isNewer(release.version, than: local)
                self.appUpdateAvailable = newer
                self.appUpdateVersion = release.version
                self.appUpdateHTMLURL = release.htmlURL
                self.appUpdateAssetURL = release.assetURL
                self.appUpdateAssetName = release.assetName
                if manual {
                    self.updateCheckMessage = newer ? nil : "upToDate"
                }
            case .failure(let error):
                if manual {
                    if let check = error as? AppUpdateService.CheckError, check == .noRelease {
                        self.appUpdateAvailable = false
                        self.updateCheckMessage = "noRelease"
                    } else {
                        self.updateCheckMessage = "failed"
                    }
                }
            }
        }
    }

    /// Download release asset when present; otherwise open the GitHub release page.
    func installOrOpenUpdate() {
        if isDownloadingUpdate { return }
        if let asset = appUpdateAssetURL {
            isDownloadingUpdate = true
            updateCheckMessage = "downloading"
            AppUpdateService.downloadAsset(
                from: asset,
                suggestedName: appUpdateAssetName
            ) { result in
                self.isDownloadingUpdate = false
                switch result {
                case .success(let fileURL):
                    self.updateCheckMessage = "downloaded"
                    AppUpdateService.revealInFinder(fileURL)
                    AppUpdateService.openURL(fileURL)
                case .failure:
                    self.updateCheckMessage = "failed"
                    if let page = self.appUpdateHTMLURL {
                        AppUpdateService.openURL(page)
                    } else {
                        AppUpdateService.openURL(AppUpdateService.releasesPageURL)
                    }
                }
            }
            return
        }
        if let page = appUpdateHTMLURL {
            AppUpdateService.openURL(page)
        } else {
            AppUpdateService.openURL(AppUpdateService.releasesPageURL)
        }
    }

    func openReleasesPage() {
        if let page = appUpdateHTMLURL {
            AppUpdateService.openURL(page)
        } else {
            AppUpdateService.openURL(AppUpdateService.releasesPageURL)
        }
    }

    /// Push appearance to AppKit so NSVisualEffectView / window chrome match SwiftUI.
    static func applyAppearance(_ mode: AppearanceMode) {
        NSApp.appearance = mode.nsAppearance
        for window in NSApp.windows {
            window.appearance = mode.nsAppearance
        }
        MenuBarController.shared.refreshPopoverAppearance()
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
    }

    func setColorThemeTemplate(_ template: ColorThemeTemplate) {
        var nextAccents = themeAccents
        if template != .custom && template != .mono {
            nextAccents = ThemeAccentSet.defaults(for: template)
        } else if template == .mono {
            var mono = ThemeAccentSet.mono
            mono.proxy = themeAccents.proxy
            nextAccents = mono
        }
        colorThemeTemplate = template
        themeAccents = nextAccents
        persistColorTheme()
        applyColorTheme()
    }

    /// Update a single accent; switches template to `.custom` when leaving a preset (except mono proxy tweaks).
    func updateThemeAccent(_ keyPath: WritableKeyPath<ThemeAccentSet, ThemeRGB>, to rgb: ThemeRGB) {
        var next = themeAccents
        next[keyPath: keyPath] = rgb
        commitThemeAccents(next, allowNonProxyInMono: keyPath == \ThemeAccentSet.proxy)
    }

    /// Primary accent also nudges the darker brand token for consistent surfaces.
    func updatePrimaryAccent(_ rgb: ThemeRGB) {
        var next = themeAccents
        next.accent = rgb
        next.brand = ThemeRGB(
            r: max(0, rgb.r * 0.85),
            g: max(0, rgb.g * 0.85),
            b: max(0, rgb.b * 0.85)
        )
        commitThemeAccents(next, allowNonProxyInMono: false)
    }

    private func commitThemeAccents(_ next: ThemeAccentSet, allowNonProxyInMono: Bool) {
        if colorThemeTemplate == .mono {
            guard allowNonProxyInMono else { return }
            var locked = ThemeAccentSet.mono
            locked.proxy = next.proxy
            themeAccents = locked
            persistColorTheme()
            applyColorTheme()
            return
        }
        if colorThemeTemplate != .custom {
            colorThemeTemplate = .custom
        }
        themeAccents = next
        persistColorTheme()
        applyColorTheme()
    }

    func resetThemeAccentsToTemplate() {
        if colorThemeTemplate == .custom {
            setColorThemeTemplate(.forest)
            return
        }
        setColorThemeTemplate(colorThemeTemplate)
    }

    private func loadColorThemePreferences() {
        isLoadingColorTheme = true
        var template = ColorThemeTemplate.forest
        var accents = ThemeAccentSet.forest
        if let raw = UserDefaults.standard.string(forKey: Self.colorThemeTemplateKey),
           let loaded = ColorThemeTemplate(rawValue: raw) {
            template = loaded
        }
        if let data = UserDefaults.standard.data(forKey: Self.themeAccentsKey),
           let decoded = try? JSONDecoder().decode(ThemeAccentSet.self, from: data) {
            accents = decoded
        } else {
            accents = ThemeAccentSet.defaults(for: template == .custom ? .forest : template)
        }
        colorThemeTemplate = template
        themeAccents = accents
        isLoadingColorTheme = false
    }

    private func persistColorTheme() {
        guard !isLoadingColorTheme else { return }
        UserDefaults.standard.set(colorThemeTemplate.rawValue, forKey: Self.colorThemeTemplateKey)
        if let data = try? JSONEncoder().encode(themeAccents) {
            UserDefaults.standard.set(data, forKey: Self.themeAccentsKey)
        }
    }

    private func applyColorTheme() {
        ThemeStore.apply(template: colorThemeTemplate, accents: themeAccents)
        themeRevision = ThemeStore.revision
    }

    func resetRankingColumnSpacing() {
        rankingColumnSpacing = Self.rankingColumnSpacingDefault
    }

    func nudgeRankingColumnSpacing(_ delta: Double) {
        rankingColumnSpacing = Self.clampRankingColumnSpacing(rankingColumnSpacing + delta)
    }

    // MARK: - Favorites

    func isFavorite(_ app: AppIdentityKey) -> Bool {
        favoriteKeys.contains(app.storageKey)
    }

    func toggleFavorite(_ app: AppIdentityKey) {
        let key = app.storageKey
        if favoriteKeys.contains(key) {
            favoriteKeys.remove(key)
        } else {
            favoriteKeys.insert(key)
        }
        persistFavorites()
        // Re-sort ranking / top lists without full reseed.
        applyFavoriteOrdering()
        recomputeSearchResults()
    }

    private func loadFavorites() {
        if let arr = UserDefaults.standard.array(forKey: Self.favoritesDefaultsKey) as? [String] {
            favoriteKeys = Set(arr)
        }
    }

    private func persistFavorites() {
        UserDefaults.standard.set(Array(favoriteKeys).sorted(), forKey: Self.favoritesDefaultsKey)
    }

    private func applyFavoriteOrdering() {
        rankingRows = Self.sortByFavorites(rankingRows, favorites: favoriteKeys)
        topApps = rankingRows.map(\.snapshot)
        historyRows = Self.sortSnapshotsByFavorites(historyRows, favorites: favoriteKeys)
        sunburstRoot = Self.buildSunburst(from: rankingRows)
    }

    /// Ranking order: favorites first, then period total bytes, then live rate, then name.
    private static func sortByFavorites(_ rows: [AppRankingRow], favorites: Set<String>) -> [AppRankingRow] {
        rows.sorted { a, b in
            let af = favorites.contains(a.snapshot.app.storageKey)
            let bf = favorites.contains(b.snapshot.app.storageKey)
            if af != bf { return af && !bf }
            let at = a.snapshot.totals.totalBytes
            let bt = b.snapshot.totals.totalBytes
            if at != bt { return at > bt }
            let ar = a.snapshot.rateDownBps + a.snapshot.rateUpBps
            let br = b.snapshot.rateDownBps + b.snapshot.rateUpBps
            if abs(ar - br) > 1 { return ar > br }
            let ac = a.snapshot.totals.flowsOpened
            let bc = b.snapshot.totals.flowsOpened
            if ac != bc { return ac > bc }
            return a.snapshot.displayName.localizedCaseInsensitiveCompare(b.snapshot.displayName) == .orderedAscending
        }
    }

    // MARK: - Block / archive

    func isArchived(_ app: AppIdentityKey) -> Bool {
        archivedKeys.contains(app.storageKey)
    }

    func isBlocked(_ app: AppIdentityKey) -> Bool {
        blockedKeys.contains(app.storageKey) || resolveFirewall(for: app) == .block
    }

    func toggleArchive(_ app: AppIdentityKey) {
        let key = app.storageKey
        if archivedKeys.contains(key) {
            archivedKeys.remove(key)
        } else {
            archivedKeys.insert(key)
        }
        persistArchivedAndBlocked()
        refreshPublishedState()
    }

    func toggleBlock(_ app: AppIdentityKey) {
        setBlocked(app, blocked: !blockedKeys.contains(app.storageKey))
    }

    /// Explicit allow / block for ranking status menu.
    func setBlocked(_ app: AppIdentityKey, blocked: Bool) {
        let key = app.storageKey
        if blocked {
            guard !blockedKeys.contains(key) else { return }
            blockedKeys.insert(key)
            let rule = NetworkPolicyRule(
                priority: 50_000,
                app: .exact(app),
                destination: .any,
                firewall: .block,
                route: .inherit,
                note: "UI block"
            )
            policyStore.upsert(rule: rule)
        } else {
            guard blockedKeys.contains(key) else {
                // Still clear any UI block rules if firewall resolved via other means.
                removeBlockRules(for: app)
                refreshPublishedState()
                return
            }
            blockedKeys.remove(key)
            removeBlockRules(for: app)
        }
        persistArchivedAndBlocked()
        refreshPublishedState()
    }

    private func removeBlockRules(for app: AppIdentityKey) {
        for rule in policyStore.allRules() where rule.note == "UI block" {
            if case .exact(let key) = rule.app, key == app {
                policyStore.removeRule(id: rule.id)
            }
        }
    }

    private func loadArchivedAndBlocked() {
        if let arr = UserDefaults.standard.array(forKey: Self.archivedDefaultsKey) as? [String] {
            archivedKeys = Set(arr)
        }
        if let arr = UserDefaults.standard.array(forKey: Self.blockedDefaultsKey) as? [String] {
            blockedKeys = Set(arr)
        }
    }

    private func persistArchivedAndBlocked() {
        UserDefaults.standard.set(Array(archivedKeys).sorted(), forKey: Self.archivedDefaultsKey)
        UserDefaults.standard.set(Array(blockedKeys).sorted(), forKey: Self.blockedDefaultsKey)
    }

    // MARK: - Combined ranking filter

    /// Parsed ranking search: free-text tokens are AND; field tokens filter columns.
    /// Examples: `chrome route:direct`, `status:block group:Media`, `proxy:on 收藏`
    struct RankingQuery: Equatable {
        var texts: [String] = []
        var routes: Set<String> = []      // direct / system / socks5 / proxy
        var statuses: Set<String> = []    // allow / block
        var groups: [String] = []
        var proxyOn: Bool? = nil
        var favoritesOnly = false
        var archivedOnly = false

        var isEmpty: Bool {
            texts.isEmpty && routes.isEmpty && statuses.isEmpty
                && groups.isEmpty && proxyOn == nil && !favoritesOnly && !archivedOnly
        }

        static func parse(_ raw: String) -> RankingQuery {
            var q = RankingQuery()
            let parts = raw
                .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == ";" })
                .map(String.init)
                .filter { !$0.isEmpty }
            for part in parts {
                let lower = part.lowercased()
                if lower.hasPrefix("route:") || lower.hasPrefix("路由:") {
                    let v = String(part.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    q.routes.formUnion(Self.normalizeRouteTokens(v))
                } else if lower.hasPrefix("status:") || lower.hasPrefix("状态:") {
                    let v = String(part.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    q.statuses.formUnion(Self.normalizeStatusTokens(v))
                } else if lower.hasPrefix("group:") || lower.hasPrefix("分组:") {
                    let v = String(part.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    if !v.isEmpty { q.groups.append(v) }
                } else if lower.hasPrefix("proxy:") || lower.hasPrefix("代理:") {
                    let v = String(part.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    if ["on", "1", "true", "yes", "开", "开启"].contains(v) { q.proxyOn = true }
                    if ["off", "0", "false", "no", "关", "关闭"].contains(v) { q.proxyOn = false }
                } else if ["fav", "favorite", "favorites", "★", "收藏", "star"].contains(lower) {
                    q.favoritesOnly = true
                } else if ["archived", "archive", "归档"].contains(lower) {
                    q.archivedOnly = true
                } else {
                    q.texts.append(lower)
                }
            }
            return q
        }

        private static func normalizeRouteTokens(_ v: String) -> Set<String> {
            switch v {
            case "direct", "直连": return ["direct"]
            case "system", "系统", "systemproxy", "系统代理": return ["system"]
            case "socks5", "proxy", "代理", "custom", "自定义", "自定义代理": return ["socks5", "proxy"]
            default: return [v]
            }
        }

        private static func normalizeStatusTokens(_ v: String) -> Set<String> {
            switch v {
            case "block", "blocked", "拦截", "屏蔽", "deny": return ["block"]
            case "allow", "allowed", "允许", "放行": return ["allow"]
            default: return [v]
            }
        }

        func matches(row: AppRankingRow, isFavorite: Bool, isBlocked: Bool, isArchived: Bool) -> Bool {
            let snap = row.snapshot
            if favoritesOnly && !isFavorite { return false }
            if archivedOnly && !isArchived { return false }
            if !routes.isEmpty {
                let label = snap.route.chipLabel.lowercased()
                let hit = routes.contains { token in
                    label.contains(token) || token == "direct" && label == "direct"
                        || token == "system" && (label == "system" || label.contains("system"))
                        || (token == "socks5" || token == "proxy") && (label.contains("socks") || label == "proxy")
                }
                if !hit { return false }
            }
            if !statuses.isEmpty {
                let blocked = isBlocked || snap.firewallStatus == .block
                let wantBlock = statuses.contains("block")
                let wantAllow = statuses.contains("allow")
                if wantBlock && !wantAllow && !blocked { return false }
                if wantAllow && !wantBlock && blocked { return false }
            }
            if let proxyOn {
                let on = ProxyToggleLogic.isProxyEnabled(snap.route)
                if on != proxyOn { return false }
            }
            if !groups.isEmpty {
                let g = (row.groupName ?? "").lowercased()
                if !groups.contains(where: { g.contains($0) }) { return false }
            }
            for t in texts {
                let name = snap.displayName.lowercased()
                let sid = snap.app.signingIdentifier.lowercased()
                let g = (row.groupName ?? "").lowercased()
                if !(name.contains(t) || sid.contains(t) || g.contains(t)) {
                    return false
                }
            }
            return true
        }
    }

    func filteredRankingRows(_ rows: [AppRankingRow]) -> [AppRankingRow] {
        let parsed = RankingQuery.parse(rankingFilterQuery)
        guard !parsed.isEmpty else { return rows }
        return rows.filter { row in
            parsed.matches(
                row: row,
                isFavorite: isFavorite(row.snapshot.app),
                isBlocked: isBlocked(row.snapshot.app),
                isArchived: isArchived(row.snapshot.app)
            )
        }
    }

    /// Rows shown in ranking: active or archived panel, then combined filter.
    var displayedRankingRows: [AppRankingRow] {
        let base: [AppRankingRow]
        let parsed = RankingQuery.parse(rankingFilterQuery)
        if isArchivePanelPresented || parsed.archivedOnly {
            base = archivedRankingRows
        } else {
            base = visibleRankingRows
        }
        return filteredRankingRows(base)
    }

    var selectedRankingRow: AppRankingRow? {
        guard let app = selectedApp else { return nil }
        return rankingRows.first(where: { $0.snapshot.app == app })
            ?? archivedRankingRows.first(where: { $0.snapshot.app == app })
    }

    var selectedAppDisplayName: String? {
        selectedRankingRow?.snapshot.displayName
    }

    func selectRankingApp(_ app: AppIdentityKey?) {
        if let app, selectedApp == app {
            selectedApp = nil
        } else {
            selectedApp = app
        }
        sparklineDown = []
        sparklineUp = []
        sparklineRouteDirect = []
        sparklineRouteSystem = []
        sparklineRouteCustom = []
        refreshPublishedState()
    }

    func clearRankingSelection() {
        guard selectedApp != nil else { return }
        selectedApp = nil
        sparklineDown = []
        sparklineUp = []
        sparklineRouteDirect = []
        sparklineRouteSystem = []
        sparklineRouteCustom = []
        refreshPublishedState()
    }

    func revealInFinder(_ app: AppIdentityKey) {
        guard let url = AppIconCache.shared.applicationURL(forSigningID: app.signingIdentifier) else {
            return
        }
        // Context-menu dismissal reactivates this app and can immediately bury Finder.
        // Defer the reveal so Finder stays frontmost after the menu closes.
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let finderApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            if let finder = finderApps.first {
                finder.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    /// Remove telemetry for the app and drop it from ranking (also clears favorite pin).
    func deleteAppFromRanking(_ app: AppIdentityKey) {
        aggregator.purge(app: app)
        appRateHistory.removeValue(forKey: app.storageKey)
        favoriteKeys.remove(app.storageKey)
        persistFavorites()
        archivedKeys.remove(app.storageKey)
        blockedKeys.remove(app.storageKey)
        persistArchivedAndBlocked()
        if selectedApp == app {
            selectedApp = nil
        }
        refreshPublishedState()
    }

    private static func sortSnapshotsByFavorites(
        _ rows: [AppTrafficSnapshot],
        favorites: Set<String>
    ) -> [AppTrafficSnapshot] {
        rows.sorted { a, b in
            let af = favorites.contains(a.app.storageKey)
            let bf = favorites.contains(b.app.storageKey)
            if af != bf { return af && !bf }
            return a.totals.totalBytes > b.totals.totalBytes
        }
    }

    // MARK: - Global search

    enum SearchHitKind: String, Equatable {
        case app
        case site
        case rule
        case group
    }

    struct SearchHit: Identifiable, Equatable {
        let id: String
        let kind: SearchHitKind
        let title: String
        let subtitle: String
        let appKey: AppIdentityKey?
        let destination: Tab
    }

    func clearSearch() {
        searchQuery = ""
        isSearchPresented = false
        searchResults = []
    }

    func selectSearchHit(_ hit: SearchHit) {
        // Main UI is overview-only; search always focuses ranking / sunburst there.
        selectedTab = .overview
        if let app = hit.appKey {
            hoverNodeID = app.storageKey
            // Drill into browser sites when selecting a site hit
            if hit.kind == .site, let row = rankingRows.first(where: { $0.snapshot.app == app }) {
                if row.snapshot.isBrowser {
                    sunburstPath = [row.id]
                }
            }
        }
        isSearchPresented = false
    }

    private func recomputeSearchResults() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else {
            searchResults = []
            return
        }
        let needle = q.lowercased()
        var hits: [SearchHit] = []

        for row in rankingRows {
            let snap = row.snapshot
            let name = snap.displayName.lowercased()
            let sid = snap.app.signingIdentifier.lowercased()
            if name.contains(needle) || sid.contains(needle) {
                hits.append(SearchHit(
                    id: "app:\(snap.id)",
                    kind: .app,
                    title: snap.displayName,
                    subtitle: snap.app.signingIdentifier
                        + (isFavorite(snap.app) ? " ★" : ""),
                    appKey: snap.app,
                    destination: .overview
                ))
            }
            for site in snap.sites {
                if site.hostname.lowercased().contains(needle) {
                    hits.append(SearchHit(
                        id: "site:\(snap.id)|\(site.destinationKey)",
                        kind: .site,
                        title: site.hostname,
                        subtitle: snap.displayName,
                        appKey: snap.app,
                        destination: .overview
                    ))
                }
            }
        }

        for group in groups {
            if group.name.lowercased().contains(needle) {
                hits.append(SearchHit(
                    id: "group:\(group.id.uuidString)",
                    kind: .group,
                    title: group.name,
                    subtitle: "\(group.memberKeys.count) apps",
                    appKey: nil,
                    destination: .overview
                ))
            }
        }

        for rule in rules {
            let note = (rule.note ?? "").lowercased()
            let dest: String = {
                switch rule.destination {
                case .any: return "any"
                case .hostnameExact(let h): return h.lowercased()
                case .hostnameSuffix(let s): return s.lowercased()
                case .ip(let a): return a.lowercased()
                case .cidr(let n, _): return n.lowercased()
                }
            }()
            if note.contains(needle) || dest.contains(needle) {
                hits.append(SearchHit(
                    id: "rule:\(rule.id.uuidString)",
                    kind: .rule,
                    title: rule.note ?? String(rule.id.uuidString.prefix(8)),
                    subtitle: dest,
                    appKey: nil,
                    destination: .overview
                ))
            }
        }

        searchResults = Array(hits.prefix(24))
    }

    deinit {
        tickTimer?.invalidate()
    }

    // MARK: - Public actions

    func selectTab(_ tab: Tab) {
        selectedTab = tab
    }

    /// Open the dedicated Settings window (language, appearance, protection, updates).
    func openSettings() {
        SettingsWindowController.shared.show(model: self)
    }

    /// Split total live rates into direct vs proxy using current route mix shares.
    private func recomputePathRates() {
        // Proxy path = system proxy + custom proxy profiles.
        var dFrac = max(0, routeMix.directPercent) / 100
        var pFrac = max(0, routeMix.systemProxyPercent + routeMix.customProxyPercent) / 100
        if !proxyEnabled {
            dFrac = 1
            pFrac = 0
        }
        let sum = dFrac + pFrac
        if sum <= 0.000_1 {
            dFrac = 1
            pFrac = 0
        } else {
            dFrac /= sum
            pFrac /= sum
        }

        // Slight path bias on up vs down so columns aren't identical twins.
        let downDirectBias = demoMode ? (0.97 + sin(demoClock / 7) * 0.03) : 1.0
        let upDirectBias = demoMode ? (1.03 + cos(demoClock / 9) * 0.03) : 1.0
        let dDownShare = min(1, max(0, dFrac * downDirectBias))
        let dUpShare = min(1, max(0, dFrac * upDirectBias))

        directDownBps = rateDownBps * dDownShare
        proxyDownBps = max(0, rateDownBps - directDownBps)
        directUpBps = rateUpBps * dUpShare
        proxyUpBps = max(0, rateUpBps - directUpBps)

        let total = directDownBps + directUpBps + proxyDownBps + proxyUpBps
        if total > 1 {
            directShare = (directDownBps + directUpBps) / total
            proxyShare = (proxyDownBps + proxyUpBps) / total
        } else {
            directShare = dFrac
            proxyShare = pFrac
        }

        sparklineDirect.append(directDownBps + directUpBps)
        sparklineProxy.append(proxyDownBps + proxyUpBps)
        if sparklineDirect.count > 40 {
            sparklineDirect.removeFirst(sparklineDirect.count - 40)
            sparklineProxy.removeFirst(sparklineProxy.count - 40)
        }

        sparklineRouteDirect.append(routeMix.directPercent)
        sparklineRouteSystem.append(routeMix.systemProxyPercent)
        sparklineRouteCustom.append(routeMix.customProxyPercent)
        if sparklineRouteDirect.count > 40 {
            sparklineRouteDirect.removeFirst(sparklineRouteDirect.count - 40)
            sparklineRouteSystem.removeFirst(sparklineRouteSystem.count - 40)
            sparklineRouteCustom.removeFirst(sparklineRouteCustom.count - 40)
        }
    }

    /// Header proxy status: 代理 / 配置 / 直连 / 无.
    var globalProxyStatus: GlobalProxyStatus {
        let hasEnabledProfile = proxyProfiles.contains(where: \.enabled)
        let hasAnyProfile = !proxyProfiles.isEmpty

        if !proxyEnabled {
            // Master off: configured profiles still count as "配置", otherwise "无".
            return (hasEnabledProfile || hasAnyProfile) ? .configured : .none
        }

        let hasCustomProxyRoute = rankingRows.contains {
            if case .proxy = $0.snapshot.route { return true }
            return false
        }
        let hasSystemProxyRoute = rankingRows.contains {
            if case .systemProxy = $0.snapshot.route { return true }
            return false
        }

        if routeMix.customProxyPercent > 0 || hasCustomProxyRoute {
            return .proxy
        }
        if routeMix.systemProxyPercent > 0 || hasSystemProxyRoute {
            return .configured
        }
        // Selective proxy on, but resolved routes are direct (or inherit→direct).
        return .direct
    }

    func setFilterEnabled(_ enabled: Bool) {
        filterEnabled = enabled
        isRunning = enabled || proxyEnabled
    }

    func setProxyEnabled(_ enabled: Bool) {
        proxyEnabled = enabled
        isRunning = filterEnabled || enabled
    }

    func assignRoute(app: AppIdentityKey, route: RouteAction) {
        policyStore.assignRoute(app: app, route: route)
        rules = policyStore.allRules()
        groups = policyStore.allGroups()
        recomputeRouteLabels()
    }

    // MARK: - Groups

    func group(containing app: AppIdentityKey) -> AppGroup? {
        groups.first(where: { $0.memberKeys.contains(app) })
    }

    @discardableResult
    func createGroup(
        name: String,
        defaultRoute: RouteAction = .inherit,
        defaultFirewall: FirewallAction = .inherit
    ) -> AppGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = AppGroup(
            name: trimmed,
            defaultRoute: defaultRoute,
            defaultFirewall: defaultFirewall
        )
        policyStore.upsert(group: group)
        refreshPublishedState()
        return group
    }

    func renameGroup(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var group = groups.first(where: { $0.id == id }) else { return }
        group.name = trimmed
        policyStore.upsert(group: group)
        refreshPublishedState()
    }

    func updateGroupDefaults(
        id: UUID,
        defaultRoute: RouteAction? = nil,
        defaultFirewall: FirewallAction? = nil
    ) {
        guard var group = groups.first(where: { $0.id == id }) else { return }
        if let defaultRoute { group.defaultRoute = defaultRoute }
        if let defaultFirewall { group.defaultFirewall = defaultFirewall }
        policyStore.upsert(group: group)
        refreshPublishedState()
    }

    func deleteGroup(id: UUID) {
        policyStore.removeGroup(id: id)
        refreshPublishedState()
    }

    /// Move app into `groupID`, or `nil` to leave ungrouped. Membership is exclusive.
    func setAppGroup(_ app: AppIdentityKey, groupID: UUID?) {
        policyStore.moveApp(app, toGroup: groupID)
        refreshPublishedState()
    }

    func reorderGroups(orderedIDs: [UUID]) {
        policyStore.reorderGroups(orderedIDs: orderedIDs)
        refreshPublishedState()
    }

    /// Toggle selective proxy for an app using the **resolved** route (rules + groups),
    /// not the raw assignment (which may be `.inherit` while UI shows Proxy).
    func toggleAppProxy(_ snapshot: AppTrafficSnapshot) {
        let profileID = proxyProfiles.first?.id ?? UUID()
        let resolved = resolveRoute(for: snapshot.app)
        let next = ProxyToggleLogic.nextRoute(resolved: resolved, profileID: profileID)
        assignRoute(app: snapshot.app, route: next)
    }

    func openDashboard() {
        selectedTab = .overview
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == AppBrand.displayName || $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func refreshHistory() {
        let range = overviewDateRange()
        let rows = aggregator.topApps(from: range.start, to: range.end, limit: 50)
        historyRows = Self.sortSnapshotsByFavorites(rows, favorites: favoriteKeys)
        recomputeSearchResults()
    }

    // MARK: - Tick

    private func startTicker() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.onTick()
            }
        }
    }

    private func onTick() {
        demoClock += 1
        if demoMode {
            injectDemoDelta()
        }
        refreshPublishedState()
    }

    private func refreshPublishedState() {
        let now = Date()
        let range = overviewDateRange(now: now)
        let periodFrom = range.start
        let periodTo = range.end
        periodRangeStart = periodFrom
        periodRangeEnd = periodTo
        let dayFrom = now.addingTimeInterval(-86_400)

        // Resolve selected app identity early (may be nil).
        let selectedIdentity = selectedApp

        let rates = aggregator.liveRateBps(for: selectedIdentity)
        // Blend live rates with demo floor so UI stays lively in demo mode
        if demoMode {
            if let selectedIdentity,
               let snap = rankingRows.first(where: { $0.snapshot.app == selectedIdentity })
                ?? archivedRankingRows.first(where: { $0.snapshot.app == selectedIdentity }) {
                rateDownBps = max(snap.snapshot.rateDownBps, rates.down)
                rateUpBps = max(snap.snapshot.rateUpBps, rates.up)
                // Soft floor so selected app still animates a little in demo.
                if rateDownBps < 1_000 {
                    rateDownBps = 120_000 + sin(demoClock / 4) * 20_000
                }
                if rateUpBps < 1_000 {
                    rateUpBps = 28_000 + cos(demoClock / 5) * 6_000
                }
            } else if selectedIdentity != nil {
                rateDownBps = rates.down
                rateUpBps = rates.up
            } else {
                rateDownBps = max(rates.down, 1_550_000 + sin(demoClock / 4) * 200_000)
                rateUpBps = max(rates.up, 280_000 + cos(demoClock / 5) * 40_000)
            }
        } else {
            rateDownBps = rates.down
            rateUpBps = rates.up
        }

        sparklineDown.append(rateDownBps)
        sparklineUp.append(rateUpBps)
        if sparklineDown.count > 40 {
            sparklineDown.removeFirst(sparklineDown.count - 40)
            sparklineUp.removeFirst(sparklineUp.count - 40)
        }

        // Period network totals for active range (optionally scoped to selected app).
        let periodTotals = aggregator.totals(for: selectedIdentity, from: periodFrom, to: periodTo)
        if demoMode {
            // Scale seeded demo traffic so longer ranges look larger than the live window.
            let live = aggregator.totals(for: selectedIdentity, from: dayFrom, to: now)
            var scale = overviewPeriod.networkScale
            if overviewPeriod == .custom {
                let hours = max(1, periodTo.timeIntervalSince(periodFrom) / 3600)
                scale = UInt64(max(1, hours / 24))
            }
            periodNetworkUp = max(periodTotals.bytesUp, live.bytesUp) &* scale
            periodNetworkDown = max(periodTotals.bytesDown, live.bytesDown) &* scale
            // Disk I/O: demo facade (real path would use IOKit / endpoint stats later).
            let weekRead: UInt64 = 42_000_000_000   // ~42 GB
            let weekWrite: UInt64 = 18_500_000_000  // ~18.5 GB
            var ds = overviewPeriod.diskScale
            if overviewPeriod == .custom {
                let days = max(0.05, periodTo.timeIntervalSince(periodFrom) / 86_400)
                ds = days / 7.0
            }
            var diskR = UInt64(Double(weekRead) * ds)
            var diskW = UInt64(Double(weekWrite) * ds)
            if let selectedIdentity {
                // Share of global disk by this app's network share in the period.
                let allNet = aggregator.totals(for: nil, from: periodFrom, to: periodTo)
                let appNet = max(1, periodTotals.totalBytes)
                let allBytes = max(1, allNet.totalBytes)
                let share = min(1.0, Double(appNet) / Double(allBytes))
                let bias = demoDiskBias(for: selectedIdentity)
                diskR = UInt64(Double(diskR) * share * bias)
                diskW = UInt64(Double(diskW) * share * (2.0 - bias))
            }
            periodDiskRead = diskR
            periodDiskWrite = diskW
        } else {
            periodNetworkUp = periodTotals.bytesUp
            periodNetworkDown = periodTotals.bytesDown
            periodDiskRead = 0
            periodDiskWrite = 0
        }

        // Period trend series for totals mini charts.
        let series = aggregator.byteSeries(
            for: selectedIdentity,
            from: periodFrom,
            to: periodTo,
            points: 28
        )
        if series.down.contains(where: { $0 > 0 }) || series.up.contains(where: { $0 > 0 }) {
            periodTrendDown = series.down
            periodTrendUp = series.up
        } else if demoMode {
            // Synthesize a gentle trend from current period totals so charts aren't flat.
            let baseDown = Double(max(1, periodNetworkDown)) / 28.0
            let baseUp = Double(max(1, periodNetworkUp)) / 28.0
            let clock = demoClock
            var downTrend: [Double] = []
            var upTrend: [Double] = []
            downTrend.reserveCapacity(28)
            upTrend.reserveCapacity(28)
            for i in 0..<28 {
                let waveDown = 0.5 + 0.5 * sin(Double(i) / 4.0 + clock / 9)
                let waveUp = 0.5 + 0.5 * cos(Double(i) / 5.0 + clock / 11)
                downTrend.append(baseDown * (0.55 + 0.45 * waveDown))
                upTrend.append(baseUp * (0.55 + 0.45 * waveUp))
            }
            periodTrendDown = downTrend
            periodTrendUp = upTrend
        } else {
            periodTrendDown = series.down
            periodTrendUp = series.up
        }

        var tops = aggregator.topApps(
            from: periodFrom,
            to: periodTo,
            limit: Self.rankingLimit,
            includeSitesForBrowsers: true
        )
        tops = tops.map { snap in
            let route = resolveRoute(for: snap.app)
            let firewall = resolveFirewall(for: snap.app)
            let name = AppIconCache.shared.displayName(
                forSigningID: snap.app.signingIdentifier,
                fallback: snap.displayName
            )
            return AppTrafficSnapshot(
                app: snap.app,
                displayName: name,
                totals: snap.totals,
                rateUpBps: snap.rateUpBps,
                rateDownBps: snap.rateDownBps,
                activeConnections: snap.activeConnections,
                route: route,
                firewallStatus: firewall,
                isBrowser: snap.isBrowser,
                sites: snap.sites
            )
        }
        rules = policyStore.allRules()
        groups = policyStore.allGroups()

        let connectionPool = aggregator.recentConnections(limit: 40)
        let scopedConnections: [LiveConnection]
        if let selectedIdentity {
            scopedConnections = connectionPool.filter { $0.app == selectedIdentity }
        } else {
            scopedConnections = connectionPool
        }
        liveConnections = Array(scopedConnections.prefix(12)).map { conn in
            LiveConnection(
                id: conn.id,
                app: conn.app,
                displayName: conn.displayName,
                host: conn.host,
                protocolLabel: conn.protocolLabel,
                route: resolveRoute(for: conn.app),
                firewall: conn.firewall,
                timestamp: conn.timestamp,
                bytesUp: conn.bytesUp,
                bytesDown: conn.bytesDown
            )
        }

        let dayTotals = aggregator.totals(for: selectedIdentity, from: dayFrom, to: now)
        blockedToday = dayTotals.flowsBlocked > 0 ? dayTotals.flowsBlocked : (demoMode && selectedIdentity == nil ? 1_248 : dayTotals.flowsBlocked)
        allowedConnections = dayTotals.flowsOpened > 0 ? dayTotals.flowsOpened : (demoMode && selectedIdentity == nil ? 12_853 : dayTotals.flowsOpened)

        let activeRuleCount = policyStore.compileSnapshot().activeRuleCount + groups.count
        let periodRouteShare = aggregator.routeByteShare(
            for: selectedIdentity,
            from: periodFrom,
            to: periodTo
        )
        routeMix = Self.makeRouteMix(
            share: periodRouteShare,
            selectedRoute: selectedIdentity.flatMap { id in tops.first(where: { $0.app == id })?.route },
            proxyEnabled: proxyEnabled,
            blockedFallback: blockedToday,
            activeRules: activeRuleCount,
            demoMode: demoMode,
            demoClock: demoClock
        )
        recomputePathRates()

        // Build ranking rows with group + proportional demo disk share.
        // Share is relative to the *active* (non-archived) set so pie + rank stay consistent.
        let activeTops = tops.filter { !archivedKeys.contains($0.app.storageKey) }
        var archivedTops = tops.filter { archivedKeys.contains($0.app.storageKey) }
        // Keep archived keys visible even with zero traffic in the current period.
        let presentArchived = Set(archivedTops.map(\.app.storageKey))
        for key in archivedKeys where !presentArchived.contains(key) {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let team = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            let sid = parts.count > 1 ? parts[1] : key
            let identity = AppIdentityKey(teamIdentifier: team, signingIdentifier: sid)
            let name = AppIconCache.shared.displayName(forSigningID: sid, fallback: sid)
            archivedTops.append(
                AppTrafficSnapshot(
                    app: identity,
                    displayName: name,
                    totals: TrafficTotals(),
                    rateUpBps: 0,
                    rateDownBps: 0,
                    activeConnections: 0,
                    route: resolveRoute(for: identity),
                    firewallStatus: resolveFirewall(for: identity),
                    isBrowser: BrowserIdentity.isBrowser(identity),
                    sites: []
                )
            )
        }
        let netTotal = max(1, activeTops.reduce(UInt64(0)) { $0 &+ $1.totals.totalBytes })
        let diskR = selectedIdentity == nil ? periodDiskRead : {
            // When filtered, ranking disk columns still use global period disk for proportions.
            let weekRead: UInt64 = 42_000_000_000
            var ds = overviewPeriod.diskScale
            if overviewPeriod == .custom {
                let days = max(0.05, periodTo.timeIntervalSince(periodFrom) / 86_400)
                ds = days / 7.0
            }
            return demoMode ? UInt64(Double(weekRead) * ds) : periodDiskRead
        }()
        let diskW = selectedIdentity == nil ? periodDiskWrite : {
            let weekWrite: UInt64 = 18_500_000_000
            var ds = overviewPeriod.diskScale
            if overviewPeriod == .custom {
                let days = max(0.05, periodTo.timeIntervalSince(periodFrom) / 86_400)
                ds = days / 7.0
            }
            return demoMode ? UInt64(Double(weekWrite) * ds) : periodDiskWrite
        }()

        updateAppRateHistory(from: activeTops + archivedTops)

        func makeRows(from snaps: [AppTrafficSnapshot], shareBase: UInt64) -> [AppRankingRow] {
            snaps.map { snap -> AppRankingRow in
                let share = Double(snap.totals.totalBytes) / Double(max(1, shareBase))
                let groupName = groups.first(where: { $0.memberKeys.contains(snap.app) })?.name
                let bias = demoDiskBias(for: snap.app)
                let lastAt = aggregator.lastTrafficAt(for: snap.app)
                    ?? ((snap.rateDownBps + snap.rateUpBps) > 1 ? now : nil)
                return AppRankingRow(
                    snapshot: snap,
                    diskRead: UInt64(Double(diskR) * share * bias),
                    diskWrite: UInt64(Double(diskW) * share * (2.0 - bias)),
                    groupName: groupName,
                    share: min(1, share),
                    lastTrafficAt: lastAt,
                    rateSeries: displayRateSeries(
                        for: snap,
                        periodFrom: periodFrom,
                        periodTo: periodTo
                    )
                )
            }
        }

        let unsorted = makeRows(from: activeTops, shareBase: netTotal)
        rankingRows = Self.sortByFavorites(unsorted, favorites: favoriteKeys)
        topApps = rankingRows.map(\.snapshot)

        let archBase = max(1, archivedTops.reduce(UInt64(0)) { $0 &+ $1.totals.totalBytes })
        archivedRankingRows = Self.sortByFavorites(
            makeRows(from: archivedTops, shareBase: archBase),
            favorites: favoriteKeys
        )

        // Drop stale selection if app vanished after purge / archive.
        if let app = selectedApp {
            let stillThere = rankingRows.contains(where: { $0.snapshot.app == app })
                || archivedRankingRows.contains(where: { $0.snapshot.app == app })
            if !stillThere {
                selectedApp = nil
            }
        }

        sunburstRoot = Self.buildSunburst(from: rankingRows)
        // Drop path segments that no longer exist after data refresh.
        var validPath: [String] = []
        var cursor = sunburstRoot
        for step in sunburstPath {
            guard let next = cursor.children.first(where: { $0.id == step }) else { break }
            validPath.append(step)
            cursor = next
        }
        if validPath != sunburstPath {
            sunburstPath = validPath
        }

        refreshHistory()
    }

    private static func buildSunburst(from rows: [AppRankingRow]) -> SunburstNode {
        let paletteCount = 12.0
        let children: [SunburstNode] = rows.enumerated().map { index, row in
            let hue = (Double(index) / paletteCount).truncatingRemainder(dividingBy: 1.0)
            let appID = row.snapshot.id
            // Drill children: websites (Chrome), projects (VS Code), sessions (ChatGPT)…
            let siteChildren: [SunburstNode]
            if !row.snapshot.sites.isEmpty {
                let siteTotal = max(1, row.snapshot.sites.reduce(UInt64(0)) { $0 &+ $1.totals.totalBytes })
                siteChildren = row.snapshot.sites.enumerated().map { sIdx, site in
                    let siteHue = (hue + 0.03 * Double(sIdx)).truncatingRemainder(dividingBy: 1.0)
                    let siteValue = max(
                        1,
                        UInt64(Double(row.snapshot.totals.totalBytes) * Double(site.totals.totalBytes) / Double(siteTotal))
                    )
                    return SunburstNode(
                        id: "\(appID)|\(site.destinationKey)",
                        title: site.hostname,
                        value: siteValue,
                        hue: siteHue,
                        children: []
                    )
                }
            } else {
                siteChildren = []
            }
            return SunburstNode(
                id: appID,
                title: row.snapshot.displayName,
                value: max(1, row.snapshot.totals.totalBytes),
                hue: hue,
                children: siteChildren
            )
        }
        let total = children.reduce(UInt64(0)) { $0 &+ $1.value }
        return SunburstNode(id: "root", title: "Root", value: total, hue: 0.55, children: children)
    }

    /// Ranking rows for the current drill level (apps at root; sites/projects when drilled).
    var visibleRankingRows: [AppRankingRow] {
        guard let appID = sunburstPath.first,
              let parent = rankingRows.first(where: { $0.id == appID }) else {
            return rankingRows
        }
        let sites = parent.snapshot.sites
        guard !sites.isEmpty else { return rankingRows }
        let siteTotal = max(1, sites.reduce(UInt64(0)) { $0 &+ $1.totals.totalBytes })
        return sites.map { site in
            let share = Double(site.totals.totalBytes) / Double(siteTotal)
            let scaledSeries = parent.rateSeries.map { $0 * share }
            return AppRankingRow(
                id: "\(parent.id)|\(site.destinationKey)",
                snapshot: AppTrafficSnapshot(
                    app: parent.snapshot.app,
                    displayName: site.hostname,
                    totals: site.totals,
                    rateUpBps: 0,
                    rateDownBps: 0,
                    activeConnections: site.activeConnections,
                    route: parent.snapshot.route,
                    firewallStatus: parent.snapshot.firewallStatus,
                    isBrowser: parent.snapshot.isBrowser,
                    sites: []
                ),
                diskRead: UInt64(Double(parent.diskRead) * share),
                diskWrite: UInt64(Double(parent.diskWrite) * share),
                groupName: parent.groupName,
                share: share,
                lastTrafficAt: site.totals.totalBytes > 0 ? parent.lastTrafficAt : nil,
                rateSeries: scaledSeries
            )
        }
    }

    /// Append one live (down+up) sample per visible app each tick.
    private func updateAppRateHistory(from snaps: [AppTrafficSnapshot]) {
        let activeKeys = Set(snaps.map(\.app.storageKey))
        for snap in snaps {
            let key = snap.app.storageKey
            var series = appRateHistory[key] ?? []
            series.append(snap.rateDownBps + snap.rateUpBps)
            if series.count > Self.appRateHistoryLimit {
                series.removeFirst(series.count - Self.appRateHistoryLimit)
            }
            appRateHistory[key] = series
        }
        appRateHistory = appRateHistory.filter { activeKeys.contains($0.key) || archivedKeys.contains($0.key) }
    }

    /// Prefer live sparkline; when idle, show period byte shape so the cell isn't empty.
    private func displayRateSeries(
        for snap: AppTrafficSnapshot,
        periodFrom: Date,
        periodTo: Date
    ) -> [Double] {
        let live = appRateHistory[snap.app.storageKey] ?? []
        if (live.max() ?? 0) > 1 {
            return live
        }
        guard snap.totals.totalBytes > 0 else { return live }
        let bytes = aggregator.byteSeries(
            for: snap.app,
            from: periodFrom,
            to: periodTo,
            points: Self.appRateHistoryLimit
        )
        let combined = zip(bytes.down, bytes.up).map { $0 + $1 }
        if (combined.max() ?? 0) > 0 {
            return combined
        }
        return live
    }

    var drilledAppTitle: String? {
        guard let id = sunburstPath.first else { return nil }
        return rankingRows.first(where: { $0.id == id })?.snapshot.displayName
    }

    /// Deterministic 0.7...1.3 multiplier so demo disk columns vary by app.
    private func demoDiskBias(for app: AppIdentityKey) -> Double {
        let h = abs(app.signingIdentifier.hashValue % 100)
        return 0.7 + Double(h) / 200.0
    }

    /// Build proxy-routing card mix from period-scoped byte shares (time range + optional app).
    private static func makeRouteMix(
        share: (direct: UInt64, systemProxy: UInt64, customProxy: UInt64, blockedFlows: UInt64),
        selectedRoute: RouteAction?,
        proxyEnabled: Bool,
        blockedFallback: UInt64,
        activeRules: Int,
        demoMode: Bool,
        demoClock: TimeInterval
    ) -> RouteMix {
        let blocked = share.blockedFlows > 0 ? share.blockedFlows : blockedFallback

        if !proxyEnabled {
            return RouteMix(
                directPercent: 100,
                systemProxyPercent: 0,
                customProxyPercent: 0,
                blockedCount: blocked,
                activeRules: activeRules
            )
        }

        let total = share.direct &+ share.systemProxy &+ share.customProxy
        if total > 0 {
            let d = Double(share.direct) / Double(total) * 100
            let s = Double(share.systemProxy) / Double(total) * 100
            let c = max(0, 100 - d - s)
            return RouteMix(
                directPercent: d,
                systemProxyPercent: s,
                customProxyPercent: c,
                blockedCount: blocked,
                activeRules: activeRules
            )
        }

        // No bytes in range: if an app is selected, show its resolved route; else demo blend.
        if let selectedRoute {
            switch selectedRoute {
            case .direct, .inherit:
                return RouteMix(
                    directPercent: 100,
                    systemProxyPercent: 0,
                    customProxyPercent: 0,
                    blockedCount: blocked,
                    activeRules: activeRules
                )
            case .systemProxy:
                return RouteMix(
                    directPercent: 0,
                    systemProxyPercent: 100,
                    customProxyPercent: 0,
                    blockedCount: blocked,
                    activeRules: activeRules
                )
            case .proxy(_):
                return RouteMix(
                    directPercent: 0,
                    systemProxyPercent: 0,
                    customProxyPercent: 100,
                    blockedCount: blocked,
                    activeRules: activeRules
                )
            }
        }

        if demoMode {
            let wobble = sin(demoClock / 11) * 4
            let direct = max(5, min(90, 62 + wobble))
            let system = max(5, min(40, 25 - wobble * 0.5))
            let custom = max(0, 100 - direct - system)
            return RouteMix(
                directPercent: direct,
                systemProxyPercent: system,
                customProxyPercent: custom,
                blockedCount: blocked,
                activeRules: activeRules
            )
        }

        return RouteMix(
            directPercent: 100,
            systemProxyPercent: 0,
            customProxyPercent: 0,
            blockedCount: blocked,
            activeRules: activeRules
        )
    }

    private func resolveFirewall(for app: AppIdentityKey) -> FirewallAction {
        if blockedKeys.contains(app.storageKey) { return .block }
        // Prefer explicit UI/policy block rules.
        for rule in policyStore.allRules() where rule.enabled && rule.firewall == .block {
            switch rule.app {
            case .exact(let key) where key == app:
                return .block
            case .signingID(let sid) where sid == app.signingIdentifier:
                return .block
            default:
                continue
            }
        }
        if let group = groups.first(where: { $0.memberKeys.contains(app) }),
           group.defaultFirewall == .block {
            return .block
        }
        return .allow
    }

    private func resolveRoute(for app: AppIdentityKey) -> RouteAction {
        let snap = policyStore.compileSnapshot()
        return snap.evaluateRoute(FlowDescriptor(app: app)).action
    }

    private func recomputeRouteLabels() {
        refreshPublishedState()
    }

    // MARK: - Seed data

    private func seedPolicies() {
        let socksProfile = ProxyProfile(
            name: "Office SOCKS5",
            kind: .socks5,
            host: "127.0.0.1",
            port: 1080
        )
        proxyProfiles = [socksProfile]

        let chrome = AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome")
        let claude = AppIdentityKey(teamIdentifier: "TEAM2", signingIdentifier: "com.anthropic.claude")
        let discord = AppIdentityKey(teamIdentifier: "53Q6R32WPB", signingIdentifier: "com.hnc.Discord")
        let telegram = AppIdentityKey(teamIdentifier: "6N38VWS5BX", signingIdentifier: "ru.keepcoder.Telegram")
        let slack = AppIdentityKey(teamIdentifier: "BQR82RBBHL", signingIdentifier: "com.tinyspeck.slackmacgap")

        policyStore.assignRoute(app: claude, route: .proxy(profileID: socksProfile.id))
        policyStore.assignRoute(app: telegram, route: .proxy(profileID: socksProfile.id))
        policyStore.assignRoute(app: discord, route: .systemProxy)
        policyStore.assignRoute(app: slack, route: .systemProxy)
        policyStore.assignRoute(app: chrome, route: .direct)

        let mediaGroup = AppGroup(
            name: "Media",
            memberKeys: [
                AppIdentityKey(teamIdentifier: "2FNC3A47ZF", signingIdentifier: "com.spotify.client")
            ],
            defaultRoute: .direct
        )
        policyStore.upsert(group: mediaGroup)

        let blockRule = NetworkPolicyRule(
            priority: 100,
            app: .any,
            destination: .hostnameSuffix("metrics.example.com"),
            firewall: .block,
            route: .direct,
            note: "Block analytics endpoint"
        )
        policyStore.upsert(rule: blockRule)

        let allowAPI = NetworkPolicyRule(
            priority: 50,
            app: .exact(claude),
            destination: .hostnameExact("api.anthropic.com"),
            firewall: .allow,
            route: .proxy(profileID: socksProfile.id),
            note: "Claude via SOCKS5"
        )
        policyStore.upsert(rule: allowAPI)
    }

    private func seedDemoTraffic() {
        // Drill-down demos:
        // - Chrome/Safari → websites
        // - VS Code → projects
        // - ChatGPT / Claude → sessions
        let chrome = AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome")
        let safari = AppIdentityKey(teamIdentifier: "APPLE", signingIdentifier: "com.apple.Safari")
        let vscode = AppIdentityKey(teamIdentifier: "UBF8T346G9", signingIdentifier: "com.microsoft.VSCode")
        let chatgpt = AppIdentityKey(teamIdentifier: "2DC432GLL2", signingIdentifier: "com.openai.chat")
        let claude = AppIdentityKey(teamIdentifier: "TEAM2", signingIdentifier: "com.anthropic.claude")

        let chromeSites: [(String, UInt64, UInt64)] = [
            ("www.google.com", 120_000_000, 1_200_000_000),
            ("github.com", 80_000_000, 900_000_000),
            ("www.youtube.com", 200_000_000, 980_000_000),
            ("news.ycombinator.com", 42_000_000, 220_000_000),
            ("stackoverflow.com", 50_000_000, 150_000_000),
            ("docs.python.org", 28_000_000, 110_000_000),
        ]
        let safariSites: [(String, UInt64, UInt64)] = [
            ("www.apple.com", 30_000_000, 180_000_000),
            ("developer.apple.com", 25_000_000, 220_000_000),
            ("icloud.com", 15_000_000, 90_000_000),
        ]
        // VS Code: different projects (synthetic destination keys)
        let vscodeProjects: [(String, UInt64, UInt64)] = [
            ("project:EyesOnYou", 90_000_000, 420_000_000),
            ("project:dontbesilent-web", 55_000_000, 280_000_000),
            ("project:design-system", 40_000_000, 190_000_000),
            ("project:api-gateway", 35_000_000, 160_000_000),
            ("project:infra-scripts", 18_000_000, 70_000_000),
        ]
        // ChatGPT: different chats / projects
        let chatgptSessions: [(String, UInt64, UInt64)] = [
            ("session:Swift concurrency rewrite", 40_000_000, 220_000_000),
            ("session:App Store copy", 22_000_000, 95_000_000),
            ("session:Travel planning", 12_000_000, 48_000_000),
            ("session:Code review helpers", 30_000_000, 150_000_000),
        ]
        let claudeSessions: [(String, UInt64, UInt64)] = [
            ("session:Architecture review", 50_000_000, 400_000_000),
            ("session:Debug NEFilter", 35_000_000, 280_000_000),
            ("session:Marketing outline", 20_000_000, 120_000_000),
        ]

        let other: [(String, String, String?, UInt64, UInt64, String)] = [
            ("Xcode", "com.apple.dt.Xcode", "APPLE", 198_000_000, 1_120_000_000, "developer.apple.com"),
            ("Discord", "com.hnc.Discord", "53Q6R32WPB", 156_000_000, 823_000_000, "gateway.discord.gg"),
            ("Spotify", "com.spotify.client", "2FNC3A47ZF", 98_000_000, 512_000_000, "audio-fa.scdn.co"),
            ("Slack", "com.tinyspeck.slackmacgap", "BQR82RBBHL", 64_000_000, 342_000_000, "wss-primary.slack.com"),
            ("Telegram", "ru.keepcoder.Telegram", "6N38VWS5BX", 37_000_000, 221_000_000, "api.telegram.org"),
            ("zoom.us", "us.zoom.xos", "BJ4HAAB9B3", 28_000_000, 178_000_000, "zoom.us"),
        ]

        let now = Date()
        var offset = 0
        for site in chromeSites {
            seedSite(app: chrome, displayName: "Chrome", host: site.0, up: site.1, down: site.2, at: now, offset: offset)
            offset += 1
        }
        for site in safariSites {
            seedSite(app: safari, displayName: "Safari", host: site.0, up: site.1, down: site.2, at: now, offset: offset)
            offset += 1
        }
        for p in vscodeProjects {
            seedSite(app: vscode, displayName: "Visual Studio Code", host: p.0, up: p.1, down: p.2, at: now, offset: offset)
            offset += 1
        }
        for s in chatgptSessions {
            seedSite(app: chatgpt, displayName: "ChatGPT", host: s.0, up: s.1, down: s.2, at: now, offset: offset)
            offset += 1
        }
        for s in claudeSessions {
            seedSite(app: claude, displayName: "Claude", host: s.0, up: s.1, down: s.2, at: now, offset: offset)
            offset += 1
        }
        for sample in other {
            let app = AppIdentityKey(teamIdentifier: sample.2, signingIdentifier: sample.1)
            seedSite(
                app: app,
                displayName: sample.0,
                host: sample.5,
                up: sample.3,
                down: sample.4,
                at: now,
                offset: offset
            )
            offset += 1
        }

        let blockedApp = AppIdentityKey(teamIdentifier: "ANALYTICS", signingIdentifier: "com.example.Analytics")
        let blockedFlow = FlowDescriptor(
            app: blockedApp,
            remoteHostname: "metrics.example.com",
            remotePort: 443,
            openedAt: now
        )
        aggregator.recordOpen(blockedFlow, displayName: "Analytics", route: .direct, firewall: .block)
    }

    private func seedSite(
        app: AppIdentityKey,
        displayName: String,
        host: String,
        up: UInt64,
        down: UInt64,
        at: Date,
        offset: Int
    ) {
        let flow = FlowDescriptor(
            app: app,
            remoteHostname: host,
            remotePort: 443,
            openedAt: at.addingTimeInterval(Double(-offset) - 1)
        )
        let route = resolveRoute(for: app)
        aggregator.recordOpen(flow, displayName: displayName, route: route)
        aggregator.recordDelta(
            flowID: flow.id,
            app: app,
            up: up,
            down: down,
            at: at.addingTimeInterval(Double(-offset)),
            route: route,
            destinationKey: DestinationKey.make(hostname: host, address: nil)
        )
    }

    private func injectDemoDelta() {
        guard let top = topApps.first ?? rankingRows.first?.snapshot else { return }
        let flowID = UUID()
        let flow = FlowDescriptor(
            id: flowID,
            app: top.app,
            remoteHostname: "live.example.com",
            remotePort: 443
        )
        // Only occasional new connection entries
        if Int(demoClock) % 5 == 0 {
            aggregator.recordOpen(flow, displayName: top.displayName, route: top.route)
        }
        aggregator.recordDelta(
            flowID: flowID,
            app: top.app,
            up: UInt64.random(in: 8_000...40_000),
            down: UInt64.random(in: 40_000...200_000),
            route: top.route
        )
    }
}
