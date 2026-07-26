import AppKit
import SwiftUI
import EyesOnYouCore

// MARK: - Icon cache

/// Resolves real macOS application icons via `NSWorkspace` + bundle identifier.
@MainActor
final class AppIconCache: ObservableObject {
    static let shared = AppIconCache()

    private var memory: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    private var missing: Set<String> = []

    /// Known signing-id → installable bundle id (helpers often don't map 1:1).
    private static let aliases: [String: String] = [
        "com.apple.WebKit.Networking": "com.apple.Safari",
        "com.apple.WebKit.WebContent": "com.apple.Safari",
        "com.apple.Safari.WebApp": "com.apple.Safari",
        "com.google.Chrome.helper": "com.google.Chrome",
        "com.google.Chrome.helper.renderer": "com.google.Chrome",
        "com.microsoft.edgemac.helper": "com.microsoft.edgemac",
        "org.mozilla.plugincontainer": "org.mozilla.firefox",
        "com.hnc.Discord.helper": "com.hnc.Discord",
        "com.tinyspeck.slackmacgap.helper": "com.tinyspeck.slackmacgap",
        "com.spotify.client.helper": "com.spotify.client",
        // Demo / alternate product IDs
        "com.anthropic.claude": "com.anthropic.claudefordesktop",
        "com.openai.chat": "com.openai.codex",
        "us.zoom.xos": "us.zoom.xos",
    ]

    func icon(forSigningID signingID: String, size: CGFloat) -> NSImage? {
        let key = Self.normalize(signingID)
        if let hit = memory[key] {
            return sized(hit, size: size)
        }
        if missing.contains(key) { return nil }
        if !inflight.contains(key) {
            inflight.insert(key)
            // Resolve off the hot path; publish when ready.
            Task { @MainActor in
                defer { self.inflight.remove(key) }
                if let image = Self.loadIcon(for: key) {
                    self.memory[key] = image
                    self.objectWillChange.send()
                } else {
                    self.missing.insert(key)
                }
            }
        }
        // Try a synchronous first-chance lookup so first paint often has the icon.
        if let image = Self.loadIcon(for: key) {
            memory[key] = image
            return sized(image, size: size)
        }
        missing.insert(key)
        inflight.remove(key)
        return nil
    }

    /// Prefer system-localized display name from the installed app bundle.
    ///
    /// Memoized: the ranking asks for one of these per app on every tick, and each
    /// miss costs a Launch Services round trip plus an `Info.plist` read.
    func displayName(forSigningID signingID: String, fallback: String) -> String {
        let key = Self.normalize(signingID)
        if let hit = Self.nameCache[key] { return hit ?? fallback }
        let resolved = Self.resolveDisplayName(key: key)
        Self.nameCache[key] = resolved
        return resolved ?? fallback
    }

    private static func resolveDisplayName(key: String) -> String? {
        guard let url = applicationURL(forSigningID: key) else { return nil }
        if let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Resolve the on-disk `.app` URL for a signing / bundle identifier.
    func applicationURL(forSigningID signingID: String) -> URL? {
        Self.applicationURL(forSigningID: signingID)
    }

    /// Resolved bundle URLs. A hit is kept for the session (matching the icon cache);
    /// a miss expires, so an app installed while the dashboard is open still shows up.
    private static var urlCache: [String: URL] = [:]
    private static var urlMisses: [String: Date] = [:]
    private static var nameCache: [String: String?] = [:]
    private static let missTTL: TimeInterval = 60

    /// Resolve the on-disk `.app` URL for a signing / bundle identifier.
    ///
    /// The uncached path is expensive — several Launch Services lookups and, on a
    /// miss, a full walk of `runningApplications` — and the dashboard used to run it
    /// once per ranked app per second.
    static func applicationURL(forSigningID signingID: String) -> URL? {
        let key = normalize(signingID)
        if let hit = urlCache[key] { return hit }
        if let missedAt = urlMisses[key], Date().timeIntervalSince(missedAt) < missTTL {
            return nil
        }
        guard let resolved = lookUpApplicationURL(key: key) else {
            urlMisses[key] = Date()
            return nil
        }
        urlCache[key] = resolved
        urlMisses.removeValue(forKey: key)
        return resolved
    }

    private static func lookUpApplicationURL(key: String) -> URL? {
        let candidates = bundleCandidates(for: key)
        for bundleID in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, candidates.contains(bid) else { continue }
            if let url = app.bundleURL {
                return url
            }
        }
        // Last resort: strip helper / renderer / networking suffixes and retry Launch Services.
        for suffix in [".helper.renderer", ".helper", ".WebContent", ".Networking", ".plugincontainer"] {
            if key.hasSuffix(suffix) {
                let parent = String(key.dropLast(suffix.count))
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parent) {
                    return url
                }
            }
        }
        return nil
    }

    private func sized(_ image: NSImage, size: CGFloat) -> NSImage {
        let px = max(16, size * 2) // retina-ish
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: px, height: px)
        return copy
    }

    private static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadIcon(for signingID: String) -> NSImage? {
        if let url = applicationURL(forSigningID: signingID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
        // Fallback: running-app icon when bundle path is unavailable.
        let candidates = bundleCandidates(for: signingID)
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, candidates.contains(bid), let icon = app.icon else {
                continue
            }
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
        return nil
    }

    private static func bundleCandidates(for signingID: String) -> [String] {
        var list: [String] = []
        if let alias = aliases[signingID] {
            list.append(alias)
        }
        list.append(signingID)
        // Common vendor suffixes
        if signingID.hasSuffix(".helper") {
            list.append(String(signingID.dropLast(".helper".count)))
        }
        return Array(NSOrderedSet(array: list)) as? [String] ?? list
    }
}

// MARK: - SwiftUI view

/// Shows the real app icon when resolvable; otherwise a letter placeholder.
struct AppIconView: View {
    let signingIdentifier: String
    var displayName: String = ""
    var size: CGFloat = 20

    @ObservedObject private var cache = AppIconCache.shared

    var body: some View {
        Group {
            if let nsImage = cache.icon(forSigningID: signingIdentifier, size: size) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                AppIconPlaceholder(name: displayName.isEmpty ? signingIdentifier : displayName, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(displayName.isEmpty ? signingIdentifier : displayName))
    }
}

/// Convenience overload for `AppIdentityKey`.
extension AppIconView {
    init(app: AppIdentityKey, displayName: String = "", size: CGFloat = 20) {
        self.init(signingIdentifier: app.signingIdentifier, displayName: displayName, size: size)
    }
}

// MARK: - Letter fallback (when app not installed / unresolved)

struct AppIconPlaceholder: View {
    let name: String
    var size: CGFloat = 20

    private var color: Color {
        let colors: [Color] = [
            .blue, .orange, .purple, .green, .pink, .cyan, .indigo, .mint
        ]
        let idx = abs(name.hashValue) % colors.count
        return colors[idx]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(color.opacity(0.85))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
