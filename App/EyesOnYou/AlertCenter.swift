import Foundation
import UserNotifications
import EyesOnYouCore

/// Delivers traffic alerts as macOS notifications, and keeps a short in-app history.
///
/// Notification permission is requested only when the user turns alerts on — never at
/// launch — and a refusal is not fatal: alerts still appear inside the app, so the
/// feature degrades instead of disappearing.
@MainActor
final class AlertCenter: ObservableObject {
    /// Most recent alerts, newest first (bounded).
    @Published private(set) var recent: [TrafficAlert] = []
    @Published private(set) var notificationsAuthorized = false

    private static let maxRecent = 50
    private let center = UNUserNotificationCenter.current()
    /// `nil` until the app bundle is known to support notifications (unit-test safety).
    private let canUseNotifications: Bool

    init() {
        // UNUserNotificationCenter traps when there is no bundle identifier, which is
        // the case for command-line hosts and some test runners.
        canUseNotifications = Bundle.main.bundleIdentifier != nil
    }

    func refreshAuthorization() {
        guard canUseNotifications else { return }
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.notificationsAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    /// Ask for permission. Safe to call repeatedly; macOS only prompts once.
    func requestAuthorization() {
        guard canUseNotifications else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.notificationsAuthorized = granted
            }
        }
    }

    func deliver(_ alerts: [TrafficAlert], localization: LocalizationStore) {
        guard !alerts.isEmpty else { return }
        recent.insert(contentsOf: alerts, at: 0)
        if recent.count > Self.maxRecent {
            recent.removeLast(recent.count - Self.maxRecent)
        }
        guard canUseNotifications, notificationsAuthorized else { return }

        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = Self.title(for: alert, localization: localization)
            content.body = Self.body(for: alert, localization: localization)
            content.sound = .default
            // The alert id is already a stable dedupe key, so macOS will not stack
            // duplicates if delivery is retried.
            center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
        }
    }

    func clear() {
        recent.removeAll()
    }

    // MARK: - Copy

    static func title(for alert: TrafficAlert, localization: LocalizationStore) -> String {
        switch alert.kind {
        case .dailyTotal: return localization.t("alert.dailyTotal.title")
        case .dailyApp: return localization.t("alert.dailyApp.title")
        case .cumulativeApp: return localization.t("alert.cumulativeApp.title")
        case .appBurst: return localization.t("alert.burst.title")
        case .newApp: return localization.t("alert.newApp.title")
        }
    }

    static func body(for alert: TrafficAlert, localization: LocalizationStore) -> String {
        let name = alert.displayName
            ?? alert.app?.signingIdentifier
            ?? localization.t("destination.unknown")
        let used = ByteFormat.string(for: alert.bytes)
        let limit = ByteFormat.string(for: alert.threshold)

        switch alert.kind {
        case .dailyTotal:
            return localization.t("alert.dailyTotal.body", used, limit)
        case .dailyApp:
            return localization.t("alert.dailyApp.body", name, used, limit)
        case .cumulativeApp:
            return localization.t("alert.cumulativeApp.body", name, used)
        case .appBurst:
            return localization.t("alert.burst.body", name, used)
        case .newApp:
            return localization.t("alert.newApp.body", name)
        }
    }
}
