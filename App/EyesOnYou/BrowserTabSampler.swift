import AppKit
import ApplicationServices

/// Samples the page open in the frontmost browser tab, so a `github.com` traffic row
/// can name the page it came from instead of only its host.
///
/// Privacy contract — this is the one part of EyesOnYou that can see what you are
/// reading, so it is deliberately constrained:
/// - **Off by default.** Requires an explicit opt-in *and* macOS Accessibility trust,
///   which the user grants in System Settings and can revoke at any time.
/// - **Host and title only.** The path, query, and fragment of a URL are dropped at
///   the point of capture — never stored, never shown.
/// - **Titles stay in memory.** Page titles live in a bounded in-memory index and are
///   gone when the app quits. The *host* of the foreground tab is different: it is
///   used as a traffic destination label, so it lands in the telemetry database
///   exactly like any other observed hostname.
/// - **Foreground only.** Reads the focused window of the frontmost browser; it does
///   not enumerate background tabs or other windows.
@MainActor
final class BrowserTabSampler {
    struct Tab: Equatable {
        let host: String
        let title: String
        let seenAt: Date
    }

    /// Browsers whose focused document is readable through Accessibility.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
    ]

    /// Cap the index so a long session cannot grow without bound.
    private static let maxTrackedHosts = 200
    /// Titles older than this stop being shown — a stale page name is worse than none.
    private static let titleTTL: TimeInterval = 6 * 3600

    private var tabsByHost: [String: Tab] = [:]

    /// Last successful read of the frontmost browser tab, for attributing that
    /// browser's traffic to the page actually in front of the user.
    ///
    /// Cleared as soon as a non-browser app comes to the front, so another app's
    /// traffic can never inherit the last page. `tab.seenAt` lets callers apply
    /// their own staleness bound.
    private(set) var frontmost: (bundleID: String, tab: Tab)?

    /// Whether macOS has granted this app Accessibility access.
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt for Accessibility access. macOS shows the prompt once per app version;
    /// afterwards it silently returns the current state and the user must use
    /// System Settings.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Page title last seen on `host`, if still fresh.
    func title(forHost host: String, now: Date = Date()) -> String? {
        let key = host.lowercased()
        guard let tab = tabsByHost[key] else { return nil }
        guard now.timeIntervalSince(tab.seenAt) <= Self.titleTTL else { return nil }
        return tab.title
    }

    /// Read the frontmost browser tab and fold it into the index.
    ///
    /// Returns `nil` — without side effects — when the feature is not permitted, the
    /// front app is not a browser, or the page cannot be read.
    @discardableResult
    func sample(now: Date = Date()) -> Tab? {
        guard Self.isAccessibilityTrusted else { return nil }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier,
              Self.browserBundleIDs.contains(bundleID)
        else {
            frontmost = nil
            return nil
        }

        let application = AXUIElementCreateApplication(frontApp.processIdentifier)
        guard let window = copyElement(application, attribute: kAXFocusedWindowAttribute as CFString),
              let url = documentURL(window: window),
              let host = Self.normalizedHost(from: url)
        else {
            // Unreadable page (new-tab, about:blank, or a different browser came to
            // the front): never let a stale tab from another browser linger.
            if frontmost?.bundleID != bundleID {
                frontmost = nil
            }
            return nil
        }

        let title = pageTitle(window: window) ?? host
        let tab = Tab(host: host, title: title, seenAt: now)
        record(tab)
        frontmost = (bundleID, tab)
        return tab
    }

    /// Drop everything captured so far (used when the user turns tracking off).
    func reset() {
        tabsByHost.removeAll(keepingCapacity: false)
        frontmost = nil
    }

    // MARK: - Index

    private func record(_ tab: Tab) {
        tabsByHost[tab.host] = tab
        guard tabsByHost.count > Self.maxTrackedHosts else { return }
        // Evict least-recently-seen hosts back down to the cap.
        let excess = tabsByHost.count - Self.maxTrackedHosts
        let stale = tabsByHost
            .sorted { $0.value.seenAt < $1.value.seenAt }
            .prefix(excess)
            .map(\.key)
        for key in stale {
            tabsByHost.removeValue(forKey: key)
        }
    }

    /// Host of a URL, with `www.` dropped so it matches the traffic destination key.
    static func normalizedHost(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            // about:, file:, and extension pages are not network destinations.
            return nil
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - Accessibility reads

    private func documentURL(window: AXUIElement) -> URL? {
        // Safari publishes the document URL on the window itself.
        if let document: String = copyValue(window, attribute: kAXDocumentAttribute as CFString),
           let url = URL(string: document) {
            return url
        }
        // Chromium and Firefox expose it on the web area inside the window.
        guard let webArea = findWebArea(in: window) else { return nil }
        if let url: URL = copyValue(webArea, attribute: "AXURL" as CFString) {
            return url
        }
        if let document: String = copyValue(webArea, attribute: kAXDocumentAttribute as CFString) {
            return URL(string: document)
        }
        return nil
    }

    private func pageTitle(window: AXUIElement) -> String? {
        if let webArea = findWebArea(in: window),
           let title: String = copyValue(webArea, attribute: kAXTitleAttribute as CFString),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        // Browser window titles are the page title, sometimes with a browser suffix.
        guard let raw: String = copyValue(window, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Breadth-first search for the `AXWebArea` element, bounded so a deep or hostile
    /// hierarchy cannot stall the main thread.
    private func findWebArea(in root: AXUIElement, maxVisited: Int = 250) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        while !queue.isEmpty, visited < maxVisited {
            let element = queue.removeFirst()
            visited += 1
            if let role: String = copyValue(element, attribute: kAXRoleAttribute as CFString),
               role == "AXWebArea" {
                return element
            }
            if let children: [AXUIElement] = copyValue(element, attribute: kAXChildrenAttribute as CFString) {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    private func copyElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func copyValue<T>(_ element: AXUIElement, attribute: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? T
    }
}
