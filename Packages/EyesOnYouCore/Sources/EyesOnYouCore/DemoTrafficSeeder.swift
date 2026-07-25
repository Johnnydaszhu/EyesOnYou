import Foundation

/// Shared demo/live-fallback traffic seeder.
/// Browser hosts stay illustrative; IDE / agent drill-downs use real discovered workspaces.
public enum DemoTrafficSeeder {
    public struct AppSeedIdentity: Sendable {
        public let displayName: String
        public let signingIdentifier: String
        public let teamIdentifier: String?

        public init(displayName: String, signingIdentifier: String, teamIdentifier: String?) {
            self.displayName = displayName
            self.signingIdentifier = signingIdentifier
            self.teamIdentifier = teamIdentifier
        }

        public var key: AppIdentityKey {
            AppIdentityKey(teamIdentifier: teamIdentifier, signingIdentifier: signingIdentifier)
        }
    }

    public static let vscode = AppSeedIdentity(
        displayName: "Visual Studio Code",
        signingIdentifier: "com.microsoft.VSCode",
        teamIdentifier: "UBF8T346G9"
    )
    public static let cursor = AppSeedIdentity(
        displayName: "Cursor",
        signingIdentifier: "com.todesktop.230313mzl4w4u92",
        teamIdentifier: "VDXQ22DGB9"
    )
    /// ChatGPT desktop ships as Codex (`com.openai.codex`), not the legacy `com.openai.chat` id.
    public static let codex = AppSeedIdentity(
        displayName: "ChatGPT",
        signingIdentifier: "com.openai.codex",
        teamIdentifier: "2DC432GLL2"
    )
    public static let claude = AppSeedIdentity(
        displayName: "Claude",
        signingIdentifier: "com.anthropic.claudefordesktop",
        teamIdentifier: "Q6L2SF6YDW"
    )

    public static func seed(
        into aggregator: TelemetryAggregator,
        at now: Date = Date(),
        discoveryOptions: WorkspaceDiscoveryOptions = .default,
        resolveRoute: (AppIdentityKey) -> RouteAction = { _ in .direct }
    ) {
        var offset = 0
        offset = seedBrowsers(into: aggregator, at: now, offset: offset, resolveRoute: resolveRoute)

        let discovered = WorkspaceDiscovery.discover(options: discoveryOptions)

        offset = seedWorkspaceApp(
            identity: vscode,
            projects: discovered.filter { $0.sources.contains(.vsCode) },
            fallbackNames: ["EyesOnYou", "design-system"],
            baseUp: 90_000_000,
            baseDown: 420_000_000,
            into: aggregator,
            at: now,
            offset: offset,
            resolveRoute: resolveRoute
        )
        offset = seedWorkspaceApp(
            identity: cursor,
            projects: discovered.filter { $0.sources.contains(.cursor) },
            fallbackNames: ["EyesOnYou", "Cultivation"],
            baseUp: 110_000_000,
            baseDown: 520_000_000,
            into: aggregator,
            at: now,
            offset: offset,
            resolveRoute: resolveRoute
        )
        offset = seedWorkspaceApp(
            identity: codex,
            projects: discovered.filter {
                !$0.sources.isDisjoint(with: [.codexDesktop, .codexSession, .codexMonitor])
            },
            fallbackNames: ["Cultivation", "EyesOnYou"],
            baseUp: 140_000_000,
            baseDown: 680_000_000,
            into: aggregator,
            at: now,
            offset: offset,
            resolveRoute: resolveRoute
        )
        offset = seedWorkspaceApp(
            identity: claude,
            projects: discovered.filter { $0.sources.contains(.claudeCode) },
            fallbackNames: ["Architecture review", "Debug NEFilter"],
            baseUp: 80_000_000,
            baseDown: 400_000_000,
            destinationPrefix: "project",
            into: aggregator,
            at: now,
            offset: offset,
            resolveRoute: resolveRoute
        )

        _ = seedOtherApps(into: aggregator, at: now, offset: offset, resolveRoute: resolveRoute)
    }

    // MARK: - Pieces

    @discardableResult
    private static func seedBrowsers(
        into aggregator: TelemetryAggregator,
        at now: Date,
        offset: Int,
        resolveRoute: (AppIdentityKey) -> RouteAction
    ) -> Int {
        let chrome = AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome")
        let safari = AppIdentityKey(teamIdentifier: "APPLE", signingIdentifier: "com.apple.Safari")
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
        var next = offset
        for site in chromeSites {
            seedSite(
                app: chrome,
                displayName: "Chrome",
                host: site.0,
                up: site.1,
                down: site.2,
                at: now,
                offset: next,
                into: aggregator,
                route: resolveRoute(chrome)
            )
            next += 1
        }
        for site in safariSites {
            seedSite(
                app: safari,
                displayName: "Safari",
                host: site.0,
                up: site.1,
                down: site.2,
                at: now,
                offset: next,
                into: aggregator,
                route: resolveRoute(safari)
            )
            next += 1
        }
        return next
    }

    @discardableResult
    private static func seedWorkspaceApp(
        identity: AppSeedIdentity,
        projects: [DiscoveredWorkspace],
        fallbackNames: [String],
        baseUp: UInt64,
        baseDown: UInt64,
        destinationPrefix: String = "project",
        limit: Int = 8,
        into aggregator: TelemetryAggregator,
        at now: Date,
        offset: Int,
        resolveRoute: (AppIdentityKey) -> RouteAction
    ) -> Int {
        let top = Array(projects.prefix(limit))
        let slices: [(String, Double)]
        if top.isEmpty {
            slices = fallbackNames.enumerated().map { index, name in
                let weight = Double(fallbackNames.count - index)
                return ("\(destinationPrefix):\(name)", weight)
            }
        } else {
            slices = top.map { project in
                let weight = Double(max(1, project.sessionCount))
                    + (project.isActive ? 8 : 0)
                    + (project.isPinned ? 4 : 0)
                return (project.destinationKey, weight)
            }
        }

        let totalWeight = slices.reduce(0.0) { $0 + $1.1 }
        guard totalWeight > 0 else { return offset }

        var next = offset
        let route = resolveRoute(identity.key)
        for (index, slice) in slices.enumerated() {
            let share = slice.1 / totalWeight
            // Keep totals near the original demo scale while reflecting relative activity.
            let up = UInt64(Double(baseUp) * share * Double(slices.count))
            let down = UInt64(Double(baseDown) * share * Double(slices.count))
            seedSite(
                app: identity.key,
                displayName: identity.displayName,
                host: slice.0,
                up: max(up, 1_000_000),
                down: max(down, 4_000_000),
                at: now,
                offset: next + index,
                into: aggregator,
                route: route
            )
        }
        return next + slices.count
    }

    @discardableResult
    private static func seedOtherApps(
        into aggregator: TelemetryAggregator,
        at now: Date,
        offset: Int,
        resolveRoute: (AppIdentityKey) -> RouteAction
    ) -> Int {
        let other: [(String, String, String?, UInt64, UInt64, String)] = [
            ("Xcode", "com.apple.dt.Xcode", "APPLE", 198_000_000, 1_120_000_000, "developer.apple.com"),
            ("Discord", "com.hnc.Discord", "53Q6R32WPB", 156_000_000, 823_000_000, "gateway.discord.gg"),
            ("Spotify", "com.spotify.client", "2FNC3A47ZF", 98_000_000, 512_000_000, "audio-fa.scdn.co"),
            ("Slack", "com.tinyspeck.slackmacgap", "BQR82RBBHL", 64_000_000, 342_000_000, "wss-primary.slack.com"),
            ("Telegram", "ru.keepcoder.Telegram", "6N38VWS5BX", 37_000_000, 221_000_000, "api.telegram.org"),
            ("zoom.us", "us.zoom.xos", "BJ4HAAB9B3", 28_000_000, 178_000_000, "zoom.us"),
        ]
        var next = offset
        for sample in other {
            let app = AppIdentityKey(teamIdentifier: sample.2, signingIdentifier: sample.1)
            seedSite(
                app: app,
                displayName: sample.0,
                host: sample.5,
                up: sample.3,
                down: sample.4,
                at: now,
                offset: next,
                into: aggregator,
                route: resolveRoute(app)
            )
            next += 1
        }

        let blockedApp = AppIdentityKey(teamIdentifier: "ANALYTICS", signingIdentifier: "com.example.Analytics")
        let blockedFlow = FlowDescriptor(
            app: blockedApp,
            remoteHostname: "metrics.example.com",
            remotePort: 443,
            openedAt: now
        )
        aggregator.recordOpen(blockedFlow, displayName: "Analytics", route: .direct, firewall: .block)
        return next
    }

    private static func seedSite(
        app: AppIdentityKey,
        displayName: String,
        host: String,
        up: UInt64,
        down: UInt64,
        at: Date,
        offset: Int,
        into aggregator: TelemetryAggregator,
        route: RouteAction
    ) {
        let flow = FlowDescriptor(
            app: app,
            remoteHostname: host,
            remotePort: 443,
            openedAt: at.addingTimeInterval(Double(-offset) - 1)
        )
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
}
