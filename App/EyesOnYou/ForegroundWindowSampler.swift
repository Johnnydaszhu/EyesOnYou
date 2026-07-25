import AppKit
import ApplicationServices
import EyesOnYouCore

/// Reads what the frontmost app is working on, from its focused window.
///
/// Why this exists: only two kinds of app publish a machine-readable "what am I
/// working on" signal — CLI agents (their working directory) and VS Code-family
/// editors (a per-window workspace label). Everything else — Claude, GitHub Desktop,
/// Xcode, Figma — publishes it *only* in the window title. Without reading that, those
/// apps can never show meaningful sub-rows, which is why their drill-down used to be
/// nothing but "via proxy node / direct by rule".
///
/// This is an approximation and is labeled as one: bytes moved while a window is in
/// front are attributed to it, including background work. It is the same trade-off
/// Timing makes for time tracking.
///
/// Privacy contract:
/// - Off by default; requires explicit opt-in *and* macOS Accessibility trust.
/// - Only the focused window's **title** (and, for browsers, the page host) is read —
///   never page content, never other windows, never background apps.
/// - Titles are recorded as traffic destinations, so they do reach the local database.
@MainActor
final class ForegroundWindowSampler {
    struct Context: Equatable {
        /// Bundle identifier of the frontmost app.
        let bundleID: String
        /// Destination key to record (`window:…`, or a hostname for browsers).
        let destinationKey: String
        let seenAt: Date
    }

    private(set) var current: Context?

    /// Browsers are handled by ``BrowserTabSampler``: their meaningful unit is the
    /// page host, which also matches how their traffic is keyed elsewhere.
    private let browserSampler: BrowserTabSampler

    /// Titles that name no document — recording them would just be noise.
    private static let uninformativeTitles: Set<String> = [
        "", "untitled", "new tab", "new window", "window", "general", "settings",
        "preferences", "open", "save", "�",
    ]

    init(browserSampler: BrowserTabSampler) {
        self.browserSampler = browserSampler
    }

    static var isAuthorized: Bool { BrowserTabSampler.isAccessibilityTrusted }

    func reset() {
        current = nil
        browserSampler.reset()
    }

    /// Sample the frontmost app. Returns the context, or `nil` when nothing readable.
    @discardableResult
    func sample(now: Date = Date()) -> Context? {
        guard Self.isAuthorized else { current = nil; return nil }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier
        else {
            current = nil
            return nil
        }

        // Browsers: the page host is the better unit, and it already lines up with
        // the hostnames recorded for their sockets.
        if BrowserTabSampler.browserBundleIDs.contains(bundleID) {
            if let tab = browserSampler.sample(now: now) {
                let context = Context(bundleID: bundleID, destinationKey: tab.host, seenAt: now)
                current = context
                return context
            }
            current = nil
            return nil
        }

        guard let title = focusedWindowTitle(pid: frontApp.processIdentifier),
              let cleaned = Self.cleanTitle(title, appName: frontApp.localizedName)
        else {
            current = nil
            return nil
        }

        let context = Context(
            bundleID: bundleID,
            destinationKey: DestinationKey.makeLabeled(prefix: "window", title: cleaned),
            seenAt: now
        )
        current = context
        return context
    }

    /// Destination for `app` if it is the frontmost app and the read is fresh.
    func destinationKey(
        forSigningID signing: String,
        now: Date,
        maxAge: TimeInterval = 15
    ) -> String? {
        guard let current,
              now.timeIntervalSince(current.seenAt) <= maxAge,
              ProcessAppIdentity.canonicalSigningID(current.bundleID) == signing
        else { return nil }
        return current.destinationKey
    }

    // MARK: - Title handling

    /// Strip the app-name suffix macOS apps append, and reject titles that name
    /// nothing. `"AppModel.swift — EyesOnYou"` keeps both halves; `"Claude"` is dropped.
    static func cleanTitle(_ raw: String, appName: String?) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        if let appName, !appName.isEmpty {
            // Common separators for "<document> — <App>".
            for separator in [" — ", " - ", " – ", " | "] {
                let suffix = separator + appName
                if title.hasSuffix(suffix) {
                    title = String(title.dropLast(suffix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            // A window titled only with the app's own name says nothing.
            if title.caseInsensitiveCompare(appName) == .orderedSame { return nil }
        }

        guard !title.isEmpty,
              !Self.uninformativeTitles.contains(title.lowercased())
        else { return nil }

        // Keep rows readable; the full title is not needed to identify the work.
        if title.count > 80 {
            title = String(title.prefix(80)) + "…"
        }
        return title
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success,
            let windowRef,
            CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }

        let window = windowRef as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success else { return nil }
        return titleRef as? String
    }
}
