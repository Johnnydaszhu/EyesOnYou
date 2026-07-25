import SwiftUI
import AppKit

// MARK: - RGB

/// Linear sRGB triplet stored in UserDefaults / theme templates.
struct ThemeRGB: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    static func gray(_ value: Double) -> ThemeRGB {
        ThemeRGB(r: value, g: value, b: value)
    }

    var color: Color {
        Color(red: r, green: g, blue: b)
    }

    init(r: Double, g: Double, b: Double) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
    }

    init(color: Color) {
        let ns = NSColor(color)
        if let rgb = ns.usingColorSpace(.sRGB) {
            self.init(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)
        } else {
            self.init(r: 0.5, g: 0.5, b: 0.5)
        }
    }

    func withAlpha(_ alpha: CGFloat) -> Color {
        Color(red: r, green: g, blue: b).opacity(Double(alpha))
    }
}

// MARK: - Accent set

/// User-adjustable accent tokens shared across light / dark surfaces.
struct ThemeAccentSet: Codable, Equatable {
    var brand: ThemeRGB
    var accent: ThemeRGB
    var secondary: ThemeRGB
    var tertiary: ThemeRGB
    var proxy: ThemeRGB
    var warning: ThemeRGB
    var danger: ThemeRGB
    var gold: ThemeRGB

    static let forest = ThemeAccentSet(
        brand: ThemeRGB(r: 0.18, g: 0.42, b: 0.32),
        accent: ThemeRGB(r: 0.22, g: 0.55, b: 0.40),
        secondary: ThemeRGB(r: 0.25, g: 0.48, b: 0.78),
        tertiary: ThemeRGB(r: 0.52, g: 0.38, b: 0.82),
        proxy: ThemeRGB(r: 0.92, g: 0.48, b: 0.20),
        warning: ThemeRGB(r: 0.88, g: 0.55, b: 0.18),
        danger: ThemeRGB(r: 0.86, g: 0.28, b: 0.28),
        gold: ThemeRGB(r: 0.72, g: 0.58, b: 0.28)
    )

    static let ocean = ThemeAccentSet(
        brand: ThemeRGB(r: 0.12, g: 0.38, b: 0.52),
        accent: ThemeRGB(r: 0.18, g: 0.55, b: 0.68),
        secondary: ThemeRGB(r: 0.20, g: 0.45, b: 0.86),
        tertiary: ThemeRGB(r: 0.35, g: 0.42, b: 0.78),
        proxy: ThemeRGB(r: 0.95, g: 0.52, b: 0.22),
        warning: ThemeRGB(r: 0.90, g: 0.62, b: 0.20),
        danger: ThemeRGB(r: 0.84, g: 0.30, b: 0.32),
        gold: ThemeRGB(r: 0.55, g: 0.68, b: 0.42)
    )

    static let ember = ThemeAccentSet(
        brand: ThemeRGB(r: 0.55, g: 0.28, b: 0.18),
        accent: ThemeRGB(r: 0.78, g: 0.38, b: 0.22),
        secondary: ThemeRGB(r: 0.42, g: 0.40, b: 0.55),
        tertiary: ThemeRGB(r: 0.62, g: 0.32, b: 0.42),
        proxy: ThemeRGB(r: 0.95, g: 0.50, b: 0.18),
        warning: ThemeRGB(r: 0.92, g: 0.58, b: 0.16),
        danger: ThemeRGB(r: 0.88, g: 0.26, b: 0.24),
        gold: ThemeRGB(r: 0.82, g: 0.62, b: 0.28)
    )

    static let violet = ThemeAccentSet(
        brand: ThemeRGB(r: 0.38, g: 0.28, b: 0.58),
        accent: ThemeRGB(r: 0.52, g: 0.38, b: 0.78),
        secondary: ThemeRGB(r: 0.32, g: 0.48, b: 0.82),
        tertiary: ThemeRGB(r: 0.68, g: 0.42, b: 0.88),
        proxy: ThemeRGB(r: 0.94, g: 0.50, b: 0.22),
        warning: ThemeRGB(r: 0.88, g: 0.56, b: 0.22),
        danger: ThemeRGB(r: 0.86, g: 0.30, b: 0.36),
        gold: ThemeRGB(r: 0.78, g: 0.62, b: 0.38)
    )

    /// Mono: neutrals everywhere; proxy stays vivid orange for traffic highlight.
    static let mono = ThemeAccentSet(
        brand: ThemeRGB.gray(0.28),
        accent: ThemeRGB.gray(0.42),
        secondary: ThemeRGB.gray(0.40),
        tertiary: ThemeRGB.gray(0.48),
        proxy: ThemeRGB(r: 0.95, g: 0.52, b: 0.18),
        warning: ThemeRGB.gray(0.50),
        danger: ThemeRGB.gray(0.32),
        gold: ThemeRGB.gray(0.55)
    )

    static func defaults(for template: ColorThemeTemplate) -> ThemeAccentSet {
        switch template {
        case .forest: return .forest
        case .ocean: return .ocean
        case .ember: return .ember
        case .violet: return .violet
        case .mono: return .mono
        case .custom: return .forest
        }
    }

    /// Slightly brighter companions for dark appearance.
    func elevatedForDark() -> ThemeAccentSet {
        ThemeAccentSet(
            brand: brighten(brand, by: 0.18),
            accent: brighten(accent, by: 0.22),
            secondary: brighten(secondary, by: 0.18),
            tertiary: brighten(tertiary, by: 0.16),
            proxy: brighten(proxy, by: 0.08),
            warning: brighten(warning, by: 0.12),
            danger: brighten(danger, by: 0.10),
            gold: brighten(gold, by: 0.14)
        )
    }

    private func brighten(_ rgb: ThemeRGB, by amount: Double) -> ThemeRGB {
        ThemeRGB(
            r: min(1, rgb.r + amount * (1 - rgb.r)),
            g: min(1, rgb.g + amount * (1 - rgb.g)),
            b: min(1, rgb.b + amount * (1 - rgb.b))
        )
    }
}

// MARK: - Template

enum ColorThemeTemplate: String, CaseIterable, Identifiable {
    case forest
    case ocean
    case ember
    case violet
    case mono
    case custom

    var id: String { rawValue }
    var localizationKey: String { "theme.template.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .forest: return "leaf.fill"
        case .ocean: return "water.waves"
        case .ember: return "flame.fill"
        case .violet: return "sparkles"
        case .mono: return "circle.lefthalf.filled"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// Preview swatches for the settings grid (primary / secondary / proxy).
    var previewSwatches: [Color] {
        let accents = ThemeAccentSet.defaults(for: self == .custom ? .forest : self)
        return [accents.accent.color, accents.secondary.color, accents.proxy.color]
    }

    var isMono: Bool { self == .mono }
}

// MARK: - Theme store bridge

@MainActor
enum ThemeStore {
    private(set) static var template: ColorThemeTemplate = .forest
    private(set) static var accents: ThemeAccentSet = .forest
    private(set) static var revision: Int = 0

    static func apply(template: ColorThemeTemplate, accents: ThemeAccentSet) {
        self.template = template
        // Mono locks non-proxy accents to grayscale; keep user proxy tint.
        if template == .mono {
            var locked = ThemeAccentSet.mono
            locked.proxy = accents.proxy
            self.accents = locked
        } else {
            self.accents = accents
        }
        FlowLensTheme.rebuild(template: self.template, accents: self.accents)
        revision &+= 1
    }
}
