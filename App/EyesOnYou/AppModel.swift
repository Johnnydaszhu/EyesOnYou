import Foundation
import Combine
import SwiftUI
import AppKit
import ServiceManagement
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouIPC
import EyesOnYouProxyCore
import EyesOnYouStorage

private let unattributedTrafficApp = AppIdentityKey(
    teamIdentifier: nil,
    signingIdentifier: "com.example.EyesOnYou.unattributed"
)
private let unattributedTrafficFlowID = UUID(
    uuidString: "E505A115-0000-4000-8000-000000000001"
)!

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
    @Published var alertsEnabled: Bool = true {
        didSet {
            guard alertsEnabled != oldValue else { return }
            UserDefaults.standard.set(alertsEnabled, forKey: Self.alertsEnabledKey)
            if alertsEnabled { alertCenter.requestAuthorization() }
        }
    }

    /// Budgets that raise an alert. Persisted; `0` disables a check.
    @Published var alertThresholds: TrafficAlertThresholds = .default {
        didSet {
            guard alertThresholds != oldValue else { return }
            if let data = try? JSONEncoder().encode(alertThresholds) {
                UserDefaults.standard.set(data, forKey: Self.alertThresholdsKey)
            }
        }
    }

    /// Drives the one-time first-run explanation of foreground window labeling.
    @Published var showsForegroundLabelingOnboarding = false
    @Published var isRunning: Bool = true

    @Published var rateDownBps: Double = 0
    @Published var rateUpBps: Double = 0
    /// Live rates split by path (direct vs any proxy). iStat-style header/menu bar.
    @Published var directDownBps: Double = 0
    @Published var directUpBps: Double = 0
    @Published var proxyDownBps: Double = 0
    @Published var proxyUpBps: Double = 0
    /// Host bytes whose app or route could not be established from socket evidence.
    @Published var unattributedDownBps: Double = 0
    @Published var unattributedUpBps: Double = 0
    /// Share of total bandwidth on each known path (0...1). The remainder is unattributed.
    @Published var directShare: Double = 1
    @Published var proxyShare: Double = 0
    @Published var topApps: [AppTrafficSnapshot] = []
    @Published var liveConnections: [LiveConnection] = []
    /// Unified ranking rows for Overview bento (traffic + route + group + status).
    @Published var rankingRows: [AppRankingRow] = []
    /// DaisyDisk-style sunburst root (apps → optional sites).
    @Published var sunburstRoot: SunburstNode = .empty
    /// Shared hover id between sunburst and ranking table (`AppRankingRow.id` / node.id).
    @Published var hoverNodeID: String? = nil
    /// Ranking-row hover that temporarily filters the pie to that app's destinations.
    /// Separate from `hoverNodeID` so pie pointer moves don't cancel the preview.
    @Published var rankingHoverFilterID: String? = nil
    /// Row id the pie pointer is over (see ``setPieHoverRow(_:)``).
    @Published private(set) var pieHoverRowID: String? = nil
    /// Dwell before a hovered row swaps the pie into its destinations.
    private var rankingHoverFilterDwell: Task<Void, Never>? = nil
    /// Row the dwell above is waiting on, so a row exit only cancels its own dwell.
    private var rankingHoverFilterPendingID: String? = nil
    /// Drill-down path of node ids; empty = top-level apps.
    @Published var sunburstPath: [String] = []
    @Published var routeMix: RouteMix = RouteMix()
    /// Live macOS system HTTP/HTTPS/SOCKS/PAC settings (e.g. Shadowrocket “系统代理”).
    @Published var systemProxy: SystemProxySnapshot = .inactive
    /// Dominant remote IP of the local system-proxy process (node / uplink), not 127.0.0.1.
    @Published var systemProxyNodeIP: String? = nil
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
    @Published var sparklineRouteUnknown: [Double] = []
    /// Cumulative traffic trend for the network card (upload / download), rolling samples.
    @Published var periodTrendDown: [Double] = []
    @Published var periodTrendUp: [Double] = []
    private static let cumulativeTrendLimit = 40
    /// Identity of the series currently feeding `periodTrend*` (reset on period / app change).
    private var cumulativeTrendScopeKey: String = ""

    /// Selected ranking app; nil = all apps. Filters totals / live / proxy cards with time range.
    @Published var selectedApp: AppIdentityKey? = nil
    /// Show archived apps panel (from ranking search-bar archive icon).
    @Published var isArchivePanelPresented: Bool = false

    /// Overview totals time range (presets + custom). Persisted across launches;
    /// first run starts on `.today`.
    @Published var overviewPeriod: OverviewPeriod = AppModel.restoredOverviewPeriod() {
        didSet {
            UserDefaults.standard.set(overviewPeriod.rawValue, forKey: Self.overviewPeriodKey)
            refreshPublishedState()
        }
    }
    /// Inclusive start for `.custom` (wall clock). Persisted with the period.
    @Published var customRangeStart: Date = AppModel.restoredCustomRangeStart() {
        didSet {
            UserDefaults.standard.set(customRangeStart.timeIntervalSince1970, forKey: Self.customRangeStartKey)
            if overviewPeriod == .custom { refreshPublishedState() }
        }
    }
    /// Inclusive end for `.custom`. Persisted with the period.
    @Published var customRangeEnd: Date = AppModel.restoredCustomRangeEnd() {
        didSet {
            UserDefaults.standard.set(customRangeEnd.timeIntervalSince1970, forKey: Self.customRangeEndKey)
            if overviewPeriod == .custom { refreshPublishedState() }
        }
    }
    /// Resolved range used by totals / ranking (for UI caption).
    @Published private(set) var periodRangeStart: Date = Date()
    @Published private(set) var periodRangeEnd: Date = Date()

    /// A coarse clock, published so relative "last seen" labels keep counting up.
    ///
    /// Nothing reads this value — publishing it *is* its job. The ranking renders
    /// `relativeTrafficTime`, which derives its text from the wall clock rather than
    /// from any published property. Every other write is gated on the value actually
    /// changing, so an idle machine produces no `objectWillChange` at all and those
    /// labels would freeze at whatever they said when traffic stopped. A row whose
    /// label changes faster than this interval is a row with live traffic, and that
    /// republishes on its own.
    @Published private(set) var relativeTimeEpoch: Int = 0
    private static let relativeTimeEpochInterval: TimeInterval = 5
    /// Network totals for the selected overview period.
    @Published var periodNetworkUp: UInt64 = 0
    @Published var periodNetworkDown: UInt64 = 0
    @Published var periodDirectUp: UInt64 = 0
    @Published var periodDirectDown: UInt64 = 0
    @Published var periodProxyUp: UInt64 = 0
    @Published var periodProxyDown: UInt64 = 0
    @Published var periodUnattributedUp: UInt64 = 0
    @Published var periodUnattributedDown: UInt64 = 0
    /// The selected period began before this monitoring process, so it may contain gaps.
    @Published private(set) var periodMayBeIncomplete = false

    /// Login-item state. Keeping the app running is required for continuous host totals.
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginError: String?
    @Published var rules: [NetworkPolicyRule] = []
    @Published var groups: [AppGroup] = []
    @Published var proxyProfiles: [ProxyProfile] = [] {
        didSet {
            if proxyProfiles != oldValue { policyArchiveDirty = true }
        }
    }
    @Published var historyRange: HistoryRange = .day
    @Published var historyRows: [AppTrafficSnapshot] = []

    // MARK: Favorites, archive & global search

    /// Favorited app storage keys (`AppIdentityKey.storageKey`); pinned to ranking top.
    @Published private(set) var favoriteKeys: Set<String> = []
    /// Archived apps — hidden from main ranking (viewable via archive panel).
    @Published private(set) var archivedKeys: Set<String> = []
    /// Snapshot of archived ranking rows for the archive panel (includes zero-traffic).
    @Published private(set) var archivedRankingRows: [AppRankingRow] = []

    @Published var searchQuery: String = "" {
        didSet { recomputeSearchResults() }
    }
    @Published var isSearchPresented: Bool = false
    @Published private(set) var searchResults: [SearchHit] = []
    /// Ranking filter query (supports combined tokens; see `RankingQuery`).
    @Published var rankingFilterQuery: String = ""

    // Bounded retention: this aggregator ingests for as long as the app runs, and
    // one-second buckets only ever back live rates and sub-two-minute ranges.
    let aggregator = TelemetryAggregator(retention: .live)
    private var cachedOverviewRollup: TrafficOverviewRollup?
    private var cachedOverviewRollupScope: String?
    private var overviewRollupInFlight = false
    let policyStore = PolicyStore()
    /// Host-wide interface sampler — fills live rates when NE telemetry is empty.
    private let hostNetworkSampler = HostNetworkSampler()
    private let monitoringStartedAt = Date()
    /// Latest `lsof` socket sample (filled off the main thread).
    private var cachedSocketSnapshot = ActiveSocketSnapshot()
    private var cachedSocketSnapshotAt: Date?
    /// Process and project attribution for the same socket sample.
    ///
    /// Workspace fallback can walk session directories, so it must stay off the
    /// main actor with the rest of socket collection.
    private var cachedAttributedSocketProcesses: [AttributedProcess] = []
    private var socketSampleInFlight = false
    private struct SyntheticSocketFlow {
        let id: UUID
        let app: AppIdentityKey
        let route: RouteAction
    }
    /// Synthetic flows that still have matching live socket evidence.
    private var socketActiveFlows: [String: SyntheticSocketFlow] = [:]
    /// Stable flow IDs for socket-fallback deltas (one per app + route).
    private var socketFlowIDs: [String: UUID] = [:]
    /// Last observed route per app from socket attribution (direct vs system proxy).
    private var socketObservedRoute: [String: RouteAction] = [:]
    /// Cached DIRECT destination index from local proxy clients (Clash / Shadowrocket / …).
    private var directDestinationIndex = DirectDestinationIndex.empty
    private var directIndexLoadedAt: Date? = nil
    private var directIndexLoadInFlight = false
    /// Set once the local proxy config could not be read, to avoid re-prompting.
    private var directIndexUnavailable = false
    /// Maps a socket-holding process to the project it is working in, so agent / IDE
    /// traffic drills into real sub-projects instead of a static guess.
    /// SQLite telemetry, shared with the CLI. `nil` when the database could not be
    /// opened — the app keeps working live, it just cannot persist.
    private var telemetryStore: TelemetryStore?
    private var telemetryFlusher: TelemetryFlusher?
    private var lastPruneAt: Date?
    private var lastFlushAttemptAt: Date?
    private var lastPruneAttemptAt: Date?
    private let telemetryPersistenceQueue = DispatchQueue(
        label: "EyesOnYou.TelemetryPersistence",
        qos: .utility
    )
    private var telemetryFlushInFlight = false
    private var telemetryPruneInFlight = false
    /// Buckets reloaded from disk at launch, reported by `storageSummary`.
    private var restoredBucketCount = 0
    /// Last persistence failure, surfaced in Settings rather than swallowed.
    @Published private(set) var storageError: String?
    /// Policy generation already written to disk, so edits persist without every
    /// mutating method having to remember to call `savePolicies()`.
    private var lastPersistedPolicyGeneration: UInt64?
    private var policyArchiveDirty = false
    /// Focused-tab reader for browser drill-down labels (opt-in; see `tracksBrowserTabs`).
    private let browserTabSampler = BrowserTabSampler()
    /// Foreground window reader, so apps whose only signal is the window title
    /// (Claude, GitHub Desktop, Xcode …) still get meaningful sub-rows.
    private lazy var foregroundSampler = ForegroundWindowSampler(browserSampler: browserTabSampler)
    private var cancellables: Set<AnyCancellable> = []
    /// Traffic budget / anomaly detection (see `TrafficAlertEngine`).
    private let alertEngine: TrafficAlertEngine
    let alertCenter = AlertCenter()
    private var lastAlertEvaluation: Date?
    private var cumulativeAlertTotals: [AppIdentityKey: UInt64] = [:]
    private var cumulativeAlertRefreshAt: Date?
    private var cumulativeAlertRefreshInFlight = false
    private var cumulativeAlertGeneration: UInt64 = 0
    private let projectResolver = ProjectResolver()
    private lazy var attributionResolver = LiveAttributionResolver(
        projectResolver: projectResolver,
        // Session discovery walks large on-disk histories. The GUI refreshes that
        // index independently, so the live socket sampler must never wait for it.
        usesSessionFallback: false
    )
    private var workspacesRefreshedAt: Date? = nil
    private var workspaceRefreshInFlight = false
    /// Reverse-DNS cache for proxy egress IPs.
    private var reverseDNSCache: [String: String] = [:]
    /// Successful and failed lookups are both throttled. DNS APIs are blocking on
    /// macOS, so they must never hold up the next socket snapshot.
    private var reverseDNSAttemptedAt: [String: Date] = [:]
    private let reverseDNSQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "EyesOnYou.ReverseDNS"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var tickTimer: Timer?
    /// Rolling live rate (down+up) history keyed by `AppIdentityKey.storageKey`.
    /// Per-app cumulative network totals history for ranking traffic-trend sparklines.
    private var appRateHistory: [String: [Double]] = [:]
    private static let appRateHistoryLimit = 28
    private static let favoritesDefaultsKey = "eyesonyou.favoriteAppKeys"
    private static let overviewPeriodKey = "eyesonyou.overviewPeriod"
    private static let customRangeStartKey = "eyesonyou.customRangeStart"
    private static let customRangeEndKey = "eyesonyou.customRangeEnd"
    private static let browserTabTrackingKey = "eyesonyou.trackBrowserTabs"
    private static let alertsEnabledKey = "eyesonyou.alertsEnabled"
    private static let alertThresholdsKey = "eyesonyou.alertThresholds"
    private static let alertStateKey = "eyesonyou.alertState"
    private static let onboardingShownKey = "eyesonyou.foregroundOnboardingShown"
    /// Seconds between telemetry flushes. Minute buckets are the finest thing
    /// persisted, so anything under a minute only costs writes.
    private static let telemetryFlushInterval: TimeInterval = 30
    private static let telemetryPruneInterval: TimeInterval = 6 * 3600

    /// Shared with the CLI — this app is not sandboxed, so both see one database.
    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("EyesOnYou", isDirectory: true)
    }

    static var telemetryDatabaseURL: URL {
        supportDirectory.appendingPathComponent("telemetry.sqlite")
    }
    private static let archivedDefaultsKey = "eyesonyou.archivedAppKeys"
    /// How many apps to materialize into the ranking table.
    private static let rankingLimit = 64
    /// Rows in the history table. Must not exceed `rankingLimit`, which it is sliced from.
    private static let historyLimit = 50

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

    private static let menuBarStyleKey = "eyesonyou.menuBarDisplayStyle"
    private static let rankingColumnSpacingKey = "eyesonyou.rankingColumnSpacing"
    private static let rankingHiddenColumnsKey = "eyesonyou.rankingHiddenColumns"
    private static let rankingSortKeyKey = "eyesonyou.rankingSortKey"
    private static let rankingSortAscendingKey = "eyesonyou.rankingSortAscending"
    private static let appearanceModeKey = "eyesonyou.appearanceMode"
    private static let colorThemeTemplateKey = "eyesonyou.colorThemeTemplate"
    private static let themeAccentsKey = "eyesonyou.themeAccents"

    /// Optional ranking table columns the user can hide via header context menu.
    enum RankingColumnID: String, CaseIterable, Identifiable, Sendable {
        case down
        case up
        case trend
        case lastSeen
        case requests
        case egress
        case online

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .down: return "overview.colDown"
            case .up: return "overview.colUp"
            case .trend: return "overview.colTrend"
            case .lastSeen: return "overview.colLastSeen"
            case .requests: return "overview.colRequests"
            case .egress: return "overview.colEgress"
            case .online: return "overview.colOnline"
            }
        }
    }

    /// Column the ranking table is sorted by. `nil` = default order (pins first, then
    /// measured bytes), which is what the `#` header restores.
    enum RankingSortKey: String, CaseIterable, Sendable {
        case name
        case down
        case up
        case trend
        case lastSeen
        case requests
        case egress
        case online

        /// Names read best A→Z; every measured column reads best biggest-first.
        var startsAscending: Bool { self == .name }
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

    /// Label browser traffic rows with the page seen on that host.
    ///
    /// Off by default: it is the only feature that reads what the user is looking at.
    /// Turning it on also needs macOS Accessibility trust — see ``BrowserTabSampler``
    /// for the host-and-title-only, memory-only contract it keeps.
    @Published var tracksBrowserTabs: Bool = false {
        didSet {
            guard tracksBrowserTabs != oldValue else { return }
            UserDefaults.standard.set(tracksBrowserTabs, forKey: Self.browserTabTrackingKey)
            if tracksBrowserTabs {
                BrowserTabSampler.requestAccessibilityPermission()
            } else {
                foregroundSampler.reset()
            }
        }
    }

    /// True once the user has granted Accessibility access; drives the settings hint.
    var isBrowserTabTrackingAuthorized: Bool {
        BrowserTabSampler.isAccessibilityTrusted
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

    /// Header-click sort column; `nil` keeps the default order. Persisted.
    @Published private(set) var rankingSortKey: RankingSortKey? = nil
    /// Direction of ``rankingSortKey`` — `true` ascending. Persisted.
    @Published private(set) var rankingSortAscending: Bool = false

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

    // MARK: - Persisted overview period

    /// Last selected overview period, or `.today` on first run / unknown value.
    ///
    /// Read from a property initializer so restoring the choice does not fire `didSet`
    /// and kick off a `refreshPublishedState()` before the telemetry store is open.
    private static func restoredOverviewPeriod() -> OverviewPeriod {
        guard let raw = UserDefaults.standard.string(forKey: overviewPeriodKey),
              let period = OverviewPeriod(rawValue: raw)
        else { return .today }
        return period
    }

    private static func restoredCustomRangeStart() -> Date {
        if let stored = UserDefaults.standard.object(forKey: customRangeStartKey) as? TimeInterval {
            return Date(timeIntervalSince1970: stored)
        }
        return Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    }

    private static func restoredCustomRangeEnd() -> Date {
        if let stored = UserDefaults.standard.object(forKey: customRangeEndKey) as? TimeInterval {
            return Date(timeIntervalSince1970: stored)
        }
        return Date()
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

    // MARK: - Ranking sort

    /// Header click cycles: default order → the column's natural direction → reversed → default.
    func cycleRankingSort(_ key: RankingSortKey) {
        if rankingSortKey != key {
            rankingSortKey = key
            rankingSortAscending = key.startsAscending
        } else if rankingSortAscending == key.startsAscending {
            rankingSortAscending = !key.startsAscending
        } else {
            rankingSortKey = nil
            rankingSortAscending = false
        }
        persistRankingSort()
    }

    func clearRankingSort() {
        guard rankingSortKey != nil else { return }
        rankingSortKey = nil
        rankingSortAscending = false
        persistRankingSort()
    }

    /// `true` ascending / `false` descending while this column drives the sort; `nil` otherwise.
    func rankingSortDirection(for key: RankingSortKey) -> Bool? {
        rankingSortKey == key ? rankingSortAscending : nil
    }

    private func persistRankingSort() {
        let defaults = UserDefaults.standard
        if let key = rankingSortKey {
            defaults.set(key.rawValue, forKey: Self.rankingSortKeyKey)
            defaults.set(rankingSortAscending, forKey: Self.rankingSortAscendingKey)
        } else {
            defaults.removeObject(forKey: Self.rankingSortKeyKey)
            defaults.removeObject(forKey: Self.rankingSortAscendingKey)
        }
    }

    /// Apply the header sort. Pinned apps stay on top so a pin is never lost in a sort.
    func sortedRankingRows(_ rows: [AppRankingRow]) -> [AppRankingRow] {
        guard let key = rankingSortKey else { return rows }
        let ascending = rankingSortAscending
        return rows.sorted { a, b in
            let af = favoriteKeys.contains(a.snapshot.app.storageKey)
            let bf = favoriteKeys.contains(b.snapshot.app.storageKey)
            if af != bf { return af && !bf }
            switch Self.compareRankingRows(a, b, key: key) {
            case .orderedAscending:
                return ascending
            case .orderedDescending:
                return !ascending
            case .orderedSame:
                return a.snapshot.displayName
                    .localizedCaseInsensitiveCompare(b.snapshot.displayName) == .orderedAscending
            }
        }
    }

    private static func compareRankingRows(
        _ a: AppRankingRow,
        _ b: AppRankingRow,
        key: RankingSortKey
    ) -> ComparisonResult {
        switch key {
        case .name:
            return a.snapshot.displayName.localizedCaseInsensitiveCompare(b.snapshot.displayName)
        case .down:
            return order(a.snapshot.totals.bytesDown, b.snapshot.totals.bytesDown)
        case .up:
            return order(a.snapshot.totals.bytesUp, b.snapshot.totals.bytesUp)
        case .trend:
            return order(trendDelta(a), trendDelta(b))
        case .lastSeen:
            // Never-seen rows sort below every measured timestamp.
            return order(
                a.lastTrafficAt?.timeIntervalSince1970 ?? -1,
                b.lastTrafficAt?.timeIntervalSince1970 ?? -1
            )
        case .requests:
            return order(a.snapshot.totals.flowsOpened, b.snapshot.totals.flowsOpened)
        case .egress:
            // No bytes in range (`nil` share) sorts below every measured path.
            return order(a.proxyShare ?? -1, b.proxyShare ?? -1)
        case .online:
            let state = order(onlineRank(a), onlineRank(b))
            if state != .orderedSame { return state }
            return order(a.snapshot.activeConnections, b.snapshot.activeConnections)
        }
    }

    private static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        if a == b { return .orderedSame }
        return a < b ? .orderedAscending : .orderedDescending
    }

    /// Latest measured growth of the cumulative series the trend column draws — the
    /// sparkline's own last step, not a synthesized rate.
    private static func trendDelta(_ row: AppRankingRow) -> Double {
        let series = row.rateSeries
        guard series.count >= 2 else { return 0 }
        return max(0, series[series.count - 1] - series[series.count - 2])
    }

    private static func onlineRank(_ row: AppRankingRow) -> Int {
        switch row.onlineState {
        case .active: return 2
        case .idle: return 1
        case .noTraffic: return 0
        }
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
    private static let lastUpdateCheckKey = "eyesonyou.lastUpdateCheckAt"

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
        let groupName: String?
        /// Share of network total (0...1) for pie chart.
        let share: Double
        /// Fraction of this row's bytes that went through a proxy (0...1);
        /// `nil` when no bytes were recorded in the period.
        let proxyShare: Double?
        /// Last wall-clock time this app recorded traffic.
        let lastTrafficAt: Date?
        /// Cumulative network traffic trend (total bytes over recent ticks).
        let rateSeries: [Double]

        init(
            id: String? = nil,
            snapshot: AppTrafficSnapshot,
            groupName: String?,
            share: Double,
            proxyShare: Double? = nil,
            lastTrafficAt: Date? = nil,
            rateSeries: [Double] = []
        ) {
            self.id = id ?? snapshot.id
            self.snapshot = snapshot
            self.groupName = groupName
            self.share = share
            self.proxyShare = proxyShare
            self.lastTrafficAt = lastTrafficAt
            self.rateSeries = rateSeries
        }

        /// Where this row's bytes actually left the machine, measured — never an intent.
        var observedEgress: ObservedEgress {
            if snapshot.app == unattributedTrafficApp { return .unattributed }
            guard let share = proxyShare else { return .noTraffic }
            if share <= 0.005 { return .direct }
            if share >= 0.995 { return .proxy }
            return .mixed(proxyShare: share)
        }

        /// Whether the app is holding connections right now, from the socket sample.
        var onlineState: OnlineState {
            if snapshot.activeConnections > 0 {
                return .active(connections: snapshot.activeConnections)
            }
            return lastTrafficAt == nil ? .noTraffic : .idle
        }
    }

    /// Measured egress path for a ranking row. Derived from recorded bytes only:
    /// there is no "what this app is configured to do" here, by design.
    enum ObservedEgress: Equatable {
        /// No bytes recorded in the selected period.
        case noTraffic
        /// Every recorded byte left without passing a local proxy client.
        case direct
        /// Every recorded byte went through a local proxy client.
        case proxy
        /// Both paths carried bytes; the associated value is the proxied fraction.
        case mixed(proxyShare: Double)
        /// Host bytes were preserved, but socket evidence could not establish the path.
        case unattributed
    }

    /// Live connection state for a ranking row.
    enum OnlineState: Equatable {
        /// Holding at least one established socket at this moment.
        case active(connections: Int)
        /// Moved bytes in the period but holds nothing right now.
        case idle
        /// No traffic recorded in the period at all.
        case noTraffic
    }

    /// Hierarchical node for DaisyDisk-style sunburst.
    struct SunburstNode: Identifiable, Equatable {
        let id: String
        let title: String
        let value: UInt64
        /// Slot in the theme's categorical chart palette (app rank).
        let colorIndex: Int
        /// Sibling offset inside one app (destinations) — a tonal step off the same slot.
        let colorVariant: Int
        var children: [SunburstNode]

        static let empty = SunburstNode(id: "root", title: "Root", value: 0, colorIndex: 0, colorVariant: 0, children: [])

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

    /// Row hover highlights the matching pie segment immediately; the deeper
    /// destination preview only takes over after the pointer rests on the row, so
    /// crossing the table no longer strobes the chart.
    func scheduleRankingHoverFilter(_ id: String?, delay: TimeInterval = 0.55) {
        rankingHoverFilterDwell?.cancel()
        rankingHoverFilterDwell = nil
        rankingHoverFilterPendingID = id
        guard let id else {
            setRankingHoverFilter(nil)
            return
        }
        rankingHoverFilterDwell = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.hoverNodeID == id else { return }
            self.setRankingHoverFilter(id)
        }
    }

    /// Row exit. Scoped to the leaving row so pointer travel between adjacent rows
    /// does not cancel the row it just entered.
    func clearRankingHoverFilter(ifMatching id: String) {
        guard rankingHoverFilterPendingID == id || rankingHoverFilterID == id else { return }
        scheduleRankingHoverFilter(nil)
    }

    /// Ranking row the pie pointer is over, so the table can scroll that row into
    /// view and highlight the same segment. Set by the chart only — never by the table,
    /// which would make the two cards chase each other.
    func setPieHoverRow(_ id: String?) {
        if pieHoverRowID != id { pieHoverRowID = id }
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
            pieHoverRowID = nil
        }
    }

    func sunburstGoBack() {
        guard !sunburstPath.isEmpty else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            _ = sunburstPath.popLast()
            hoverNodeID = nil
            rankingHoverFilterID = nil
            pieHoverRowID = nil
        }
    }

    func sunburstReset() {
        guard !sunburstPath.isEmpty else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            sunburstPath.removeAll()
            hoverNodeID = nil
            rankingHoverFilterID = nil
            pieHoverRowID = nil
        }
    }

    init() {
        // Alert engine is restored before anything can evaluate, so a restart never
        // replays budgets the user has already been told about.
        let restoredAlertState: TrafficAlertState = {
            guard let data = UserDefaults.standard.data(forKey: Self.alertStateKey),
                  let decoded = try? JSONDecoder().decode(TrafficAlertState.self, from: data)
            else { return TrafficAlertState() }
            return decoded
        }()
        alertEngine = TrafficAlertEngine(state: restoredAlertState)

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
        if let raw = UserDefaults.standard.string(forKey: Self.rankingSortKeyKey),
           let key = RankingSortKey(rawValue: raw) {
            rankingSortKey = key
            rankingSortAscending = UserDefaults.standard.bool(forKey: Self.rankingSortAscendingKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.appearanceModeKey),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        // Only honour a stored opt-in while Accessibility trust still stands; the user
        // can revoke it in System Settings without coming back here.
        // Restore the user's choice as stated, not as currently permitted. ANDing this
        // with live Accessibility trust silently flipped the switch off whenever the
        // grant lapsed — after every rebuild, in practice — so the setting appeared to
        // undo itself. Trust is enforced where sampling happens; the settings row
        // shows a warning when it is missing.
        tracksBrowserTabs = UserDefaults.standard.bool(forKey: Self.browserTabTrackingKey)
        Self.applyAppearance(appearanceMode)
        loadColorThemePreferences()
        applyColorTheme()
        loadFavorites()
        loadArchived()
        loadPersistedPolicies()
        openTelemetryStore()
        restorePersistedTelemetry()
        loadAlertPreferences()
        refreshLaunchAtLoginState()
        refreshPublishedState()
        startTicker()
        scheduleInitialUpdateCheck()
    }

    // MARK: - Traffic alerts

    private func loadAlertPreferences() {
        if UserDefaults.standard.object(forKey: Self.alertsEnabledKey) != nil {
            alertsEnabled = UserDefaults.standard.bool(forKey: Self.alertsEnabledKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.alertThresholdsKey),
           let decoded = try? JSONDecoder().decode(TrafficAlertThresholds.self, from: data) {
            alertThresholds = decoded
        }
        alertCenter.refreshAuthorization()

        // Apps already in the catalog are not "new"; without this the first launch
        // after enabling first-seen alerts would announce everything at once.
        if let names = try? telemetryStore?.displayNames() {
            alertEngine.seedKnownApps(Array(names.keys))
        }

        // Offer the foreground-labeling explanation once, and only when it is not
        // already on — an existing user should never see it.
        if !UserDefaults.standard.bool(forKey: Self.onboardingShownKey), !tracksBrowserTabs {
            showsForegroundLabelingOnboarding = true
        }
    }

    /// Record that the first-run explanation was answered, whichever way.
    func completeForegroundLabelingOnboarding(enable: Bool) {
        UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
        showsForegroundLabelingOnboarding = false
        if enable {
            tracksBrowserTabs = true
        }
    }

    /// Check budgets. Cheap enough per tick, but the aggregate scan is throttled.
    private func evaluateAlertsIfDue(now: Date) {
        guard alertsEnabled else { return }
        if let last = lastAlertEvaluation, now.timeIntervalSince(last) < 5 { return }
        lastAlertEvaluation = now

        // A daily budget resets at the user's local midnight. A rolling 24-hour
        // window made the same "today" budget drift throughout the day.
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: now)
        let dailyTotals = aggregator.topApps(from: dayStart, to: now, limit: 200,
                                             includeSitesForBrowsers: false)
        let dailyTotalBytes = dailyTotals.reduce(UInt64(0)) {
            $0 &+ $1.totals.totalBytes
        }
        let alertableDailyTotals = dailyTotals.filter {
            $0.app != unattributedTrafficApp
        }
        let dailyByApp = Dictionary(
            alertableDailyTotals.map { ($0.app, $0.totals.totalBytes) },
            uniquingKeysWith: { a, _ in a }
        )
        let names = Dictionary(
            alertableDailyTotals.map { ($0.app, $0.displayName) },
            uniquingKeysWith: { a, _ in a }
        )
        let burstStart = now.addingTimeInterval(-alertThresholds.burstWindow)
        let burstByApp = Dictionary(
            aggregator.topApps(from: burstStart, to: now, limit: 200,
                               includeSitesForBrowsers: false)
                .filter { $0.app != unattributedTrafficApp }
                .map { ($0.app, $0.totals.totalBytes) },
            uniquingKeysWith: { a, _ in a }
        )

        // Cumulative comes from storage: it is the whole recorded history, which the
        // in-memory aggregator only holds a window of.
        if alertThresholds.cumulativeAppBytes > 0 {
            refreshCumulativeAlertTotalsIfNeeded(now: now)
        }

        let input = TrafficAlertInput(
            now: now,
            dailyTotalBytes: dailyTotalBytes,
            dailyByApp: dailyByApp,
            cumulativeByApp: cumulativeAlertTotals,
            burstByApp: burstByApp,
            displayNames: names
        )
        let alerts = alertEngine.evaluate(input, thresholds: alertThresholds)
        if !alerts.isEmpty {
            alertCenter.deliver(alerts, localization: LocalizationStore.shared)
            persistAlertState()
        }
    }

    private func refreshCumulativeAlertTotalsIfNeeded(now: Date) {
        guard let store = telemetryStore, !cumulativeAlertRefreshInFlight else { return }
        if let refreshed = cumulativeAlertRefreshAt,
           now.timeIntervalSince(refreshed) < 60 {
            return
        }
        cumulativeAlertRefreshInFlight = true
        let generation = cumulativeAlertGeneration
        telemetryPersistenceQueue.async {
            let result = Result {
                try store.queryTopApps(
                    granularity: .oneDay,
                    from: Date(timeIntervalSince1970: 0),
                    to: now.addingTimeInterval(86_400),
                    limit: 200
                )
            }
            Task { @MainActor in
                self.cumulativeAlertRefreshInFlight = false
                guard generation == self.cumulativeAlertGeneration else { return }
                guard case .success(let rows) = result else { return }
                self.cumulativeAlertTotals = Dictionary(
                    rows
                        .filter { $0.0 != unattributedTrafficApp }
                        .map { ($0.0, $0.2.totalBytes) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.cumulativeAlertRefreshAt = now
            }
        }
    }

    private func persistAlertState() {
        if let data = try? JSONEncoder().encode(alertEngine.currentState) {
            UserDefaults.standard.set(data, forKey: Self.alertStateKey)
        }
    }

    // MARK: - Persistence

    /// Open the shared telemetry database, creating it on first launch.
    ///
    /// A failure here is not fatal: the app still samples and displays live traffic,
    /// it just cannot carry it across restarts. `storageError` surfaces that instead
    /// of failing silently.
    private func openTelemetryStore() {
        do {
            try FileManager.default.createDirectory(
                at: Self.supportDirectory,
                withIntermediateDirectories: true
            )
            let store = try TelemetryStore(path: Self.telemetryDatabaseURL.path)
            telemetryStore = store
            telemetryFlusher = TelemetryFlusher(store: store)
        } catch {
            telemetryStore = nil
            telemetryFlusher = nil
            storageError = "\(error)"
        }
    }

    /// Load recent history back into the aggregator so period totals, charts, and
    /// project rows survive a restart.
    private func restorePersistedTelemetry() {
        guard let store = telemetryStore else { return }
        let now = Date()
        do {
            var restored: [TrafficBucket] = []
            for granularity in TelemetryFlusher.persistedGranularities {
                let window = Self.restoreWindow(for: granularity)
                restored += try store.loadBuckets(
                    granularity: granularity,
                    from: now.addingTimeInterval(-window),
                    // One bucket past `now` so the in-progress bucket comes back too.
                    to: now.addingTimeInterval(Double(granularity.seconds))
                )
            }
            aggregator.importBuckets(restored)
            aggregator.importDisplayNames(try store.displayNames())
            // The flusher must know these bytes are already on disk, or the next
            // flush would write the restored history a second time.
            telemetryFlusher?.seed(with: restored)
            restoredBucketCount = restored.count
        } catch {
            storageError = "\(error)"
        }
        pruneTelemetry(now: now)
    }

    /// How far back to reload per granularity — enough for every dashboard range
    /// without pulling years of day rows into memory.
    ///
    /// Must not exceed `BucketRetention.live`, or the restore would load buckets the
    /// aggregator immediately evicts.
    private static func restoreWindow(for granularity: BucketGranularity) -> TimeInterval {
        switch granularity {
        case .oneSecond: return 0
        case .oneMinute: return 2 * 86_400
        case .oneHour: return 3 * 86_400
        case .oneDay: return 3 * 365 * 86_400
        }
    }

    /// Write everything recorded since the last flush.
    private func flushTelemetry(now: Date = Date()) {
        guard let flusher = telemetryFlusher, !telemetryFlushInFlight else { return }
        telemetryFlushInFlight = true
        lastFlushAttemptAt = now
        let aggregator = aggregator
        telemetryPersistenceQueue.async {
            let result = Result { try flusher.flush(aggregator) }
            Task { @MainActor in
                self.telemetryFlushInFlight = false
                switch result {
                case .success:
                    self.storageError = nil
                case .failure(let error):
                    self.storageError = "\(error)"
                }
            }
        }
    }

    /// Apply retention so the database cannot grow without bound.
    private func pruneTelemetry(now: Date) {
        guard let store = telemetryStore, !telemetryPruneInFlight else { return }
        telemetryPruneInFlight = true
        lastPruneAttemptAt = now
        let flusher = telemetryFlusher
        let aggregator = aggregator
        telemetryPersistenceQueue.async {
            let result = Result {
                try store.prune(
                    granularity: .oneMinute,
                    olderThan: now.addingTimeInterval(-7 * 86_400)
                )
                try store.prune(
                    granularity: .oneHour,
                    olderThan: now.addingTimeInterval(-365 * 86_400)
                )
                try store.prune(
                    granularity: .oneDay,
                    olderThan: now.addingTimeInterval(-3 * 365 * 86_400)
                )
                try store.pruneOrphanedApps()
                flusher?.forgetWatermarks(notPresentIn: aggregator)
            }
            Task { @MainActor in
                self.telemetryPruneInFlight = false
                switch result {
                case .success:
                    self.lastPruneAt = now
                    self.alertEngine.pruneState(now: now)
                    self.persistAlertState()
                    self.storageError = nil
                case .failure(let error):
                    self.storageError = "\(error)"
                }
            }
        }
    }

    /// Flush before the app exits so the final minute is not lost.
    func persistBeforeTermination() {
        if let flusher = telemetryFlusher {
            let aggregator = aggregator
            telemetryPersistenceQueue.sync {
                do {
                    try flusher.flush(aggregator)
                } catch {
                    NSLog("EyesOnYou telemetry final flush failed: \(error)")
                }
            }
        }
        savePoliciesIfChanged()
    }

    private func loadPersistedPolicies() {
        do {
            guard let archive = try PolicyArchiveStore.load() else {
                lastPersistedPolicyGeneration = policyStore.currentGeneration
                return
            }
            archive.apply(to: policyStore)
            proxyProfiles = archive.proxyProfiles
        } catch {
            storageError = "\(error)"
        }
        lastPersistedPolicyGeneration = policyStore.currentGeneration
        policyArchiveDirty = false
    }

    /// Persist configuration when it actually changed.
    ///
    /// Driven by `PolicyStore.currentGeneration` rather than by each call site, so a
    /// new mutating method cannot silently stop saving.
    private func savePoliciesIfChanged() {
        let generation = policyStore.currentGeneration
        guard policyArchiveDirty || lastPersistedPolicyGeneration != generation else { return }
        let archive = PolicyArchive.capture(from: policyStore, proxyProfiles: proxyProfiles)
        // Nothing configured and nothing ever saved — no reason to create a file.
        if archive.isEmpty, lastPersistedPolicyGeneration == nil || !policyArchiveDirty {
            lastPersistedPolicyGeneration = generation
            policyArchiveDirty = false
            return
        }
        do {
            try PolicyArchiveStore.save(archive)
            lastPersistedPolicyGeneration = generation
            policyArchiveDirty = false
        } catch {
            storageError = "\(error)"
        }
    }

    /// Persist user configuration. Cheap and rare — called on every policy edit.
    /// Force a configuration write regardless of generation (used by tests / imports).
    func savePolicies() {
        policyArchiveDirty = true
        savePoliciesIfChanged()
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

    // MARK: - Archive

    func isArchived(_ app: AppIdentityKey) -> Bool {
        archivedKeys.contains(app.storageKey)
    }

    func toggleArchive(_ app: AppIdentityKey) {
        let key = app.storageKey
        if archivedKeys.contains(key) {
            archivedKeys.remove(key)
        } else {
            archivedKeys.insert(key)
        }
        persistArchived()
        refreshPublishedState()
    }

    private func loadArchived() {
        if let arr = UserDefaults.standard.array(forKey: Self.archivedDefaultsKey) as? [String] {
            archivedKeys = Set(arr)
        }
    }

    private func persistArchived() {
        UserDefaults.standard.set(Array(archivedKeys).sorted(), forKey: Self.archivedDefaultsKey)
    }

    // MARK: - Combined ranking filter

    /// Parsed ranking search: free-text tokens are AND; field tokens filter columns.
    ///
    /// Both field tokens filter on *measured* state, matching what the table shows:
    /// `egress:` on the observed path, `status:` on live connections.
    /// Examples: `chrome egress:direct`, `status:online`, `egress:proxy 收藏`
    struct RankingQuery: Equatable {
        var texts: [String] = []
        /// direct / proxy / mixed — measured egress, not a rule.
        var egress: Set<String> = []
        /// online / idle — live connection state.
        var statuses: Set<String> = []
        var favoritesOnly = false
        var archivedOnly = false

        var isEmpty: Bool {
            texts.isEmpty && egress.isEmpty && statuses.isEmpty
                && !favoritesOnly && !archivedOnly
        }

        static func parse(_ raw: String) -> RankingQuery {
            var q = RankingQuery()
            let parts = raw
                .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == ";" })
                .map(String.init)
                .filter { !$0.isEmpty }
            for part in parts {
                let lower = part.lowercased()
                // `route:` / `proxy:` kept as aliases so older muscle memory still works.
                if lower.hasPrefix("egress:") || lower.hasPrefix("出口:")
                    || lower.hasPrefix("route:") || lower.hasPrefix("路由:")
                    || lower.hasPrefix("proxy:") || lower.hasPrefix("代理:") {
                    let v = String(part.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    q.egress.formUnion(Self.normalizeEgressTokens(v))
                } else if lower.hasPrefix("status:") || lower.hasPrefix("状态:") {
                    let v = String(part.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    q.statuses.formUnion(Self.normalizeStatusTokens(v))
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

        private static func normalizeEgressTokens(_ v: String) -> Set<String> {
            switch v {
            case "direct", "直连", "直連", "off", "0", "false", "no", "关", "关闭":
                return ["direct"]
            case "proxy", "代理", "socks5", "system", "系统", "系統", "systemproxy",
                 "系统代理", "custom", "自定义", "自定义代理", "on", "1", "true", "yes", "开", "开启":
                return ["proxy"]
            case "mixed", "混合", "both":
                return ["mixed"]
            default:
                return [v]
            }
        }

        private static func normalizeStatusTokens(_ v: String) -> Set<String> {
            switch v {
            case "online", "active", "在线", "在線", "活跃", "活躍", "connected":
                return ["online"]
            case "idle", "offline", "空闲", "空閒", "离线", "離線":
                return ["idle"]
            default:
                return [v]
            }
        }

        func matches(row: AppRankingRow, isFavorite: Bool, isArchived: Bool) -> Bool {
            let snap = row.snapshot
            if favoritesOnly && !isFavorite { return false }
            if archivedOnly && !isArchived { return false }
            if !egress.isEmpty {
                let hit: Bool
                switch row.observedEgress {
                case .direct: hit = egress.contains("direct")
                case .proxy: hit = egress.contains("proxy")
                // Mixed rows carry bytes on both paths, so either filter should find them.
                case .mixed: hit = !egress.isDisjoint(with: ["mixed", "direct", "proxy"])
                case .noTraffic, .unattributed: hit = false
                }
                if !hit { return false }
            }
            if !statuses.isEmpty {
                let online: Bool
                if case .active = row.onlineState { online = true } else { online = false }
                let wantOnline = statuses.contains("online")
                let wantIdle = statuses.contains("idle")
                if wantOnline && !wantIdle && !online { return false }
                if wantIdle && !wantOnline && online { return false }
            }
            for t in texts {
                let name = snap.displayName.lowercased()
                let sid = snap.app.signingIdentifier.lowercased()
                if !(name.contains(t) || sid.contains(t)) {
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
                isArchived: isArchived(row.snapshot.app)
            )
        }
    }

    /// Rows shown in ranking: active or archived panel, combined filter, then header sort.
    var displayedRankingRows: [AppRankingRow] {
        let base: [AppRankingRow]
        let parsed = RankingQuery.parse(rankingFilterQuery)
        if isArchivePanelPresented || parsed.archivedOnly {
            base = archivedRankingRows
        } else {
            base = visibleRankingRows
        }
        return sortedRankingRows(filteredRankingRows(base))
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
        // `purge` removes the aggregator's active flow records. Drop the matching
        // socket-side lifecycle state as well, otherwise the next sample believes
        // those flows are still open and can later emit an unmatched close.
        let socketKeys = socketActiveFlows.compactMap { key, flow in
            flow.app == app ? key : nil
        }
        for key in socketKeys {
            socketActiveFlows.removeValue(forKey: key)
            socketFlowIDs.removeValue(forKey: key)
        }
        socketObservedRoute.removeValue(forKey: app.storageKey)
        cumulativeAlertTotals.removeValue(forKey: app)
        cumulativeAlertRefreshAt = nil
        cumulativeAlertGeneration &+= 1

        aggregator.purge(app: app)
        if let flusher = telemetryFlusher {
            let aggregator = aggregator
            telemetryPersistenceQueue.async {
                let result = Result {
                    try flusher.deleteApp(app, preservingCurrentBucketsIn: aggregator)
                }
                if case .failure(let error) = result {
                    Task { @MainActor in
                        self.storageError = "\(error)"
                    }
                }
            }
        }
        appRateHistory.removeValue(forKey: app.storageKey)
        favoriteKeys.remove(app.storageKey)
        persistFavorites()
        archivedKeys.remove(app.storageKey)
        persistArchived()
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
            // Runs on every tick; republishing an already-empty array would invalidate
            // the view tree for nothing.
            publish(\.searchResults, [])
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

        publish(\.searchResults, Array(hits.prefix(24)))
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
        refreshLaunchAtLoginState()
        SettingsWindowController.shared.show(model: self)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        launchAtLoginError = nil
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            publish(\.launchAtLoginEnabled, true)
            publish(\.launchAtLoginNeedsApproval, false)
        case .requiresApproval:
            publish(\.launchAtLoginEnabled, false)
            publish(\.launchAtLoginNeedsApproval, true)
        case .notRegistered, .notFound:
            publish(\.launchAtLoginEnabled, false)
            publish(\.launchAtLoginNeedsApproval, false)
        @unknown default:
            publish(\.launchAtLoginEnabled, false)
            publish(\.launchAtLoginNeedsApproval, false)
        }
    }

    /// Publish direction-preserving live path rates from the current one-second bucket.
    private func recomputePathRates(_ routes: RouteDirectionalTotals) {
        let proxied = routes.proxied
        publish(\.directDownBps, Double(routes.direct.bytesDown))
        publish(\.directUpBps, Double(routes.direct.bytesUp))
        publish(\.proxyDownBps, Double(proxied.bytesDown))
        publish(\.proxyUpBps, Double(proxied.bytesUp))
        publish(\.unattributedDownBps, Double(routes.unknown.bytesDown))
        publish(\.unattributedUpBps, Double(routes.unknown.bytesUp))

        let total = Double(routes.all.totalBytes)
        if total > 0 {
            publish(\.directShare, Double(routes.direct.totalBytes) / total)
            publish(\.proxyShare, Double(proxied.totalBytes) / total)
        } else {
            let direct = max(0, routeMix.directPercent) / 100
            let proxy = max(0, routeMix.systemProxyPercent + routeMix.customProxyPercent) / 100
            publish(\.directShare, direct)
            publish(\.proxyShare, proxy)
        }

        publish(\.sparklineDirect, Self.appending(sparklineDirect, directDownBps + directUpBps, limit: 40))
        publish(\.sparklineProxy, Self.appending(sparklineProxy, proxyDownBps + proxyUpBps, limit: 40))

        publish(\.sparklineRouteDirect, Self.appending(sparklineRouteDirect, routeMix.directPercent, limit: 40))
        publish(\.sparklineRouteSystem, Self.appending(sparklineRouteSystem, routeMix.systemProxyPercent, limit: 40))
        publish(\.sparklineRouteCustom, Self.appending(sparklineRouteCustom, routeMix.customProxyPercent, limit: 40))
        publish(\.sparklineRouteUnknown, Self.appending(sparklineRouteUnknown, routeMix.unknownPercent, limit: 40))
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
        if systemProxy.isEnabled, routeMix.directPercent < 100 {
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
    func openDashboard() {
        selectedTab = .overview
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == AppBrand.displayName || $0.contentView != nil }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// History table from an already-computed ranking pass.
    ///
    /// `topApps` sorts by bytes descending, so the first `historyLimit` rows of the
    /// ranking query are exactly what a separate `limit: 50` query would return.
    private func applyHistory(from snapshots: [AppTrafficSnapshot]) {
        let rows = Array(snapshots.prefix(Self.historyLimit))
        publish(\.historyRows, Self.sortSnapshotsByFavorites(rows, favorites: favoriteKeys))
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
        refreshPublishedState()
        persistIfDue(now: Date())
    }

    private func persistIfDue(now: Date) {
        savePoliciesIfChanged()
        evaluateAlertsIfDue(now: now)
        if lastFlushAttemptAt == nil
            || now.timeIntervalSince(lastFlushAttemptAt!) >= Self.telemetryFlushInterval {
            flushTelemetry(now: now)
        }
        let pruneIsDue = lastPruneAt == nil
            || now.timeIntervalSince(lastPruneAt!) >= Self.telemetryPruneInterval
        guard pruneIsDue else {
            return
        }
        // A failed database operation gets a bounded retry instead of another attempt
        // on every one-second UI tick.
        if let attempted = lastPruneAttemptAt, now.timeIntervalSince(attempted) < 60 {
            return
        }
        pruneTelemetry(now: now)
    }

    /// Assign a published property only when the value actually changed.
    ///
    /// Every write to an `@Published` property fires `objectWillChange`, and a tick
    /// writes about thirty of them. Re-publishing an identical value re-runs every
    /// observing view body for nothing — which, on an idle machine, is the entire cost
    /// of leaving the dashboard open.
    @inline(__always)
    private func publish<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    /// Append to a fixed-length series, returning a new array.
    ///
    /// Mutating the published array in place would fire `objectWillChange` twice per
    /// tick (append, then trim) even when the series is a flat line of zeros.
    private static func appending(_ series: [Double], _ value: Double, limit: Int) -> [Double] {
        var next = series
        next.append(value)
        if next.count > limit {
            next.removeFirst(next.count - limit)
        }
        return next
    }

    /// The range caption never renders finer than `HH:mm`, so publishing a to-the-second
    /// end date would invalidate the view every tick to draw the same string.
    private static func minuteAligned(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func overviewRollupScopeKey(selectedApp: AppIdentityKey?) -> String {
        let customRange: String
        if overviewPeriod == .custom {
            customRange = "\(customRangeStart.timeIntervalSince1970)|\(customRangeEnd.timeIntervalSince1970)"
        } else {
            customRange = ""
        }
        return "\(overviewPeriod.rawValue)|\(selectedApp?.storageKey ?? "*")|\(customRange)"
    }

    /// Keep the full history aggregation and destination sorting off the main actor.
    /// The first snapshot is built synchronously once; later ticks display the most
    /// recent completed rollup while the next one is prepared in the background.
    private func overviewRollupForDisplay(
        from: Date,
        to: Date,
        selectedApp: AppIdentityKey?
    ) -> (rollup: TrafficOverviewRollup, matchesScope: Bool) {
        let scope = overviewRollupScopeKey(selectedApp: selectedApp)
        if cachedOverviewRollup == nil {
            let initial = aggregator.overviewRollup(
                from: from,
                to: to,
                limit: Self.rankingLimit,
                selectedApp: selectedApp,
                includeSites: true
            )
            cachedOverviewRollup = initial
            cachedOverviewRollupScope = scope
            return (initial, true)
        }

        if !overviewRollupInFlight {
            overviewRollupInFlight = true
            let aggregator = aggregator
            let rankingLimit = Self.rankingLimit
            DispatchQueue.global(qos: .userInitiated).async {
                let next = aggregator.overviewRollup(
                    from: from,
                    to: to,
                    limit: rankingLimit,
                    selectedApp: selectedApp,
                    includeSites: true
                )
                Task { @MainActor in
                    self.overviewRollupInFlight = false
                    guard self.overviewRollupScopeKey(selectedApp: self.selectedApp) == scope else {
                        return
                    }
                    self.cachedOverviewRollup = next
                    self.cachedOverviewRollupScope = scope
                }
            }
        }

        let cached = cachedOverviewRollup ?? TrafficOverviewRollup(
            topApps: [],
            routeTotals: RouteDirectionalTotals(),
            routeShares: [:]
        )
        return (cached, cachedOverviewRollupScope == scope)
    }

    private func refreshPublishedState() {
        let now = Date()
        let range = overviewDateRange(now: now)
        let periodFrom = range.start
        let periodTo = range.end
        publish(\.periodRangeStart, Self.minuteAligned(periodFrom))
        publish(\.periodRangeEnd, Self.minuteAligned(periodTo))
        publish(\.periodMayBeIncomplete, periodFrom < monitoringStartedAt.addingTimeInterval(-1))
        publish(
            \.relativeTimeEpoch,
            Int(now.timeIntervalSince1970 / Self.relativeTimeEpochInterval)
        )
        let dayFrom = now.addingTimeInterval(-86_400)

        // Resolve selected app identity early (may be nil).
        let selectedIdentity = selectedApp

        // OS system proxy first — drives route chips + socket attribution.
        publish(\.systemProxy, SystemProxyReader.current())
        if !systemProxy.isEnabled {
            publish(\.systemProxyNodeIP, nil)
        }

        let hostRates = hostNetworkSampler.sampleRates(now: now)

        // Without NE telemetry, discover apps via ESTABLISHED sockets and
        // split host interface bytes across them by connection weight.
        // Read the foreground window first: this tick's bytes for whichever app is in
        // front are attributed to the page/document actually on screen.
        if tracksBrowserTabs {
            foregroundSampler.sample(now: now)
        }
        ingestActiveSocketFallback(hostRates: hostRates, at: now)

        let rates = aggregator.liveRateBps(for: selectedIdentity)

        if rates.down > 0 || rates.up > 0 {
            // Prefer aggregator rates (NE or socket-fallback attribution).
            publish(\.rateDownBps, rates.down)
            publish(\.rateUpBps, rates.up)
        } else if selectedIdentity == nil {
            // Idle socket sample: still show raw host interface rates.
            publish(\.rateDownBps, hostRates.downBps)
            publish(\.rateUpBps, hostRates.upBps)
        } else {
            publish(\.rateDownBps, 0)
            publish(\.rateUpBps, 0)
        }

        let liveBucketStart = Date(
            timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)
        )
        let liveRouteTotals = aggregator.routeDirectionalTotals(
            for: selectedIdentity,
            from: liveBucketStart,
            to: liveBucketStart.addingTimeInterval(1),
            preferredGranularity: .oneSecond
        )

        publish(\.sparklineDown, Self.appending(sparklineDown, rateDownBps, limit: 40))
        publish(\.sparklineUp, Self.appending(sparklineUp, rateUpBps, limit: 40))

        // Ranking and route totals share one history walk.
        let overviewResult = overviewRollupForDisplay(
            from: periodFrom,
            to: periodTo,
            selectedApp: selectedIdentity
        )
        let overviewRollup = overviewResult.rollup
        let periodRoutes = overviewRollup.routeTotals
        let periodTotals = periodRoutes.all
        let periodProxied = periodRoutes.proxied
        publish(\.periodNetworkUp, periodTotals.bytesUp)
        publish(\.periodNetworkDown, periodTotals.bytesDown)
        publish(\.periodDirectUp, periodRoutes.direct.bytesUp)
        publish(\.periodDirectDown, periodRoutes.direct.bytesDown)
        publish(\.periodProxyUp, periodProxied.bytesUp)
        publish(\.periodProxyDown, periodProxied.bytesDown)
        publish(\.periodUnattributedUp, periodRoutes.unknown.bytesUp)
        publish(\.periodUnattributedDown, periodRoutes.unknown.bytesDown)

        // Cumulative trend: append running period totals each tick so the area chart moves.
        // Scope ignores `periodTo` (usually `now`) so the series is not reset every tick.
        let scopeKey = cumulativeTrendKey(app: selectedIdentity, from: periodFrom)
        if scopeKey != cumulativeTrendScopeKey {
            cumulativeTrendScopeKey = scopeKey
            publish(\.periodTrendDown, [])
            publish(\.periodTrendUp, [])
        }

        // Running cumulative totals — chart rises as traffic accrues in this period.
        publish(
            \.periodTrendDown,
            Self.appending(periodTrendDown, Double(periodNetworkDown), limit: Self.cumulativeTrendLimit)
        )
        publish(
            \.periodTrendUp,
            Self.appending(periodTrendUp, Double(periodNetworkUp), limit: Self.cumulativeTrendLimit)
        )

        // One pass covers both the ranking and the history table: `rankingLimit`
        // exceeds the history's 50 rows and the sort is the same, so the history is a
        // prefix of this result rather than a second full rollup over the same range.
        let rawTops = overviewRollup.topApps
        let tops = rawTops.map { snap in
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
        publish(\.rules, policyStore.allRules())
        publish(\.groups, policyStore.allGroups())

        let connectionPool = aggregator.recentConnections(limit: 40)
        let scopedConnections: [LiveConnection]
        if let selectedIdentity {
            scopedConnections = connectionPool.filter { $0.app == selectedIdentity }
        } else {
            scopedConnections = connectionPool
        }
        publish(\.liveConnections, Array(scopedConnections.prefix(12)).map { conn in
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
        })

        let dayTotals = aggregator.totals(for: selectedIdentity, from: dayFrom, to: now)
        publish(\.blockedToday, dayTotals.flowsBlocked)
        publish(\.allowedConnections, dayTotals.flowsOpened)

        let activeRuleCount = policyStore.activeRuleCount() + groups.count
        publish(\.routeMix, Self.makeRouteMix(
            routes: periodRoutes,
            selectedRoute: selectedIdentity.flatMap { id in tops.first(where: { $0.app == id })?.route },
            systemProxyEnabled: systemProxy.isEnabled,
            blockedFallback: blockedToday,
            activeRules: activeRuleCount
        ))
        recomputePathRates(liveRouteTotals)

        // Build ranking rows with group + per-app proxy share.
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
        // Real per-app route split from recorded buckets (same range as the ranking).
        let routeShares = overviewRollup.routeShares

        updateAppTrafficHistory(from: activeTops + archivedTops)

        func makeRows(from snaps: [AppTrafficSnapshot], shareBase: UInt64) -> [AppRankingRow] {
            snaps.map { snap -> AppRankingRow in
                let share = Double(snap.totals.totalBytes) / Double(max(1, shareBase))
                let proxyShare: Double? = routeShares[snap.app].flatMap { split in
                    let total = split.direct &+ split.proxied
                    guard total > 0 else { return nil }
                    return Double(split.proxied) / Double(total)
                }
                let lastAt = aggregator.lastTrafficAt(for: snap.app)
                    ?? ((snap.rateDownBps + snap.rateUpBps) > 1 ? now : nil)
                return AppRankingRow(
                    snapshot: snap,
                    groupName: nil,
                    share: min(1, share),
                    proxyShare: proxyShare,
                    lastTrafficAt: lastAt,
                    rateSeries: appRateHistory[snap.app.storageKey] ?? []
                )
            }
        }

        let unsorted = makeRows(from: activeTops, shareBase: netTotal)
        publish(\.rankingRows, Self.sortByFavorites(unsorted, favorites: favoriteKeys))
        publish(\.topApps, rankingRows.map(\.snapshot))

        let archBase = max(1, archivedTops.reduce(UInt64(0)) { $0 &+ $1.totals.totalBytes })
        publish(\.archivedRankingRows, Self.sortByFavorites(
            makeRows(from: archivedTops, shareBase: archBase),
            favorites: favoriteKeys
        ))

        // Drop stale selection if app vanished after purge / archive.
        if overviewResult.matchesScope, let app = selectedApp {
            let stillThere = rankingRows.contains(where: { $0.snapshot.app == app })
                || archivedRankingRows.contains(where: { $0.snapshot.app == app })
            if !stillThere {
                selectedApp = nil
            }
        }

        publish(\.sunburstRoot, Self.buildSunburst(from: rankingRows))
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

        applyHistory(from: rawTops)
    }

    private static func buildSunburst(from rows: [AppRankingRow]) -> SunburstNode {
        let children: [SunburstNode] = rows.enumerated().map { index, row in
            let appID = row.snapshot.id
            // Drill children: websites (Chrome), projects (VS Code / Cursor / ChatGPT Codex / Claude)…
            let siteChildren: [SunburstNode]
            if !row.snapshot.sites.isEmpty {
                let siteTotal = max(1, row.snapshot.sites.reduce(UInt64(0)) { $0 &+ $1.totals.totalBytes })
                siteChildren = row.snapshot.sites.enumerated().map { sIdx, site in
                    let siteValue = max(
                        1,
                        UInt64(Double(row.snapshot.totals.totalBytes) * Double(site.totals.totalBytes) / Double(siteTotal))
                    )
                    return SunburstNode(
                        id: "\(appID)|\(site.destinationKey)",
                        title: Self.localizedSpecialDestination(site.destinationKey) ?? site.hostname,
                        value: siteValue,
                        colorIndex: index,
                        colorVariant: sIdx + 1,
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
                colorIndex: index,
                colorVariant: 0,
                children: siteChildren
            )
        }
        let total = children.reduce(UInt64(0)) { $0 &+ $1.value }
        return SunburstNode(id: "root", title: "Root", value: total, colorIndex: 0, colorVariant: 0, children: children)
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
            let scaledTraffic = parent.rateSeries.map { $0 * share }
            // Path segments are the split itself: proxy-node bytes are 100% proxied,
            // rule-direct bytes 0%. Individual sites carry no per-site route data.
            let segmentProxyShare: Double?
            switch site.destinationKey {
            case DestinationKey.viaProxyNode: segmentProxyShare = 1
            case DestinationKey.directByRule: segmentProxyShare = 0
            default: segmentProxyShare = nil
            }
            return AppRankingRow(
                id: "\(parent.id)|\(site.destinationKey)",
                snapshot: AppTrafficSnapshot(
                    app: parent.snapshot.app,
                    displayName: drillDownTitle(for: site, isBrowser: parent.snapshot.isBrowser),
                    totals: site.totals,
                    rateUpBps: 0,
                    rateDownBps: 0,
                    activeConnections: site.activeConnections,
                    route: parent.snapshot.route,
                    firewallStatus: parent.snapshot.firewallStatus,
                    isBrowser: parent.snapshot.isBrowser,
                    sites: []
                ),
                groupName: nil,
                share: share,
                proxyShare: segmentProxyShare,
                lastTrafficAt: site.totals.totalBytes > 0 ? parent.lastTrafficAt : nil,
                rateSeries: scaledTraffic
            )
        }
    }

    /// Label for one drill-down segment.
    ///
    /// Project segments already carry a meaningful name. Browser hosts get the page
    /// last seen there appended — only when tab tracking is on and that host has been
    /// visited in the foreground, so the host itself is never replaced by a guess.
    private func drillDownTitle(for site: SiteTrafficSnapshot, isBrowser: Bool) -> String {
        if let special = Self.localizedSpecialDestination(site.destinationKey) {
            return special
        }
        let host = site.hostname
        guard tracksBrowserTabs, isBrowser else { return host }
        guard let title = browserTabSampler.title(forHost: host), title != host else {
            return host
        }
        let trimmed = title.count > 60 ? String(title.prefix(60)) + "…" : title
        return "\(host) · \(trimmed)"
    }

    /// Localized title for non-site destination keys (`unknown`, `path:` segments).
    static func localizedSpecialDestination(_ key: String) -> String? {
        switch key {
        case DestinationKey.unknown:
            return LocalizationStore.shared.t("destination.unknown")
        case DestinationKey.viaProxyNode:
            return LocalizationStore.shared.t("destination.pathProxy")
        case DestinationKey.directByRule:
            return LocalizationStore.shared.t("destination.pathDirect")
        default:
            return nil
        }
    }

    /// Append cumulative network totals so ranking sparklines diverge per app.
    private func updateAppTrafficHistory(from snaps: [AppTrafficSnapshot]) {
        let activeKeys = Set(snaps.map(\.app.storageKey))
        for snap in snaps {
            let key = snap.app.storageKey
            var series = appRateHistory[key] ?? []
            series.append(Double(snap.totals.totalBytes))
            if series.count > Self.appRateHistoryLimit {
                series.removeFirst(series.count - Self.appRateHistoryLimit)
            }
            appRateHistory[key] = series
        }
        appRateHistory = appRateHistory.filter { activeKeys.contains($0.key) || archivedKeys.contains($0.key) }
    }

    var drilledAppTitle: String? {
        guard let id = sunburstPath.first else { return nil }
        return rankingRows.first(where: { $0.id == id })?.snapshot.displayName
    }

    private func cumulativeTrendKey(app: AppIdentityKey?, from: Date) -> String {
        let appKey = app?.storageKey ?? "*"
        // Bucket start to the minute so rolling windows don't thrash the series.
        let startBucket = Int(from.timeIntervalSince1970) / 60
        return "\(overviewPeriod.rawValue)|\(appKey)|\(startBucket)"
    }

    /// Build proxy-routing card mix from period-scoped byte shares (time range + optional app).
    /// When no flow bytes yet, fall back to selected app route or live macOS system proxy.
    private static func makeRouteMix(
        routes: RouteDirectionalTotals,
        selectedRoute: RouteAction?,
        systemProxyEnabled: Bool,
        blockedFallback: UInt64,
        activeRules: Int
    ) -> RouteMix {
        let blocked = routes.all.flowsBlocked > 0 ? routes.all.flowsBlocked : blockedFallback
        let total = routes.all.totalBytes
        if total > 0 {
            let denominator = Double(total)
            let d = Double(routes.direct.totalBytes) / denominator * 100
            let s = Double(routes.systemProxy.totalBytes) / denominator * 100
            let c = Double(routes.customProxy.totalBytes) / denominator * 100
            let u = max(0, 100 - d - s - c)
            return RouteMix(
                directPercent: d,
                systemProxyPercent: s,
                customProxyPercent: c,
                unknownPercent: u,
                blockedCount: blocked,
                activeRules: activeRules
            )
        }

        // No bytes in range: if an app is selected, show its resolved route.
        if let selectedRoute {
            switch selectedRoute {
            case .inherit:
                // No rule for this app — macOS decides, so mirror the OS setting
                // instead of claiming the traffic bypasses the proxy.
                return RouteMix(
                    directPercent: systemProxyEnabled ? 0 : 100,
                    systemProxyPercent: systemProxyEnabled ? 100 : 0,
                    customProxyPercent: 0,
                    blockedCount: blocked,
                    activeRules: activeRules
                )
            case .direct:
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

        // Nothing measured yet. With a system proxy configured, unruled traffic goes
        // through it by default, so show that rather than asserting 100% direct.
        // Once real byte shares arrive they replace this entirely — Clash /
        // Shadowrocket DIRECT rules do produce genuine direct egress.
        return RouteMix(
            directPercent: systemProxyEnabled ? 0 : 100,
            systemProxyPercent: systemProxyEnabled ? 100 : 0,
            customProxyPercent: 0,
            blockedCount: blocked,
            activeRules: activeRules
        )
    }

    private func resolveFirewall(for app: AppIdentityKey) -> FirewallAction {
        // Block rules can still arrive from the CLI / policy archive; the app UI no
        // longer writes them.
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
        if let observed = socketObservedRoute[app.storageKey] {
            return observed
        }
        let snap = policyStore.compileSnapshot()
        return snap.evaluateRoute(FlowDescriptor(app: app)).action
    }

    // MARK: - Socket fallback (app identity without Network Extension)

    /// Reload local proxy DIRECT rules off the main thread.
    ///
    /// This reads another app's container (`~/Library/Containers/…`), which macOS
    /// gates behind TCC: the first read can block until the user answers a consent
    /// prompt — indefinitely if no one is at the keyboard. Doing it inline froze the
    /// whole app inside `init`, so it now runs on a background queue and publishes
    /// back when it finishes.
    private func refreshDirectIndexIfNeeded(now: Date) {
        if let loaded = directIndexLoadedAt, now.timeIntervalSince(loaded) < 120 {
            return
        }
        // One refused or unanswered consent prompt is enough: retrying would ask the
        // user again on every refresh.
        if directIndexUnavailable { return }
        if directIndexLoadInFlight { return }
        directIndexLoadInFlight = true
        // Stamp the attempt immediately so a slow read is not retried every tick.
        directIndexLoadedAt = now
        DispatchQueue.global(qos: .utility).async {
            let index = LocalProxyConfigReader.loadDirectIndex(timeout: 3)
            Task { @MainActor in
                if let index {
                    self.directDestinationIndex = index
                } else {
                    // Blocked on a consent prompt nobody answered. Route classification
                    // falls back to socket evidence alone rather than stalling.
                    self.directIndexUnavailable = true
                }
                self.directIndexLoadedAt = Date()
                self.directIndexLoadInFlight = false
            }
        }
    }

    /// Re-read local IDE / agent workspaces so project titles track renames and new
    /// checkouts. Discovery walks the filesystem, so it stays off the main thread.
    private func refreshWorkspacesIfNeeded(now: Date) {
        if let refreshed = workspacesRefreshedAt, now.timeIntervalSince(refreshed) < 300 {
            return
        }
        if workspaceRefreshInFlight { return }
        workspaceRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [projectResolver] in
            let workspaces = WorkspaceDiscovery.discover(options: WorkspaceDiscoveryOptions(limit: 0))
            projectResolver.updateWorkspaces(workspaces)
            Task { @MainActor in
                self.attributionResolver.invalidate()
                self.workspacesRefreshedAt = Date()
                self.workspaceRefreshInFlight = false
            }
        }
    }

    private func scheduleSocketSampleIfNeeded() {
        if socketSampleInFlight { return }
        socketSampleInFlight = true
        let port = systemProxy.httpPort ?? systemProxy.httpsPort ?? systemProxy.socksPort
        let index = directDestinationIndex
        let dnsCache = reverseDNSCache
        let attributionResolver = attributionResolver
        DispatchQueue.global(qos: .utility).async {
            let connections: [ActiveAppSocketSampler.ConnectionLine]
            switch ActiveAppSocketSampler.currentConnectionResult() {
            case .success(let lines):
                connections = lines
            case .failure:
                Task { @MainActor in
                    self.socketSampleInFlight = false
                }
                return
            }
            // Stamp capture before attribution and other work. A delayed result must
            // not become "fresh" merely because it was published late.
            let capturedAt = Date()
            // DNS enrichment is scheduled separately. A missing or slow PTR record
            // must not delay app attribution or keep `socketSampleInFlight` stuck.
            var pendingCounts: [String: Int] = [:]
            for conn in connections {
                let host = conn.remoteHost
                guard dnsCache[host] == nil,
                      DirectDestinationIndex.parseIPv4(host) != nil,
                      !RemoteDestination.isProxyPlaceholderAddress(host)
                else { continue }
                pendingCounts[host, default: 0] += 1
            }

            let snapshot = ActiveAppSocketSampler.summarize(
                connections,
                proxyPort: port,
                directIndex: index,
                resolvedHosts: dnsCache
            )
            let attributed = attributionResolver.attribute(
                snapshot.processes.filter { !$0.isProxyProcess },
                now: Date()
            )
            let pending = pendingCounts
                .sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key < $1.key
                }
                .map(\.key)
            Task { @MainActor in
                self.cachedSocketSnapshot = snapshot
                self.cachedAttributedSocketProcesses = attributed
                self.cachedSocketSnapshotAt = capturedAt
                self.systemProxyNodeIP = snapshot.primaryProxyNodeIP
                self.socketSampleInFlight = false
                self.scheduleReverseDNSLookups(pending, now: Date())
            }
        }
    }

    /// Enrich labels in the background with a small, bounded queue.
    ///
    /// Failed PTR lookups are cached as attempts for 30 minutes; otherwise common
    /// public IPs with no reverse record would launch another blocking lookup every
    /// second forever.
    private func scheduleReverseDNSLookups(_ candidates: [String], now: Date) {
        let retryAfter: TimeInterval = 30 * 60
        reverseDNSAttemptedAt = reverseDNSAttemptedAt.filter {
            now.timeIntervalSince($0.value) < retryAfter
        }
        if reverseDNSCache.count > 2_048 {
            reverseDNSCache.removeAll(keepingCapacity: true)
        }

        let availableSlots = max(0, 8 - reverseDNSQueue.operationCount)
        guard availableSlots > 0 else { return }
        var scheduled = 0
        for ip in candidates {
            guard scheduled < availableSlots else { break }
            guard reverseDNSCache[ip] == nil else { continue }
            if let attempted = reverseDNSAttemptedAt[ip],
               now.timeIntervalSince(attempted) < retryAfter {
                continue
            }
            reverseDNSAttemptedAt[ip] = now
            scheduled += 1
            reverseDNSQueue.addOperation { [weak self] in
                let name = ReverseDNS.lookup(ip)
                guard let name else { return }
                Task { @MainActor [weak self] in
                    self?.reverseDNSCache[ip] = name
                }
            }
        }
    }

    /// Attribute host interface byte deltas to apps that hold ESTABLISHED sockets.
    ///
    /// Observed route semantics (first principles):
    /// - `.systemProxy` = egress via local proxy client toward a proxy node (翻墙)
    /// - `.direct` = not via a proxy node (true bypass, or client rule DIRECT)
    /// - weak TUN / unattributed evidence → do not force `.direct`
    private func ingestActiveSocketFallback(hostRates: HostNetworkSampler.Rates, at: Date) {
        refreshDirectIndexIfNeeded(now: at)
        refreshWorkspacesIfNeeded(now: at)
        scheduleSocketSampleIfNeeded()
        let totalDown = hostRates.deltaIn
        let totalUp = hostRates.deltaOut
        let sampleInterval = hostRates.sampleInterval > 0
            ? Optional(hostRates.sampleInterval)
            : nil
        // Never stretch freshness to match a long host-counter interval. After sleep
        // or a stalled sampler, an hours-old ownership snapshot must not claim the
        // accumulated bytes.
        let snapshotIsFresh = ActiveAppSocketSampler.snapshotIsFresh(
            capturedAt: cachedSocketSnapshotAt,
            now: at
        )
        let snapshot = snapshotIsFresh ? cachedSocketSnapshot : ActiveSocketSnapshot()
        let attributedSamples = snapshotIsFresh ? cachedAttributedSocketProcesses : []
        guard !attributedSamples.isEmpty
                || snapshot.proxyDirectEgress > 0
                || snapshot.proxyRemoteEgress > 0
        else {
            aggregator.setObservedActiveConnectionCounts([:])
            // A successful, fresh empty census confirms every prior synthetic
            // socket flow ended. A stale/unavailable census proves no such thing;
            // keep lifecycle state until a valid sample can confirm closure.
            if snapshotIsFresh {
                closeInactiveSocketFlows(keeping: [], at: at)
            }
            recordUnattributedDelta(
                down: totalDown,
                up: totalUp,
                at: at,
                sampleInterval: sampleInterval
            )
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundle = Bundle.main.bundleIdentifier
        let tunnelActive = HostNetworkSampler.hasActiveTunnelInterface()
        let weakBypassEvidence = tunnelActive

        struct Row {
            var key: AppIdentityKey
            var name: String
            var viaProxy: Int
            var direct: Int
            /// Hosts from processes with no project attribution. Hosts belonging to
            /// a known project must not be reused as labels for an unknown process.
            var unknownDirectHosts: [String]
            /// Keep project weights separate by observed path. Combining them lets a
            /// direct-only project absorb a different project's proxied traffic.
            var directProjectWeights: [String: Int]
            var proxyProjectWeights: [String: Int]
            var directUnknownWeight: Int
            var proxyUnknownWeight: Int
        }

        var merged: [String: Row] = [:]
        for attributed in attributedSamples {
            if attributed.pid == selfPID { continue }
            let identity = resolveSocketAppIdentity(attributed)
            let signing = identity.signingIdentifier
            if let selfBundle, signing == selfBundle { continue }

            let key = AppIdentityKey(teamIdentifier: nil, signingIdentifier: signing)
            let sk = key.storageKey
            let displayName = identity.displayName
            let projectKey = attributed.projectDestinationKey

            if var existing = merged[sk] {
                existing.viaProxy += attributed.viaProxyConnections
                existing.direct += attributed.directConnections
                // Prefer a real product name over truncated lsof COMMAND leftovers.
                if existing.name == attributed.command || existing.name.hasPrefix("proc.") {
                    existing.name = displayName
                }
                if let projectKey {
                    if attributed.directConnections > 0 {
                        existing.directProjectWeights[projectKey, default: 0] += attributed.directConnections
                    }
                    if attributed.viaProxyConnections > 0 {
                        existing.proxyProjectWeights[projectKey, default: 0] += attributed.viaProxyConnections
                    }
                } else {
                    existing.directUnknownWeight += attributed.directConnections
                    existing.proxyUnknownWeight += attributed.viaProxyConnections
                    mergeHosts(attributed.remoteHosts, into: &existing.unknownDirectHosts)
                }
                merged[sk] = existing
            } else {
                var directProjects: [String: Int] = [:]
                var proxyProjects: [String: Int] = [:]
                if let projectKey {
                    if attributed.directConnections > 0 {
                        directProjects[projectKey] = attributed.directConnections
                    }
                    if attributed.viaProxyConnections > 0 {
                        proxyProjects[projectKey] = attributed.viaProxyConnections
                    }
                }
                merged[sk] = Row(
                    key: key,
                    name: displayName,
                    viaProxy: attributed.viaProxyConnections,
                    direct: attributed.directConnections,
                    unknownDirectHosts: projectKey == nil
                        ? Array(attributed.remoteHosts.prefix(8))
                        : [],
                    directProjectWeights: directProjects,
                    proxyProjectWeights: proxyProjects,
                    directUnknownWeight: projectKey == nil ? attributed.directConnections : 0,
                    proxyUnknownWeight: projectKey == nil ? attributed.viaProxyConnections : 0
                )
            }
        }

        // Timing-style foreground attribution: while a browser is frontmost, bytes
        // its sockets move are labeled with the page the user is on. An explicit
        // approximation (background tabs transfer too), gated behind the opt-in
        // toggle, and bounded so a stale read cannot keep claiming traffic.
        /// The destination for a segment with no visible peer: the foreground page or
        /// window when this row *is* the frontmost app, else the given path label.
        func destinationFallback(for item: Row, path: String?) -> String? {
            if tracksBrowserTabs,
               let foreground = foregroundSampler.destinationKey(
                   forSigningID: item.key.signingIdentifier,
                   now: at
               ) {
                return foreground
            }
            return path
        }

        let rows = merged.values.sorted { $0.key.storageKey < $1.key.storageKey }
        aggregator.setObservedActiveConnectionCounts(
            Dictionary(
                rows.map { ($0.key, $0.direct + $0.viaProxy) },
                uniquingKeysWith: +
            )
        )
        let bypassWeight = rows.reduce(0) { $0 + $1.direct }
        let clientViaWeight = rows.reduce(0) { $0 + $1.viaProxy }
        let proxyDirect = snapshot.proxyDirectEgress
        let proxyRemote = snapshot.proxyRemoteEgress

        // Host NIC bytes ≈ proxy-process egress + true bypass apps.
        // Client→127.0.0.1 does not hit the NIC, so don't weight by viaProxy for bytes.
        let useProxyEgressSplit = (proxyDirect + proxyRemote) > 0
        let bytePoolDirect: Int
        let bytePoolProxy: Int
        let bytePoolBypass: Int
        if useProxyEgressSplit {
            bytePoolDirect = proxyDirect
            bytePoolProxy = proxyRemote
            bytePoolBypass = weakBypassEvidence ? 0 : bypassWeight
        } else {
            bytePoolDirect = bypassWeight
            bytePoolProxy = clientViaWeight
            bytePoolBypass = 0
        }
        let byteTotal = bytePoolDirect + bytePoolProxy + bytePoolBypass

        // Per-app score: prefer proxy-node (翻墙) vs rule/true direct from observed egress.
        var routeScore: [String: (direct: Int, proxy: Int)] = [:]
        var observedFlowKeys: Set<String> = []

        // Seed route badges before the first non-zero host delta.
        //
        // Deliberately opened without a destination: a seed carries no bytes, and
        // naming a host here would register a 0-byte segment that shows up in the
        // drill-down as a site the app never actually used.
        for item in rows {
            let key = item.key.storageKey
            if item.viaProxy > 0 {
                let route: RouteAction = proxyRemote >= proxyDirect ? .systemProxy : .direct
                // When both egress pools are zero, lean proxy if the app entered the local client.
                let seeded: RouteAction = {
                    if proxyDirect + proxyRemote == 0 { return .systemProxy }
                    return route
                }()
                socketObservedRoute[key] = seeded
                observedFlowKeys.insert(
                    ensureSocketOpen(app: item.key, name: item.name, host: nil, route: seeded, at: at)
                )
                if case .systemProxy = seeded {
                    routeScore[key] = (direct: 0, proxy: item.viaProxy)
                } else {
                    routeScore[key] = (direct: item.viaProxy, proxy: 0)
                }
            } else if item.direct > 0 {
                if weakBypassEvidence {
                    // TUN / local proxy active but this app was not seen on the proxy port —
                    // do not claim Direct (may still be tunneled).
                    socketObservedRoute.removeValue(forKey: key)
                } else {
                    socketObservedRoute[key] = .direct
                    observedFlowKeys.insert(
                        ensureSocketOpen(app: item.key, name: item.name, host: nil, route: .direct, at: at)
                    )
                    routeScore[key] = (direct: item.direct, proxy: 0)
                }
            }
        }

        guard totalDown > 0 || totalUp > 0 else {
            applyObservedRouteScores(routeScore)
            closeInactiveSocketFlows(keeping: observedFlowKeys, at: at)
            return
        }
        guard byteTotal > 0 else {
            recordUnattributedDelta(
                down: totalDown,
                up: totalUp,
                at: at,
                sampleInterval: sampleInterval
            )
            applyObservedRouteScores(routeScore)
            closeInactiveSocketFlows(keeping: observedFlowKeys, at: at)
            return
        }

        let poolWeights = [bytePoolDirect, bytePoolProxy, bytePoolBypass].map {
            UInt64(max(0, $0))
        }
        let downPools = ProportionalByteAllocator.split(total: totalDown, weights: poolWeights)
        let upPools = ProportionalByteAllocator.split(total: totalUp, weights: poolWeights)
        let directBytesDown = downPools[0]
        let directBytesUp = upPools[0]
        let proxyBytesDown = downPools[1]
        let proxyBytesUp = upPools[1]
        let bypassBytesDown = downPools[2]
        let bypassBytesUp = upPools[2]
        var attributedDown: UInt64 = 0
        var attributedUp: UInt64 = 0

        // Distribute proxy-process DIRECT egress across clients that talk to the local proxy.
        let proxyClients = rows.filter { $0.viaProxy > 0 }
        let proxyClientWeights = proxyClients.map { UInt64(max(0, $0.viaProxy)) }
        if useProxyEgressSplit, !proxyClients.isEmpty,
           directBytesDown > 0 || directBytesUp > 0 {
            let downs = ProportionalByteAllocator.split(
                total: directBytesDown,
                weights: proxyClientWeights
            )
            let ups = ProportionalByteAllocator.split(
                total: directBytesUp,
                weights: proxyClientWeights
            )
            for (index, item) in proxyClients.enumerated() {
                let down = downs[index]
                let up = ups[index]
                // These bytes exited via the proxy's DIRECT rules (e.g. bilibili).
                // The client's own socket peers are unrelated to this path, and the
                // proxy's egress hosts belong to the proxy, not any one client — so
                // the honest label is the path itself.
                recordSocketDelta(
                    app: item.key,
                    name: item.name,
                    hosts: [],
                    projects: item.proxyProjectWeights,
                    unknownProjectWeight: item.proxyUnknownWeight,
                    fallbackDestination: destinationFallback(for: item, path: DestinationKey.directByRule),
                    down: down,
                    up: up,
                    route: .direct,
                    at: at,
                    sampleInterval: sampleInterval,
                    observedFlowKeys: &observedFlowKeys
                )
                attributedDown &+= down
                attributedUp &+= up
                let sk = item.key.storageKey
                var score = routeScore[sk] ?? (direct: 0, proxy: 0)
                score.direct += Int(min(UInt64(Int.max), down &+ up))
                routeScore[sk] = score
            }
        }

        if !proxyClients.isEmpty, proxyBytesDown > 0 || proxyBytesUp > 0 {
            let downs = ProportionalByteAllocator.split(
                total: proxyBytesDown,
                weights: proxyClientWeights
            )
            let ups = ProportionalByteAllocator.split(
                total: proxyBytesUp,
                weights: proxyClientWeights
            )
            for (index, item) in proxyClients.enumerated() {
                let down = downs[index]
                let up = ups[index]
                recordSocketDelta(
                    app: item.key,
                    name: item.name,
                    hosts: [],
                    projects: item.proxyProjectWeights,
                    unknownProjectWeight: item.proxyUnknownWeight,
                    fallbackDestination: destinationFallback(for: item, path: DestinationKey.viaProxyNode),
                    down: down,
                    up: up,
                    route: .systemProxy,
                    at: at,
                    sampleInterval: sampleInterval,
                    observedFlowKeys: &observedFlowKeys
                )
                attributedDown &+= down
                attributedUp &+= up
                let sk = item.key.storageKey
                var score = routeScore[sk] ?? (direct: 0, proxy: 0)
                score.proxy += Int(min(UInt64(Int.max), down &+ up))
                routeScore[sk] = score
            }
        }

        // True bypass only when we are confident traffic did not go through a tunnel / local client.
        if !weakBypassEvidence, bypassWeight > 0,
           bypassBytesDown > 0 || bypassBytesUp > 0
            || (!useProxyEgressSplit && (directBytesDown > 0 || directBytesUp > 0)) {
            let downPool = useProxyEgressSplit ? bypassBytesDown : directBytesDown
            let upPool = useProxyEgressSplit ? bypassBytesUp : directBytesUp
            let directClients = rows.filter { $0.direct > 0 }
            let directClientWeights = directClients.map { UInt64(max(0, $0.direct)) }
            let downs = ProportionalByteAllocator.split(
                total: downPool,
                weights: directClientWeights
            )
            let ups = ProportionalByteAllocator.split(
                total: upPool,
                weights: directClientWeights
            )
            for (index, item) in directClients.enumerated() {
                let down = downs[index]
                let up = ups[index]
                recordSocketDelta(
                    app: item.key,
                    name: item.name,
                    hosts: item.unknownDirectHosts,
                    projects: item.directProjectWeights,
                    unknownProjectWeight: item.directUnknownWeight,
                    fallbackDestination: destinationFallback(for: item, path: nil),
                    down: down,
                    up: up,
                    route: .direct,
                    at: at,
                    sampleInterval: sampleInterval,
                    observedFlowKeys: &observedFlowKeys
                )
                attributedDown &+= down
                attributedUp &+= up
                let sk = item.key.storageKey
                var score = routeScore[sk] ?? (direct: 0, proxy: 0)
                score.direct += Int(min(UInt64(Int.max), down &+ up))
                routeScore[sk] = score
            }
        }

        assert(attributedDown <= totalDown && attributedUp <= totalUp)
        recordUnattributedDelta(
            down: totalDown >= attributedDown ? totalDown - attributedDown : 0,
            up: totalUp >= attributedUp ? totalUp - attributedUp : 0,
            at: at,
            sampleInterval: sampleInterval
        )
        applyObservedRouteScores(routeScore)
        closeInactiveSocketFlows(keeping: observedFlowKeys, at: at)
    }

    /// Pick Direct vs Proxy (systemProxy bucket) from per-app observed byte scores.
    private func applyObservedRouteScores(_ scores: [String: (direct: Int, proxy: Int)]) {
        for (key, score) in scores {
            if score.proxy > score.direct {
                socketObservedRoute[key] = .systemProxy
            } else if score.direct > score.proxy {
                socketObservedRoute[key] = .direct
            } else if score.proxy > 0 {
                // Tie with any proxy-node evidence → 翻墙.
                socketObservedRoute[key] = .systemProxy
            }
        }
    }

    private struct SocketAppIdentity {
        var signingIdentifier: String
        var displayName: String
    }

    /// Upgrade a core attribution with AppKit-only knowledge.
    ///
    /// `LiveAttributionResolver` works from executable paths, which is all the core
    /// package can see. A GUI process whose path yields no bundle can still be named
    /// through `NSRunningApplication`, so try that before settling for `proc.<name>`.
    private func resolveSocketAppIdentity(_ attributed: AttributedProcess) -> SocketAppIdentity {
        let signing = attributed.app.signingIdentifier
        if !signing.hasPrefix("proc.") {
            let name = AppIconCache.shared.displayName(
                forSigningID: signing,
                fallback: attributed.displayName
            )
            return SocketAppIdentity(signingIdentifier: signing, displayName: name)
        }

        let running = NSRunningApplication(processIdentifier: attributed.pid)
        if let bundleID = running?.bundleIdentifier, !bundleID.isEmpty {
            let canonical = ProcessAppIdentity.canonicalSigningID(bundleID)
            let localized = running?.localizedName ?? attributed.displayName
            return SocketAppIdentity(
                signingIdentifier: canonical,
                displayName: AppIconCache.shared.displayName(
                    forSigningID: canonical,
                    fallback: localized
                )
            )
        }

        let name = AppIconCache.shared.displayName(
            forSigningID: signing,
            fallback: attributed.displayName
        )
        return SocketAppIdentity(signingIdentifier: signing, displayName: name)
    }

    private func mergeHosts(_ incoming: [String], into hosts: inout [String]) {
        for host in incoming {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !hosts.contains(trimmed), hosts.count < 8 else { continue }
            hosts.append(trimmed)
        }
    }

    private func ensureSocketOpen(
        app: AppIdentityKey,
        name: String,
        host: String?,
        route: RouteAction,
        at: Date
    ) -> String {
        let key = app.storageKey + "|" + route.chipLabel
        if socketActiveFlows[key] != nil { return key }
        let id = socketFlowID(for: app, route: route)
        let flow = FlowDescriptor(
            id: id,
            app: app,
            remoteHostname: host,
            remotePort: 443,
            openedAt: at
        )
        aggregator.recordOpen(flow, displayName: name, route: route)
        socketActiveFlows[key] = SyntheticSocketFlow(id: id, app: app, route: route)
        return key
    }

    private func closeInactiveSocketFlows(keeping observed: Set<String>, at: Date) {
        let staleKeys = socketActiveFlows.keys.filter { !observed.contains($0) }
        guard !staleKeys.isEmpty else { return }
        var affectedApps: Set<String> = []
        for key in staleKeys {
            guard let state = socketActiveFlows.removeValue(forKey: key) else { continue }
            aggregator.recordClose(
                flowID: state.id,
                app: state.app,
                at: at,
                route: state.route
            )
            socketFlowIDs.removeValue(forKey: key)
            affectedApps.insert(state.app.storageKey)
        }
        let stillActiveApps = Set(socketActiveFlows.values.map { $0.app.storageKey })
        for key in affectedApps where !stillActiveApps.contains(key) {
            socketObservedRoute.removeValue(forKey: key)
        }
    }

    /// Preserve host-interface bytes that cannot be assigned without guessing.
    private func recordUnattributedDelta(
        down: UInt64,
        up: UInt64,
        at: Date,
        sampleInterval: TimeInterval?
    ) {
        guard down > 0 || up > 0 else { return }
        aggregator.setDisplayName(
            LocalizationStore.shared.t("traffic.unattributed"),
            for: unattributedTrafficApp
        )
        aggregator.recordDelta(
            flowID: unattributedTrafficFlowID,
            app: unattributedTrafficApp,
            up: up,
            down: down,
            at: at,
            route: .inherit,
            transport: .other,
            destinationKey: DestinationKey.unknown,
            routeKindOverride: .unknown,
            sampleInterval: sampleInterval
        )
    }

    /// Split an app's byte delta across its drill-down segments.
    ///
    /// Projects win over hostnames when both are known: an agent talks to the same
    /// API endpoint all day, so "which project" is the dimension that carries meaning.
    /// Segments are weighted by the sockets each one holds rather than split evenly.
    private func recordSocketDelta(
        app: AppIdentityKey,
        name: String,
        hosts: [String],
        projects: [String: Int] = [:],
        unknownProjectWeight: Int = 0,
        fallbackDestination: String? = nil,
        down: UInt64,
        up: UInt64,
        route: RouteAction,
        at: Date,
        sampleInterval: TimeInterval?,
        observedFlowKeys: inout Set<String>
    ) {
        guard down > 0 || up > 0 else { return }

        var segments: [(label: String?, weight: UInt64)] = projects
            // Sort for a stable split when weights tie.
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map { (label: Optional($0.key), weight: UInt64(max(1, $0.value))) }

        if unknownProjectWeight > 0 {
            if hosts.isEmpty {
                segments.append(
                    (label: fallbackDestination, weight: UInt64(unknownProjectWeight))
                )
            } else {
                let hostWeights = ProportionalByteAllocator.split(
                    total: UInt64(unknownProjectWeight),
                    weights: Array(repeating: 1, count: hosts.count)
                )
                for (index, host) in hosts.enumerated() where hostWeights[index] > 0 {
                    segments.append((label: host, weight: hostWeights[index]))
                }
            }
        }
        if segments.isEmpty {
            if hosts.isEmpty {
                // No visible peer: a `path:` label at least says how the bytes left.
                segments = [(label: fallbackDestination, weight: 1)]
            } else {
                segments = hosts.map { (label: Optional($0), weight: UInt64(1)) }
            }
        }

        let weights = segments.map(\.weight)
        let downParts = ProportionalByteAllocator.split(total: down, weights: weights)
        let upParts = ProportionalByteAllocator.split(total: up, weights: weights)
        for (index, segment) in segments.enumerated() {
            let partDown = downParts[index]
            let partUp = upParts[index]
            let host = segment.label
            guard partDown > 0 || partUp > 0 else { continue }
            observedFlowKeys.insert(
                ensureSocketOpen(app: app, name: name, host: host, route: route, at: at)
            )
            let dest = DestinationKey.make(hostname: host, address: nil)
            aggregator.recordDelta(
                flowID: socketFlowID(for: app, route: route),
                app: app,
                up: partUp,
                down: partDown,
                at: at,
                route: route,
                destinationKey: dest,
                sampleInterval: sampleInterval
            )
        }
    }

    private func socketFlowID(for app: AppIdentityKey, route: RouteAction = .direct) -> UUID {
        let key = app.storageKey + "|" + route.chipLabel
        if let existing = socketFlowIDs[key] {
            return existing
        }
        let id = UUID()
        socketFlowIDs[key] = id
        return id
    }

}
