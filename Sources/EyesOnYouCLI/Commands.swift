import Foundation
import EyesOnYouCore
import EyesOnYouRuleEngine
import EyesOnYouStorage
import EyesOnYouProxyCore

// MARK: - Period

enum CLIPeriod: String, CaseIterable {
    case hour, today, day, week, month, year

    var interval: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .today, .day: return 86_400
        case .week: return 604_800
        case .month: return 2_592_000
        case .year: return 31_536_000
        }
    }

    func range(now: Date = Date()) -> (start: Date, end: Date) {
        if self == .today {
            return (Calendar.current.startOfDay(for: now), now)
        }
        return (now.addingTimeInterval(-interval), now)
    }

    static func parse(_ s: String?) throws -> CLIPeriod {
        let raw = (s ?? "week").lowercased()
        guard let p = CLIPeriod(rawValue: raw) else {
            throw CLIError.usage("invalid --period \(raw); use hour|today|day|week|month|year")
        }
        return p
    }
}

// MARK: - Demo catalog (deterministic for agents without live sysext)

enum CLIDemoCatalog {
    /// Shared in-process aggregator so multiple subcommands in one process stay consistent.
    private static let lock = NSLock()
    private static var _aggregator: TelemetryAggregator?
    private static var _store: PolicyStore?

    static func aggregator() -> TelemetryAggregator {
        lock.lock(); defer { lock.unlock() }
        if let a = _aggregator { return a }
        let a = TelemetryAggregator()
        seed(into: a)
        _aggregator = a
        return a
    }

    static func policyStore() -> PolicyStore {
        lock.lock(); defer { lock.unlock() }
        if let s = _store { return s }
        let s = PolicyStore()
        let profile = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        s.assignRoute(
            app: AppIdentityKey(teamIdentifier: "TEAM2", signingIdentifier: "com.anthropic.claude"),
            route: .proxy(profileID: profile)
        )
        s.assignRoute(
            app: AppIdentityKey(teamIdentifier: "EQHXZ8M8AV", signingIdentifier: "com.google.Chrome"),
            route: .direct
        )
        s.upsert(group: AppGroup(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Media",
            memberKeys: [AppIdentityKey(teamIdentifier: "2FNC3A47ZF", signingIdentifier: "com.spotify.client")],
            defaultRoute: .direct
        ))
        s.upsert(rule: NetworkPolicyRule(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            priority: 100,
            app: .any,
            destination: .hostnameSuffix("metrics.example.com"),
            firewall: .block,
            route: .direct,
            note: "Block analytics endpoint"
        ))
        s.upsert(rule: NetworkPolicyRule(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            priority: 50,
            app: .exact(AppIdentityKey(teamIdentifier: "TEAM2", signingIdentifier: "com.anthropic.claude")),
            destination: .hostnameExact("api.anthropic.com"),
            firewall: .allow,
            route: .proxy(profileID: profile),
            note: "Claude via SOCKS5"
        ))
        _store = s
        return s
    }

    private static func seed(into agg: TelemetryAggregator) {
        let now = Date()
        let samples: [(String, String, String?, String, UInt64, UInt64)] = [
            ("Chrome", "com.google.Chrome", "EQHXZ8M8AV", "www.google.com", 120_000_000, 1_200_000_000),
            ("Chrome", "com.google.Chrome", "EQHXZ8M8AV", "github.com", 80_000_000, 900_000_000),
            ("Chrome", "com.google.Chrome", "EQHXZ8M8AV", "www.youtube.com", 200_000_000, 980_000_000),
            ("Safari", "com.apple.Safari", "APPLE", "www.apple.com", 30_000_000, 180_000_000),
            ("Visual Studio Code", "com.microsoft.VSCode", "UBF8T346G9", "project:EyesOnYou", 90_000_000, 420_000_000),
            ("Visual Studio Code", "com.microsoft.VSCode", "UBF8T346G9", "project:design-system", 40_000_000, 190_000_000),
            ("ChatGPT", "com.openai.chat", "2DC432GLL2", "session:Swift concurrency", 40_000_000, 220_000_000),
            ("Claude", "com.anthropic.claude", "TEAM2", "session:Architecture review", 50_000_000, 400_000_000),
            ("Xcode", "com.apple.dt.Xcode", "APPLE", "developer.apple.com", 198_000_000, 1_120_000_000),
            ("Discord", "com.hnc.Discord", "53Q6R32WPB", "gateway.discord.gg", 156_000_000, 823_000_000),
            ("Spotify", "com.spotify.client", "2FNC3A47ZF", "audio-fa.scdn.co", 98_000_000, 512_000_000),
        ]
        for (i, s) in samples.enumerated() {
            let app = AppIdentityKey(teamIdentifier: s.2, signingIdentifier: s.1)
            let flow = FlowDescriptor(
                app: app,
                remoteHostname: s.3,
                remotePort: 443,
                openedAt: now.addingTimeInterval(Double(-i) - 1)
            )
            agg.recordOpen(flow, displayName: s.0, route: .direct)
            agg.recordDelta(
                flowID: flow.id,
                app: app,
                up: s.4,
                down: s.5,
                at: now.addingTimeInterval(Double(-i)),
                route: .direct,
                destinationKey: DestinationKey.make(hostname: s.3, address: nil)
            )
        }
    }
}

// MARK: - Favorites (shared with host app when possible)

enum FavoritesStore {
    static func allKeys() -> [String] {
        if let arr = UserDefaults.standard.array(forKey: EyesOnYouPaths.favoritesDefaultsKey) as? [String] {
            return arr.sorted()
        }
        if let data = try? Data(contentsOf: EyesOnYouPaths.favoritesFile),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr.sorted()
        }
        return []
    }

    static func set(_ keys: [String]) throws {
        let unique = Array(Set(keys)).sorted()
        UserDefaults.standard.set(unique, forKey: EyesOnYouPaths.favoritesDefaultsKey)
        try EyesOnYouPaths.ensureSupportDir()
        let data = try JSONEncoder().encode(unique)
        try data.write(to: EyesOnYouPaths.favoritesFile, options: .atomic)
    }

    static func add(_ signingID: String) throws -> [String] {
        var keys = allKeys()
        // Prefer "team|signing" form; bare signing becomes "|signing" (nil team).
        let normalized = signingID.contains("|") ? signingID : "|\(signingID)"
        if !keys.contains(normalized) && !keys.contains(where: { $0.hasSuffix("|\(signingID)") || $0 == signingID }) {
            keys.append(normalized)
        }
        try set(keys)
        return allKeys()
    }

    static func remove(_ signingID: String) throws -> [String] {
        let keys = allKeys().filter { item in
            if item == signingID { return false }
            if item.hasSuffix("|\(signingID)") { return false }
            if item == "|\(signingID)" { return false }
            return true
        }
        try set(keys)
        return keys
    }

    static func isFavorite(storageKey: String, signingID: String) -> Bool {
        let fav = Set(allKeys())
        if fav.contains(storageKey) { return true }
        if fav.contains("|\(signingID)") { return true }
        if fav.contains(signingID) { return true }
        return fav.contains { $0.hasSuffix("|\(signingID)") }
    }
}

// MARK: - Commands

func cmdStatus(opts: GlobalOptions) throws -> ExitCode {
    let fav = FavoritesStore.allKeys()
    let dbExists = FileManager.default.fileExists(atPath: EyesOnYouPaths.telemetryDB.path)
    let payload: [String: Any] = [
        "ok": true,
        "version": CLIRunner.version,
        "mode": dbExists ? "sqlite" : "demo",
        "paths": [
            "support": EyesOnYouPaths.supportDir.path,
            "telemetry_db": EyesOnYouPaths.telemetryDB.path,
            "favorites_file": EyesOnYouPaths.favoritesFile.path
        ],
        "favorites_count": fav.count,
        "telemetry_db_present": dbExists,
        "notes": [
            "Without a live system extension, apps/traffic use a deterministic demo seed.",
            "Pass --json for stable machine parsing."
        ]
    ]
    emit(payload, json: opts.json) {
        print("eyesonyou \(CLIRunner.version)")
        print("mode: \(dbExists ? "sqlite" : "demo")")
        print("support: \(EyesOnYouPaths.supportDir.path)")
        print("favorites: \(fav.count)")
        print("telemetry_db: \(dbExists ? "present" : "missing (demo)")")
    }
    return .ok
}

func cmdPaths(opts: GlobalOptions) -> ExitCode {
    let payload: [String: Any] = [
        "ok": true,
        "support": EyesOnYouPaths.supportDir.path,
        "telemetry_db": EyesOnYouPaths.telemetryDB.path,
        "favorites_file": EyesOnYouPaths.favoritesFile.path,
        "favorites_defaults_key": EyesOnYouPaths.favoritesDefaultsKey
    ]
    emit(payload, json: opts.json) {
        print(EyesOnYouPaths.supportDir.path)
        print(EyesOnYouPaths.telemetryDB.path)
        print(EyesOnYouPaths.favoritesFile.path)
    }
    return .ok
}

func cmdApps(opts: GlobalOptions) throws -> ExitCode {
    let period = try CLIPeriod.parse(opts.flag("period"))
    let limit = opts.flagInt("limit", default: 20)
    let range = period.range()
    let agg = CLIDemoCatalog.aggregator()
    var rows = agg.topApps(
        from: range.start,
        to: range.end,
        limit: 100,
        preferredGranularity: .oneMinute,
        includeSitesForBrowsers: true
    )
    // Favorites first
    rows.sort { a, b in
        let af = FavoritesStore.isFavorite(storageKey: a.app.storageKey, signingID: a.app.signingIdentifier)
        let bf = FavoritesStore.isFavorite(storageKey: b.app.storageKey, signingID: b.app.signingIdentifier)
        if af != bf { return af && !bf }
        return a.totals.totalBytes > b.totals.totalBytes
    }
    rows = Array(rows.prefix(limit))

    let apps: [[String: Any]] = rows.map { snap in
        [
            "signing_id": snap.app.signingIdentifier,
            "team_id": snap.app.teamIdentifier as Any,
            "display_name": snap.displayName,
            "bytes_up": snap.totals.bytesUp,
            "bytes_down": snap.totals.bytesDown,
            "bytes_total": snap.totals.totalBytes,
            "flows_opened": snap.totals.flowsOpened,
            "favorite": FavoritesStore.isFavorite(
                storageKey: snap.app.storageKey,
                signingID: snap.app.signingIdentifier
            ),
            "is_browser": snap.isBrowser,
            "drill_kind": DrillableIdentity.segmentKind(for: snap.app).rawValue,
            "segments": snap.sites.prefix(12).map { site in
                [
                    "key": site.destinationKey,
                    "title": site.hostname,
                    "kind": site.kind.rawValue,
                    "bytes_up": site.totals.bytesUp,
                    "bytes_down": site.totals.bytesDown
                ] as [String: Any]
            }
        ]
    }

    let payload: [String: Any] = [
        "ok": true,
        "period": period.rawValue,
        "from": ISO8601DateFormatter().string(from: range.start),
        "to": ISO8601DateFormatter().string(from: range.end),
        "count": apps.count,
        "apps": apps
    ]
    emit(payload, json: opts.json) {
        print("period=\(period.rawValue) count=\(apps.count)")
        for (i, a) in apps.enumerated() {
            let name = a["display_name"] as? String ?? "?"
            let total = a["bytes_total"] as? UInt64 ?? 0
            let fav = (a["favorite"] as? Bool == true) ? " ★" : ""
            print(String(format: "%2d. %@%@  %@", i + 1, name, fav, ByteFormat.string(for: total)))
        }
    }
    return .ok
}

func cmdTraffic(opts: GlobalOptions) throws -> ExitCode {
    let period = try CLIPeriod.parse(opts.flag("period"))
    let range = period.range()
    let agg = CLIDemoCatalog.aggregator()
    let appFlag = opts.flag("app")
    let appKey: AppIdentityKey? = appFlag.map {
        AppIdentityKey(teamIdentifier: opts.flag("team"), signingIdentifier: $0)
    }
    let totals = agg.totals(for: appKey, from: range.start, to: range.end, preferredGranularity: .oneMinute)
    let payload: [String: Any] = [
        "ok": true,
        "period": period.rawValue,
        "app": appFlag as Any,
        "from": ISO8601DateFormatter().string(from: range.start),
        "to": ISO8601DateFormatter().string(from: range.end),
        "bytes_up": totals.bytesUp,
        "bytes_down": totals.bytesDown,
        "bytes_total": totals.totalBytes,
        "flows_opened": totals.flowsOpened,
        "flows_closed": totals.flowsClosed,
        "flows_blocked": totals.flowsBlocked
    ]
    emit(payload, json: opts.json) {
        print("period=\(period.rawValue) app=\(appFlag ?? "*")")
        print("up=\(ByteFormat.string(for: totals.bytesUp)) down=\(ByteFormat.string(for: totals.bytesDown)) total=\(ByteFormat.string(for: totals.totalBytes))")
        print("flows opened=\(totals.flowsOpened) closed=\(totals.flowsClosed) blocked=\(totals.flowsBlocked)")
    }
    return .ok
}

func cmdEvaluate(opts: GlobalOptions) throws -> ExitCode {
    guard let appID = opts.flag("app"), !appID.isEmpty else {
        throw CLIError.usage("evaluate requires --app <signing.id>")
    }
    guard let host = opts.flag("host"), !host.isEmpty else {
        throw CLIError.usage("evaluate requires --host <hostname>")
    }
    let port = UInt16(opts.flagInt("port", default: 443))
    let team = opts.flag("team")
    let app = AppIdentityKey(teamIdentifier: team, signingIdentifier: appID)
    let flow = FlowDescriptor(
        app: app,
        direction: .outbound,
        transport: .tcp,
        remoteHostname: host,
        remotePort: port
    )
    let store = CLIDemoCatalog.policyStore()
    let snap = store.compileSnapshot()
    let fw = snap.evaluateFirewall(flow)
    let route = snap.evaluateRoute(flow)
    let claim = ProxyRouteEvaluator.shouldClaimFlow(flow, snapshot: snap)

    let payload: [String: Any] = [
        "ok": true,
        "flow": [
            "app": appID,
            "team": team as Any,
            "host": host,
            "port": Int(port)
        ],
        "firewall": [
            "action": firewallName(fw.action),
            "matched_rule": fw.matchedRuleID?.uuidString as Any
        ],
        "route": [
            "action": routeName(route.action),
            "matched_rule": route.matchedRuleID?.uuidString as Any
        ],
        "proxy_should_claim": claim.claim,
        "rule_generation": snap.generation,
        "fail_open": true
    ]
    emit(payload, json: opts.json) {
        print("app=\(appID) host=\(host):\(port)")
        print("firewall=\(firewallName(fw.action)) route=\(routeName(route.action)) claim=\(claim.claim)")
    }
    return .ok
}

func cmdRules(opts: GlobalOptions) throws -> ExitCode {
    let store = CLIDemoCatalog.policyStore()
    let rules = store.allRules()
    let groups = store.allGroups()
    let payload: [String: Any] = [
        "ok": true,
        "generation": store.currentGeneration,
        "rules": rules.map { r -> [String: Any] in
            [
                "id": r.id.uuidString,
                "enabled": r.enabled,
                "priority": r.priority,
                "note": r.note as Any,
                "firewall": firewallName(r.firewall),
                "route": routeName(r.route),
                "destination": destinationDescription(r.destination)
            ]
        },
        "groups": groups.map { g -> [String: Any] in
            [
                "id": g.id.uuidString,
                "name": g.name,
                "members": g.memberKeys.map(\.signingIdentifier),
                "default_route": routeName(g.defaultRoute)
            ]
        }
    ]
    emit(payload, json: opts.json) {
        print("generation=\(store.currentGeneration) rules=\(rules.count) groups=\(groups.count)")
        for r in rules {
            print("- [\(r.priority)] \(r.note ?? r.id.uuidString) fw=\(firewallName(r.firewall)) route=\(routeName(r.route))")
        }
    }
    return .ok
}

func cmdSearch(opts: GlobalOptions) throws -> ExitCode {
    let q = (opts.positionals.first ?? opts.flag("query") ?? "").trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { throw CLIError.usage("search requires a query: eyesonyou search <query>") }
    let needle = q.lowercased()
    let period = try CLIPeriod.parse(opts.flag("period") ?? "week")
    let range = period.range()
    let apps = CLIDemoCatalog.aggregator().topApps(
        from: range.start, to: range.end, limit: 50, includeSitesForBrowsers: true
    )
    var hits: [[String: Any]] = []
    for a in apps {
        if a.displayName.lowercased().contains(needle)
            || a.app.signingIdentifier.lowercased().contains(needle) {
            hits.append([
                "kind": "app",
                "title": a.displayName,
                "subtitle": a.app.signingIdentifier,
                "signing_id": a.app.signingIdentifier
            ])
        }
        for s in a.sites where s.hostname.lowercased().contains(needle) || s.destinationKey.lowercased().contains(needle) {
            hits.append([
                "kind": "segment",
                "title": s.hostname,
                "subtitle": a.displayName,
                "signing_id": a.app.signingIdentifier,
                "segment_kind": s.kind.rawValue
            ])
        }
    }
    for r in CLIDemoCatalog.policyStore().allRules() {
        let note = (r.note ?? "").lowercased()
        let dest = destinationDescription(r.destination).lowercased()
        if note.contains(needle) || dest.contains(needle) {
            hits.append([
                "kind": "rule",
                "title": r.note ?? r.id.uuidString,
                "subtitle": destinationDescription(r.destination)
            ])
        }
    }
    let payload: [String: Any] = [
        "ok": true,
        "query": q,
        "count": hits.count,
        "hits": Array(hits.prefix(30))
    ]
    emit(payload, json: opts.json) {
        print("query=\(q) hits=\(hits.count)")
        for h in hits.prefix(20) {
            print("- [\(h["kind"] ?? "?")] \(h["title"] ?? "")  \(h["subtitle"] ?? "")")
        }
    }
    return .ok
}

func cmdFavorites(opts: GlobalOptions) throws -> ExitCode {
    let sub = (opts.positionals.first ?? "list").lowercased()
    switch sub {
    case "list", "ls":
        let keys = FavoritesStore.allKeys()
        let payload: [String: Any] = ["ok": true, "favorites": keys, "count": keys.count]
        emit(payload, json: opts.json) {
            if keys.isEmpty { print("(none)") }
            else { keys.forEach { print($0) } }
        }
        return .ok
    case "add":
        guard let id = opts.positionals.dropFirst().first ?? opts.flag("app"), !id.isEmpty else {
            throw CLIError.usage("favorites add <signing.id>")
        }
        let list = try FavoritesStore.add(id)
        emit(["ok": true, "added": id, "favorites": list], json: opts.json) {
            print("added \(id)")
            list.forEach { print($0) }
        }
        return .ok
    case "remove", "rm", "delete":
        guard let id = opts.positionals.dropFirst().first ?? opts.flag("app"), !id.isEmpty else {
            throw CLIError.usage("favorites remove <signing.id>")
        }
        let list = try FavoritesStore.remove(id)
        emit(["ok": true, "removed": id, "favorites": list], json: opts.json) {
            print("removed \(id)")
            list.forEach { print($0) }
        }
        return .ok
    default:
        throw CLIError.usage("favorites subcommand must be list|add|remove")
    }
}

// MARK: - Format helpers

private func firewallName(_ a: FirewallAction) -> String {
    switch a {
    case .inherit: return "inherit"
    case .observe: return "observe"
    case .allow: return "allow"
    case .block: return "block"
    }
}

private func routeName(_ a: RouteAction) -> String {
    switch a {
    case .inherit: return "inherit"
    case .direct: return "direct"
    case .systemProxy: return "system_proxy"
    case .proxy(let id): return "proxy:\(id.uuidString)"
    }
}

private func destinationDescription(_ d: DestinationMatcher) -> String {
    switch d {
    case .any: return "any"
    case .hostnameExact(let h): return "host:\(h)"
    case .hostnameSuffix(let s): return "suffix:\(s)"
    case .ip(let a): return "ip:\(a)"
    case .cidr(let n, let p): return "cidr:\(n)/\(p)"
    }
}
