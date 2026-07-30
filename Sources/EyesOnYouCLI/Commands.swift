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

// MARK: - Live data sources (shared with the host app)

/// Read-only access to the same SQLite database and policy file the app writes.
///
/// The CLI never invents traffic: when the app has not recorded anything yet, these
/// return empty results and the commands say so.
enum CLIDataSource {
    private static let lock = NSLock()
    private static var _store: TelemetryStore?
    private static var _policy: PolicyStore?

    /// Telemetry database, or `nil` when it does not exist / cannot be opened.
    static func telemetryStore() -> TelemetryStore? {
        lock.lock(); defer { lock.unlock() }
        if let store = _store { return store }
        guard FileManager.default.fileExists(atPath: EyesOnYouPaths.telemetryDB.path) else {
            return nil
        }
        let store = try? TelemetryStore(
            path: EyesOnYouPaths.telemetryDB.path,
            mode: .readOnly
        )
        _store = store
        return store
    }

    /// Policy configuration as saved by the app; empty when nothing is configured.
    static func policyStore() -> PolicyStore {
        lock.lock(); defer { lock.unlock() }
        if let policy = _policy { return policy }
        let policy = PolicyStore()
        if let archive = try? PolicyArchiveStore.load() {
            archive.apply(to: policy)
        }
        _policy = policy
        return policy
    }

    static func proxyProfiles() -> [ProxyProfile] {
        guard let archive = try? PolicyArchiveStore.load() else { return [] }
        return archive.proxyProfiles
    }

    /// Granularity that best covers a range, matching how the app buckets data.
    static func granularity(from: Date, to: Date) -> BucketGranularity {
        let span = max(1, Int(to.timeIntervalSince(from)))
        let chosen = TelemetryAggregator.chooseGranularity(spanSeconds: span)
        // Second-level buckets are live-only and never persisted.
        return chosen == .oneSecond ? .oneMinute : chosen
    }

    /// An aggregator hydrated from persisted buckets, so the CLI reuses the same
    /// ranking and per-destination logic as the dashboard.
    ///
    /// Empty — not seeded — when nothing has been recorded yet.
    static func aggregator(from: Date, to: Date) -> (TelemetryAggregator, BucketGranularity) {
        let granularity = granularity(from: from, to: to)
        let aggregator = TelemetryAggregator()
        guard let store = telemetryStore() else { return (aggregator, granularity) }
        if let buckets = try? store.loadBuckets(granularity: granularity, from: from, to: to) {
            aggregator.importBuckets(buckets)
        }
        if let names = try? store.displayNames() {
            aggregator.importDisplayNames(names)
        }
        return (aggregator, granularity)
    }

    /// True when the database exists and holds at least one bucket.
    static func hasRecordedData() -> Bool {
        guard let store = telemetryStore(), let stats = try? store.statistics() else {
            return false
        }
        return stats.buckets > 0
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
    let stats = CLIDataSource.telemetryStore().flatMap { try? $0.statistics() }
    let iso = ISO8601DateFormatter()

    var telemetry: [String: Any] = [
        "database_present": dbExists,
        "buckets": stats?.buckets ?? 0,
        "apps": stats?.apps ?? 0
    ]
    if let earliest = stats?.earliest { telemetry["earliest"] = iso.string(from: earliest) }
    if let latest = stats?.latest { telemetry["latest"] = iso.string(from: latest) }

    let policyExists = FileManager.default.fileExists(atPath: PolicyArchiveStore.defaultURL.path)
    let payload: [String: Any] = [
        "ok": true,
        "version": CLIRunner.version,
        "paths": [
            "support": EyesOnYouPaths.supportDir.path,
            "telemetry_db": EyesOnYouPaths.telemetryDB.path,
            "policy_file": PolicyArchiveStore.defaultURL.path,
            "favorites_file": EyesOnYouPaths.favoritesFile.path
        ],
        "favorites_count": fav.count,
        "policy_file_present": policyExists,
        "telemetry": telemetry,
        "notes": [
            "All traffic figures come from what the host app recorded; there is no seeded data.",
            "An empty result means nothing has been captured yet — run the app to record.",
            "Pass --json for stable machine parsing."
        ]
    ]
    emit(payload, json: opts.json) {
        print("eyesonyou \(CLIRunner.version)")
        print("support: \(EyesOnYouPaths.supportDir.path)")
        print("favorites: \(fav.count)")
        print("policy file: \(policyExists ? "present" : "none")")
        if let stats, stats.buckets > 0 {
            let span = [stats.earliest, stats.latest]
                .compactMap { $0.map { iso.string(from: $0) } }
                .joined(separator: " … ")
            print("telemetry: \(stats.buckets) buckets, \(stats.apps) apps  \(span)")
        } else {
            print("telemetry: no data recorded yet")
        }
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

func cmdWorkspaces(opts: GlobalOptions) throws -> ExitCode {
    let limit = opts.flagInt("limit", default: 40)
    let sourceRaw = (opts.flag("source") ?? "all").lowercased()
    let appFilter = opts.flag("app")

    // Discover broadly, then filter/limit — source filters must not see a pre-truncated global top-N.
    let options = WorkspaceDiscoveryOptions(limit: 0)
    var rows: [DiscoveredWorkspace]
    if let appFilter, !appFilter.isEmpty {
        rows = WorkspaceDiscovery.projects(forSigningIdentifier: appFilter, options: options)
    } else {
        rows = WorkspaceDiscovery.discover(options: options)
        rows = try filterWorkspaces(rows, source: sourceRaw)
    }
    rows = Array(rows.prefix(max(limit, 1)))

    let payload: [String: Any] = [
        "ok": true,
        "source": sourceRaw,
        "count": rows.count,
        "workspaces": rows.map { workspaceJSON($0) }
    ]
    emit(payload, json: opts.json) {
        if rows.isEmpty {
            print("(no workspaces discovered)")
            return
        }
        for row in rows {
            let sources = row.sources.map(\.rawValue).sorted().joined(separator: ",")
            print("\(row.name)\t\(row.path)\t\(sources)\tsessions=\(row.sessionCount)")
        }
    }
    return .ok
}

private func filterWorkspaces(_ rows: [DiscoveredWorkspace], source: String) throws -> [DiscoveredWorkspace] {
    switch source {
    case "all", "":
        return rows
    case "codex":
        return rows.filter { !$0.sources.isDisjoint(with: [.codexDesktop, .codexSession, .codexMonitor]) }
    case "codexdesktop":
        return rows.filter { $0.sources.contains(.codexDesktop) }
    case "codexsession", "sessions":
        return rows.filter { $0.sources.contains(.codexSession) }
    case "codexmonitor", "monitor":
        return rows.filter { $0.sources.contains(.codexMonitor) }
    case "cursor":
        return rows.filter { $0.sources.contains(.cursor) }
    case "vscode", "code":
        return rows.filter { $0.sources.contains(.vsCode) }
    case "claude", "claudecode":
        return rows.filter { $0.sources.contains(.claudeCode) }
    default:
        throw CLIError.usage(
            "invalid --source \(source); use all|codex|cursor|vscode|claude|codexmonitor"
        )
    }
}

private func workspaceJSON(_ row: DiscoveredWorkspace) -> [String: Any] {
    var dict: [String: Any] = [
        "name": row.name,
        "path": row.path,
        "destination_key": row.destinationKey,
        "sources": row.sources.map(\.rawValue).sorted(),
        "primary_source": row.primarySource.rawValue,
        "session_count": row.sessionCount,
        "pinned": row.isPinned,
        "active": row.isActive
    ]
    if let last = row.lastActiveAt {
        dict["last_active_at"] = ISO8601DateFormatter().string(from: last)
    }
    return dict
}

/// Live per-process attribution: which app owns each socket, and which project it is
/// working in. This is the ground truth the dashboard's sub-project rows are built on.
func cmdAttribution(opts: GlobalOptions) throws -> ExitCode {
    let limit = opts.flagInt("limit", default: 25)
    let includeAll = opts.flag("all") != nil || opts.positionals.contains("all")

    let discoveryOptions = WorkspaceDiscoveryOptions(limit: 0)
    let resolver = ProjectResolver(workspaces: WorkspaceDiscovery.discover(options: discoveryOptions))
    let attributor = LiveAttributionResolver(
        projectResolver: resolver,
        discoveryOptions: discoveryOptions
    )

    let snapshot = ActiveAppSocketSampler.sampleTCPEstablished()
    let samples = includeAll ? snapshot.processes : snapshot.processes.filter { !$0.isProxyProcess }
    let rows = attributor.attribute(samples)
        .sorted { lhs, rhs in
            if lhs.weightedConnections != rhs.weightedConnections {
                return lhs.weightedConnections > rhs.weightedConnections
            }
            return lhs.pid < rhs.pid
        }
        .prefix(max(limit, 1))

    let payload: [String: Any] = [
        "ok": true,
        "count": rows.count,
        "proxy_ports": snapshot.proxyPorts,
        "processes": rows.map { attributionJSON($0) }
    ]
    emit(payload, json: opts.json) {
        if rows.isEmpty {
            print("(no established TCP sockets attributed)")
            return
        }
        for row in rows {
            let project = row.project.map { "\($0.name) [\(row.confidence?.rawValue ?? "?")]" } ?? "-"
            let rolled = row.isRolledUp ? " ^owner" : ""
            print("\(row.pid)\t\(row.displayName)\(rolled)\t\(row.app.signingIdentifier)\t\(project)\tconns=\(row.weightedConnections)")
        }
    }
    return .ok
}

private func attributionJSON(_ row: AttributedProcess) -> [String: Any] {
    var dict: [String: Any] = [
        "pid": Int(row.pid),
        "command": row.command,
        "app": row.app.signingIdentifier,
        "display_name": row.displayName,
        "rolled_up_to_owner": row.isRolledUp,
        "connections_via_proxy": row.viaProxyConnections,
        "connections_direct": row.directConnections,
        "remote_hosts": row.remoteHosts
    ]
    if let project = row.project {
        dict["project"] = [
            "name": project.name,
            "path": project.path,
            "marker": project.marker as Any,
            "destination_key": project.destinationKey
        ]
        dict["project_confidence"] = row.confidence?.rawValue ?? "unknown"
    }
    return dict
}

func cmdApps(opts: GlobalOptions) throws -> ExitCode {
    let period = try CLIPeriod.parse(opts.flag("period"))
    let limit = opts.flagInt("limit", default: 20)
    let range = period.range()
    let (agg, granularity) = CLIDataSource.aggregator(from: range.start, to: range.end)
    let routeShares = agg.routeByteShareByApp(
        from: range.start,
        to: range.end,
        preferredGranularity: granularity
    )
    var rows = agg.topApps(
        from: range.start,
        to: range.end,
        limit: 100,
        preferredGranularity: granularity,
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
        let proxyPercent: Any = routeShares[snap.app].flatMap { split -> Int? in
            let total = split.direct &+ split.proxied
            guard total > 0 else { return nil }
            return Int((Double(split.proxied) / Double(total) * 100).rounded())
        } as Any? ?? NSNull()
        return [
            "signing_id": snap.app.signingIdentifier,
            "team_id": snap.app.teamIdentifier as Any,
            "display_name": snap.displayName,
            "bytes_up": snap.totals.bytesUp,
            "bytes_down": snap.totals.bytesDown,
            "bytes_total": snap.totals.totalBytes,
            "proxy_percent": proxyPercent,
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
    let (agg, granularity) = CLIDataSource.aggregator(from: range.start, to: range.end)
    let appFlag = opts.flag("app")
    let appKey: AppIdentityKey? = appFlag.map {
        AppIdentityKey(teamIdentifier: opts.flag("team"), signingIdentifier: $0)
    }
    let totals = agg.totals(
        for: appKey,
        from: range.start,
        to: range.end,
        preferredGranularity: granularity
    )
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
    let store = CLIDataSource.policyStore()
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
    let store = CLIDataSource.policyStore()
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
    let (agg, granularity) = CLIDataSource.aggregator(from: range.start, to: range.end)
    let apps = agg.topApps(
        from: range.start,
        to: range.end,
        limit: 50,
        preferredGranularity: granularity,
        includeSitesForBrowsers: true
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
    for r in CLIDataSource.policyStore().allRules() {
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

// MARK: - Route policy (agent-writable)

/// `route list|set|clear` — read and edit the per-app routes the app enforces.
///
/// Writes the same `policy.json` the GUI uses, so a rule set from the CLI takes
/// effect in a running app (it reloads on change) and vice versa.
func cmdRoute(opts: GlobalOptions) throws -> ExitCode {
    let sub = (opts.positionals.first ?? "list").lowercased()
    let store = CLIDataSource.policyStore()

    switch sub {
    case "list", "ls":
        let rows = store.allAssignments()
            .map { (app: $0.key, route: routeName($0.value)) }
            .sorted { $0.app.signingIdentifier < $1.app.signingIdentifier }
        let payload: [String: Any] = [
            "ok": true,
            "count": rows.count,
            "routes": rows.map { ["app": $0.app.signingIdentifier, "route": $0.route] }
        ]
        emit(payload, json: opts.json) {
            if rows.isEmpty {
                print("(no per-app routes configured; every app follows the system)")
                return
            }
            rows.forEach { print("\($0.app.signingIdentifier)\t\($0.route)") }
        }
        return .ok

    case "set":
        guard let app = opts.flag("app"), !app.isEmpty else {
            throw CLIError.usage("route set --app <signing.id> --route direct|system|proxy|inherit")
        }
        guard let raw = opts.flag("route")?.lowercased() else {
            throw CLIError.usage("route set requires --route direct|system|proxy|inherit")
        }
        let action = try parseRouteAction(raw, profileFlag: opts.flag("profile"))
        let key = AppIdentityKey(teamIdentifier: opts.flag("team"), signingIdentifier: app)
        store.assignRoute(app: key, route: action)
        try saveRoutePolicy(store)
        emit(["ok": true, "app": app, "route": routeName(action)], json: opts.json) {
            print("\(app) → \(routeName(action))")
        }
        return .ok

    case "clear":
        guard let app = opts.flag("app"), !app.isEmpty else {
            throw CLIError.usage("route clear --app <signing.id>")
        }
        let key = AppIdentityKey(teamIdentifier: opts.flag("team"), signingIdentifier: app)
        store.assignRoute(app: key, route: .inherit)
        try saveRoutePolicy(store)
        emit(["ok": true, "app": app, "route": "inherit"], json: opts.json) {
            print("\(app) → inherit (follow system)")
        }
        return .ok

    case "block", "allow":
        guard let app = opts.flag("app"), !app.isEmpty else {
            throw CLIError.usage("route \(sub) --app <signing.id> [--host <suffix>]")
        }
        let key = AppIdentityKey(teamIdentifier: opts.flag("team"), signingIdentifier: app)
        let destination: DestinationMatcher = opts.flag("host").map { .hostnameSuffix($0) } ?? .any
        // Remove any prior CLI rule for this app+destination, then add the new one.
        let note = "cli"
        let existing = store.allRules().filter { rule in
            guard rule.note == note else { return false }
            if case .exact(let k) = rule.app, k == key {
                return destinationDescription(rule.destination) == destinationDescription(destination)
            }
            return false
        }
        existing.forEach { store.removeRule(id: $0.id) }
        if sub == "block" {
            store.upsert(rule: NetworkPolicyRule(
                priority: 100,
                app: .exact(key),
                destination: destination,
                firewall: .block,
                route: .inherit,
                note: note
            ))
        }
        try saveRoutePolicy(store)
        emit([
            "ok": true, "app": app, "firewall": sub,
            "destination": destinationDescription(destination)
        ], json: opts.json) {
            print("\(app) \(sub) \(destinationDescription(destination))")
        }
        return .ok

    default:
        throw CLIError.usage("route subcommand must be list|set|clear|block|allow")
    }
}

private func parseRouteAction(_ raw: String, profileFlag: String?) throws -> RouteAction {
    switch raw {
    case "direct":
        return .direct
    case "system", "system_proxy", "systemproxy":
        return .systemProxy
    case "inherit", "follow":
        return .inherit
    case "proxy":
        // Use the named profile when given, else the first configured one.
        let profiles = CLIDataSource.proxyProfiles()
        let profile = profileFlag.flatMap { flag in
            profiles.first { $0.name == flag || $0.id.uuidString == flag }
        } ?? profiles.first
        guard let profile else {
            throw CLIError.usage("no proxy profile configured; use --route system instead")
        }
        return .proxy(profileID: profile.id)
    default:
        throw CLIError.usage("invalid --route \(raw); use direct|system|proxy|inherit")
    }
}

private func saveRoutePolicy(_ store: PolicyStore) throws {
    let archive = PolicyArchive.capture(from: store, proxyProfiles: CLIDataSource.proxyProfiles())
    do {
        try PolicyArchiveStore.save(archive)
    } catch {
        throw CLIError.runtime("could not save policy: \(error)")
    }
}

// MARK: - Enforcement (headless, agent-testable)

/// `enforce status|serve|restore` — run and verify the local enforcement proxy
/// without the GUI.
///
/// `serve` is the piece that makes this testable on a real machine: it binds the
/// proxy, prints the port immediately, and streams one JSON line per completed flow —
/// so an agent can `curl --proxy 127.0.0.1:<port>` and assert on what happened.
/// System-proxy takeover stays opt-in behind `--system-proxy` so a test run never
/// touches the machine's network settings by accident.
func cmdEnforce(opts: GlobalOptions) throws -> ExitCode {
    let sub = (opts.positionals.first ?? "status").lowercased()
    let controller = SystemProxyController(backupURL: EyesOnYouPaths.systemProxyBackup)

    switch sub {
    case "status":
        let services = controller.enabledServices()
        let states = services.map { controller.captureState(service: $0) }
        let live = states.map { state -> [String: Any] in
            [
                "service": state.service,
                "secure_enabled": state.secureEnabled,
                "secure_host": state.secureHost,
                "secure_port": state.securePort
            ]
        }
        let backup = controller.loadBackup()
        let merged = SystemProxyReader.current()
        // The port our takeover wrote — visible in the networksetup layer even
        // when a VPN's NE-provided settings shadow it in the merged config.
        let localPort = states.lazy
            .filter { $0.secureEnabled && $0.secureHost == "127.0.0.1" }
            .compactMap { UInt16(exactly: $0.securePort) }
            .first
        var shadowedBy: String?
        if controller.hasPendingBackup, let localPort,
           case .shadowed(let observed) = SystemProxyController.verifyTakeover(
               localPort: localPort, merged: merged
           ) {
            shadowedBy = observed ?? "unknown proxy"
        }
        var payload: [String: Any] = [
            "ok": true,
            "takeover_active": controller.hasPendingBackup,
            "backup_file": EyesOnYouPaths.systemProxyBackup.path,
            "services": live,
            "merged_proxy": merged.primaryEndpointLabel as Any,
            "shadowed_by_vpn": shadowedBy as Any
        ]
        if let upstream = backup?.upstream {
            payload["saved_upstream"] = ["host": upstream.host, "port": Int(upstream.port)]
        }
        emit(payload, json: opts.json) {
            print("takeover active: \(controller.hasPendingBackup ? "yes" : "no")")
            for entry in live {
                let on = (entry["secure_enabled"] as? Bool == true) ? "on" : "off"
                print("\(entry["service"] as? String ?? "?")\t\(on)\t\(entry["secure_host"] as? String ?? "")" +
                      ":\(entry["secure_port"] as? Int ?? 0)")
            }
            if let upstream = backup?.upstream {
                print("saved upstream: \(upstream.host):\(upstream.port)")
            }
            if let shadowedBy {
                print("WARNING: takeover is shadowed by \(shadowedBy) — a VPN app's proxy " +
                      "settings win while its tunnel is up; flows will not reach EyesOnYou " +
                      "until it disconnects")
            }
        }
        return .ok

    case "restore":
        let restored = controller.restoreIfNeeded()
        emit(["ok": true, "restored": restored], json: opts.json) {
            print(restored ? "restored previous system proxy settings" : "nothing to restore")
        }
        return .ok

    case "serve":
        return try runEnforcementServer(opts: opts, controller: controller)

    default:
        throw CLIError.usage("enforce subcommand must be status|serve|restore")
    }
}

private func runEnforcementServer(
    opts: GlobalOptions,
    controller: SystemProxyController
) throws -> ExitCode {
    let seconds = Double(opts.flagInt("seconds", default: 20))
    let requestedPort = UInt16(exactly: opts.flagInt("port", default: 0)) ?? 0
    let takeOverSystemProxy = opts.flagBool("system-proxy")

    // Upstream: an explicit flag, else whatever the system proxy points at today.
    let upstream: ProxyUpstream? = try resolveUpstream(opts: opts, controller: controller)

    let store = CLIDataSource.policyStore()
    let box = LocalProxyRulesBox(LocalProxyRules(
        snapshot: store.compileSnapshot(),
        systemUpstream: upstream,
        profiles: CLIDataSource.proxyProfiles()
    ))

    let flows = FlowLog()
    let emitJSON = opts.json
    let ready = DispatchSemaphore(value: 0)
    let portBox = AtomicPort()

    let server = LocalProxyServer(
        rules: box,
        onFlow: { event in
            flows.append(event)
            // Stream immediately so a caller can assert without waiting for exit.
            let line: [String: Any] = [
                "app": event.app.signingIdentifier,
                "display_name": event.displayName,
                "host": event.host,
                "port": Int(event.port),
                "action": actionName(event.action),
                "bytes_up": event.bytesUp,
                "bytes_down": event.bytesDown
            ]
            if emitJSON,
               let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                print("\(event.displayName)\t\(event.host):\(event.port)\t\(actionName(event.action))" +
                      "\tup=\(event.bytesUp) down=\(event.bytesDown)")
            }
            fflush(stdout)
        },
        onState: { state in
            if case .running(let port) = state {
                portBox.set(port)
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
    )

    server.start(preferredPort: requestedPort)
    guard ready.wait(timeout: .now() + 5) == .success, portBox.get() != 0 else {
        throw CLIError.runtime("proxy failed to start")
    }
    let port = portBox.get()

    var tookOver = false
    if takeOverSystemProxy {
        do {
            _ = try controller.takeOver(localPort: port)
            tookOver = true
        } catch {
            server.stop()
            throw CLIError.runtime("system proxy takeover failed: \(error)")
        }
    }

    // `networksetup` succeeding is not enough: a NetworkExtension VPN's proxy
    // settings shadow ours in the merged config apps actually read. Poll briefly
    // (the merge is asynchronous), then report what apps really see.
    var takeoverConfirmed = false
    var shadowedBy: String?
    if tookOver {
        var verification = SystemProxyController.verifyTakeover(
            localPort: port, merged: SystemProxyReader.current()
        )
        var attempt = 0
        while verification != .active, attempt < 20 {
            Thread.sleep(forTimeInterval: 0.1)
            verification = SystemProxyController.verifyTakeover(
                localPort: port, merged: SystemProxyReader.current()
            )
            attempt += 1
        }
        switch verification {
        case .active: takeoverConfirmed = true
        case .shadowed(let observed): shadowedBy = observed ?? "unknown proxy"
        case .notApplied: break
        }
    }

    // Announce the port first so the caller can start sending traffic.
    let header: [String: Any] = [
        "ok": true,
        "event": "listening",
        "port": Int(port),
        "seconds": seconds,
        "system_proxy_takeover": tookOver,
        "system_proxy_confirmed": takeoverConfirmed,
        "shadowed_by_vpn": shadowedBy as Any,
        "upstream": upstream.map { ["host": $0.host, "port": Int($0.port)] } as Any
    ]
    emit(header, json: opts.json) {
        print("listening on 127.0.0.1:\(port) for \(Int(seconds))s" +
              (tookOver ? " (system proxy taken over)" : "") +
              (upstream.map { " upstream=\($0.host):\($0.port)" } ?? " upstream=none"))
        if let shadowedBy {
            print("WARNING: takeover is shadowed by \(shadowedBy) — a VPN app's proxy " +
                  "settings win while its tunnel is up; flows will not reach EyesOnYou " +
                  "until it disconnects")
        } else if tookOver, !takeoverConfirmed {
            print("WARNING: macOS has not activated the EyesOnYou proxy in the merged config")
        }
    }
    fflush(stdout)

    // Restore on SIGINT/SIGTERM so an interrupted run never strands the machine.
    let restoreOnce = { (reason: String) in
        if tookOver { _ = controller.restoreIfNeeded() }
        server.stop()
        _ = reason
    }
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    for source in [sigintSource, sigtermSource] {
        source.setEventHandler {
            restoreOnce("signal")
            exit(0)
        }
        source.resume()
    }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    Thread.sleep(forTimeInterval: seconds)
    restoreOnce("timeout")

    let summary = flows.summary()
    emit([
        "ok": true,
        "event": "summary",
        "flows": summary.count,
        "blocked": summary.blocked,
        "direct": summary.direct,
        "proxied": summary.proxied,
        "bytes_up": summary.up,
        "bytes_down": summary.down
    ], json: opts.json) {
        print("flows=\(summary.count) blocked=\(summary.blocked) direct=\(summary.direct) " +
              "proxied=\(summary.proxied) up=\(summary.up) down=\(summary.down)")
    }
    return .ok
}

private func resolveUpstream(
    opts: GlobalOptions,
    controller: SystemProxyController
) throws -> ProxyUpstream? {
    if let raw = opts.flag("upstream") {
        guard let (host, port) = splitHostPortArgument(raw) else {
            throw CLIError.usage("--upstream must be host:port")
        }
        let kind: ProxyUpstream.Kind = (opts.flag("upstream-kind")?.lowercased() == "socks5")
            ? .socks5 : .http
        return ProxyUpstream(kind: kind, host: host, port: port)
    }
    // Fall back to whatever the machine's system proxy currently points at, unless it
    // is a stale pointer at our own backup (takeover already active).
    if let backup = controller.loadBackup() { return backup.upstream }
    for service in controller.enabledServices() {
        if let upstream = controller.captureState(service: service).existingUpstream {
            return upstream
        }
    }
    // The networksetup layer can be empty while a NetworkExtension VPN publishes
    // proxy settings on the primary service. The merged config is what apps
    // actually resolve, so chain inherit-flows to it. Read before takeover — after
    // takeover it would point at ourselves.
    return SystemProxyReader.current().fixedUpstream
}

private func splitHostPortArgument(_ value: String) -> (String, UInt16)? {
    guard let colon = value.lastIndex(of: ":"),
          let port = UInt16(value[value.index(after: colon)...]) else { return nil }
    let host = String(value[..<colon])
    return host.isEmpty ? nil : (host, port)
}

private func actionName(_ action: ProxyFlowAction) -> String {
    switch action {
    case .block: return "block"
    case .direct: return "direct"
    case .upstream(let up): return "upstream:\(up.host):\(up.port)"
    case .unavailable(let reason):
        switch reason {
        case .systemProxyMissing:
            return "unavailable:system-proxy"
        case .profileMissing(let id):
            return "unavailable:profile:\(id.uuidString)"
        }
    }
}

/// Collects flow events from the proxy's queue for the end-of-run summary.
private final class FlowLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LocalProxyServer.FlowEvent] = []

    func append(_ event: LocalProxyServer.FlowEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func summary() -> (count: Int, blocked: Int, direct: Int, proxied: Int, up: UInt64, down: UInt64) {
        lock.lock(); defer { lock.unlock() }
        var blocked = 0, direct = 0, proxied = 0
        var up: UInt64 = 0, down: UInt64 = 0
        for event in events {
            switch event.action {
            case .block: blocked += 1
            case .unavailable: blocked += 1
            case .direct: direct += 1
            case .upstream: proxied += 1
            }
            up &+= event.bytesUp
            down &+= event.bytesDown
        }
        return (events.count, blocked, direct, proxied, up, down)
    }
}

private final class AtomicPort: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0
    func set(_ v: UInt16) { lock.lock(); value = v; lock.unlock() }
    func get() -> UInt16 { lock.lock(); defer { lock.unlock() }; return value }
}
