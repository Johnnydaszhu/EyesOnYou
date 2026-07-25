import Foundation

/// What tripped an alert.
public enum TrafficAlertKind: String, Codable, Sendable, CaseIterable {
    /// Everything together crossed the daily budget.
    case dailyTotal
    /// One app crossed the daily budget on its own.
    case dailyApp
    /// One app's all-time total crossed another multiple of the budget.
    case cumulativeApp
    /// One app moved a lot of data in a short window — the shape of a runaway
    /// upload or an unexpected sync, which a daily total would not catch until late.
    case appBurst
    /// An app reached the network for the first time.
    case newApp
}

public struct TrafficAlert: Identifiable, Sendable, Equatable {
    /// Stable dedupe key; also the identity used to avoid re-notifying.
    public let id: String
    public let kind: TrafficAlertKind
    public let app: AppIdentityKey?
    public let displayName: String?
    /// Observed value that tripped the threshold.
    public let bytes: UInt64
    public let threshold: UInt64
    public let raisedAt: Date

    public init(
        id: String,
        kind: TrafficAlertKind,
        app: AppIdentityKey?,
        displayName: String?,
        bytes: UInt64,
        threshold: UInt64,
        raisedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.app = app
        self.displayName = displayName
        self.bytes = bytes
        self.threshold = threshold
        self.raisedAt = raisedAt
    }
}

/// User-configurable limits. A threshold of `0` disables that check.
public struct TrafficAlertThresholds: Codable, Equatable, Sendable {
    /// All apps combined, rolling 24 hours.
    public var dailyTotalBytes: UInt64
    /// Any single app, rolling 24 hours.
    public var dailyAppBytes: UInt64
    /// Any single app, all recorded history. Re-fires at each further multiple.
    public var cumulativeAppBytes: UInt64
    /// Any single app within `burstWindow`.
    public var burstBytes: UInt64
    public var burstWindow: TimeInterval
    /// Notify the first time an app is seen using the network.
    public var notifyOnNewApp: Bool

    public init(
        dailyTotalBytes: UInt64 = 10 * 1_073_741_824,
        dailyAppBytes: UInt64 = 10 * 1_073_741_824,
        cumulativeAppBytes: UInt64 = 10 * 1_073_741_824,
        burstBytes: UInt64 = 512 * 1_048_576,
        burstWindow: TimeInterval = 300,
        notifyOnNewApp: Bool = false
    ) {
        self.dailyTotalBytes = dailyTotalBytes
        self.dailyAppBytes = dailyAppBytes
        self.cumulativeAppBytes = cumulativeAppBytes
        self.burstBytes = burstBytes
        self.burstWindow = burstWindow
        self.notifyOnNewApp = notifyOnNewApp
    }

    public static let `default` = TrafficAlertThresholds()

    public static let gigabyte: UInt64 = 1_073_741_824
    public static let megabyte: UInt64 = 1_048_576
}

/// Everything the engine needs for one evaluation, so it stays pure and testable.
public struct TrafficAlertInput: Sendable {
    public var now: Date
    public var dailyTotalBytes: UInt64
    /// Per-app totals over the rolling day.
    public var dailyByApp: [AppIdentityKey: UInt64]
    /// Per-app totals over all recorded history.
    public var cumulativeByApp: [AppIdentityKey: UInt64]
    /// Per-app totals inside the burst window.
    public var burstByApp: [AppIdentityKey: UInt64]
    public var displayNames: [AppIdentityKey: String]

    public init(
        now: Date,
        dailyTotalBytes: UInt64,
        dailyByApp: [AppIdentityKey: UInt64] = [:],
        cumulativeByApp: [AppIdentityKey: UInt64] = [:],
        burstByApp: [AppIdentityKey: UInt64] = [:],
        displayNames: [AppIdentityKey: String] = [:]
    ) {
        self.now = now
        self.dailyTotalBytes = dailyTotalBytes
        self.dailyByApp = dailyByApp
        self.cumulativeByApp = cumulativeByApp
        self.burstByApp = burstByApp
        self.displayNames = displayNames
    }
}

/// Persisted so a restart does not replay alerts the user already saw.
public struct TrafficAlertState: Codable, Equatable, Sendable {
    public var firedKeys: Set<String>
    public var knownApps: Set<String>

    public init(firedKeys: Set<String> = [], knownApps: Set<String> = []) {
        self.firedKeys = firedKeys
        self.knownApps = knownApps
    }
}

/// Decides which thresholds have been crossed, exactly once each.
///
/// Deduping is the whole difficulty: the app evaluates every second, so a naive
/// check would notify continuously for the rest of the day once a budget is passed.
/// Each condition therefore gets a key scoped to the period it belongs to —
/// per-day for daily budgets, per-multiple for cumulative ones, per-window for
/// bursts — and fires only when that key is new.
public final class TrafficAlertEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var state: TrafficAlertState

    public init(state: TrafficAlertState = TrafficAlertState()) {
        self.state = state
    }

    public var currentState: TrafficAlertState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Treat these apps as already seen (used to seed from the telemetry catalog so
    /// the first launch after an upgrade does not announce every existing app).
    public func seedKnownApps(_ apps: [AppIdentityKey]) {
        lock.lock()
        for app in apps { state.knownApps.insert(app.storageKey) }
        lock.unlock()
    }

    /// Newly crossed thresholds, in the order they should be shown.
    public func evaluate(
        _ input: TrafficAlertInput,
        thresholds: TrafficAlertThresholds
    ) -> [TrafficAlert] {
        var alerts: [TrafficAlert] = []
        let day = Self.dayKey(input.now)

        if thresholds.dailyTotalBytes > 0, input.dailyTotalBytes >= thresholds.dailyTotalBytes {
            let key = "dailyTotal|\(day)"
            if claim(key) {
                alerts.append(TrafficAlert(
                    id: key,
                    kind: .dailyTotal,
                    app: nil,
                    displayName: nil,
                    bytes: input.dailyTotalBytes,
                    threshold: thresholds.dailyTotalBytes,
                    raisedAt: input.now
                ))
            }
        }

        if thresholds.dailyAppBytes > 0 {
            for (app, bytes) in input.dailyByApp.sorted(by: { $0.value > $1.value })
            where bytes >= thresholds.dailyAppBytes {
                let key = "dailyApp|\(app.storageKey)|\(day)"
                guard claim(key) else { continue }
                alerts.append(TrafficAlert(
                    id: key,
                    kind: .dailyApp,
                    app: app,
                    displayName: input.displayNames[app],
                    bytes: bytes,
                    threshold: thresholds.dailyAppBytes,
                    raisedAt: input.now
                ))
            }
        }

        if thresholds.cumulativeAppBytes > 0 {
            for (app, bytes) in input.cumulativeByApp.sorted(by: { $0.value > $1.value }) {
                // Re-arm at every further multiple: 10 GB, 20 GB, 30 GB…
                let multiple = bytes / thresholds.cumulativeAppBytes
                guard multiple >= 1 else { continue }
                let key = "cumulativeApp|\(app.storageKey)|\(multiple)"
                guard claim(key) else { continue }
                alerts.append(TrafficAlert(
                    id: key,
                    kind: .cumulativeApp,
                    app: app,
                    displayName: input.displayNames[app],
                    bytes: bytes,
                    threshold: thresholds.cumulativeAppBytes * multiple,
                    raisedAt: input.now
                ))
            }
        }

        if thresholds.burstBytes > 0, thresholds.burstWindow > 0 {
            let window = Self.windowKey(input.now, seconds: thresholds.burstWindow)
            for (app, bytes) in input.burstByApp.sorted(by: { $0.value > $1.value })
            where bytes >= thresholds.burstBytes {
                let key = "burst|\(app.storageKey)|\(window)"
                guard claim(key) else { continue }
                alerts.append(TrafficAlert(
                    id: key,
                    kind: .appBurst,
                    app: app,
                    displayName: input.displayNames[app],
                    bytes: bytes,
                    threshold: thresholds.burstBytes,
                    raisedAt: input.now
                ))
            }
        }

        if thresholds.notifyOnNewApp {
            for app in input.dailyByApp.keys.sorted(by: { $0.storageKey < $1.storageKey }) {
                lock.lock()
                let isNew = !state.knownApps.contains(app.storageKey)
                if isNew { state.knownApps.insert(app.storageKey) }
                lock.unlock()
                guard isNew else { continue }
                let key = "newApp|\(app.storageKey)"
                guard claim(key) else { continue }
                alerts.append(TrafficAlert(
                    id: key,
                    kind: .newApp,
                    app: app,
                    displayName: input.displayNames[app],
                    bytes: input.dailyByApp[app] ?? 0,
                    threshold: 0,
                    raisedAt: input.now
                ))
            }
        } else {
            // Keep the catalog current even while the check is off, so enabling it
            // later does not announce every app already running.
            lock.lock()
            for app in input.dailyByApp.keys { state.knownApps.insert(app.storageKey) }
            lock.unlock()
        }

        return alerts
    }

    /// Drop keys that can never fire again, so the set cannot grow without bound.
    ///
    /// Keys fall into three lifetimes: permanent (cumulative multiples, first-seen),
    /// per-day (daily budgets — keep today and yesterday so a timezone shift or a
    /// late-night session cannot replay them), and per-window (bursts, keep one hour).
    public func pruneState(now: Date) {
        let today = Self.dayKey(now)
        let yesterday = Self.dayKey(now.addingTimeInterval(-86_400))
        let burstCutoff = Int64(now.addingTimeInterval(-3_600).timeIntervalSince1970)

        lock.lock()
        state.firedKeys = state.firedKeys.filter { key in
            if key.hasPrefix("cumulativeApp|") || key.hasPrefix("newApp|") {
                return true
            }
            if key.hasPrefix("burst|") {
                guard let slot = key.split(separator: "|").last, let stamp = Int64(slot) else {
                    return false
                }
                return stamp >= burstCutoff
            }
            // dailyTotal| and dailyApp| both end in the day key.
            return key.hasSuffix("|\(today)") || key.hasSuffix("|\(yesterday)")
        }
        lock.unlock()
    }

    private func claim(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !state.firedKeys.contains(key) else { return false }
        state.firedKeys.insert(key)
        return true
    }

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func windowKey(_ date: Date, seconds: TimeInterval) -> String {
        let slot = Int64(date.timeIntervalSince1970 / max(1, seconds)) * Int64(max(1, seconds))
        return String(slot)
    }
}
