import SwiftUI
import AppKit

// MARK: - Adaptive palette (templates + custom accents)

/// Semantic colors for the whole app. Rebuild via `ThemeStore.apply` when the user changes template / accents.
enum EyesOnYouTheme {
    // Backgrounds
    private(set) static var background = Color.fl(light: (0.965, 0.955, 0.935), dark: (0.075, 0.080, 0.090))
    private(set) static var backgroundSecondary = Color.fl(light: (0.99, 0.985, 0.975), dark: (0.10, 0.11, 0.13))

    // Surfaces
    private(set) static var card = Color.fl(light: (1.0, 1.0, 1.0), dark: (0.14, 0.15, 0.17), lightAlpha: 0.92, darkAlpha: 0.55)
    private(set) static var cardBorder = Color.fl(light: (0.78, 0.76, 0.72), dark: (1, 1, 1), lightAlpha: 0.45, darkAlpha: 0.12)
    private(set) static var cardHighlight = Color.fl(light: (1, 1, 1), dark: (1, 1, 1), lightAlpha: 0.9, darkAlpha: 0.18)
    private(set) static var trackFill = Color.fl(light: (0.88, 0.86, 0.82), dark: (1, 1, 1), lightAlpha: 0.55, darkAlpha: 0.08)
    private(set) static var hairline = Color.fl(light: (0.75, 0.73, 0.70), dark: (1, 1, 1), lightAlpha: 0.35, darkAlpha: 0.10)

    // Text
    private(set) static var textPrimary = Color.fl(light: (0.12, 0.14, 0.16), dark: (0.96, 0.96, 0.97))
    private(set) static var textSecondary = Color.fl(light: (0.42, 0.44, 0.46), dark: (0.62, 0.64, 0.66))

    // Brand / accents
    private(set) static var brandGreen = Color.fl(light: (0.18, 0.42, 0.32), dark: (0.32, 0.72, 0.48))
    private(set) static var accentGreen = Color.fl(light: (0.22, 0.55, 0.40), dark: (0.35, 0.85, 0.55))
    private(set) static var accentBlue = Color.fl(light: (0.25, 0.48, 0.78), dark: (0.40, 0.70, 1.0))
    private(set) static var accentPurple = Color.fl(light: (0.52, 0.38, 0.82), dark: (0.70, 0.50, 0.98))
    private(set) static var accentAmber = Color.fl(light: (0.88, 0.55, 0.18), dark: (0.95, 0.72, 0.35))
    private(set) static var accentOrange = Color.fl(light: (0.92, 0.48, 0.20), dark: (1.0, 0.55, 0.28))
    private(set) static var accentRed = Color.fl(light: (0.86, 0.28, 0.28), dark: (0.95, 0.38, 0.38))
    private(set) static var gold = Color.fl(light: (0.72, 0.58, 0.28), dark: (0.90, 0.76, 0.42))

    // Chart series
    private(set) static var chartDown = Color.fl(light: (0.35, 0.62, 0.48), dark: (0.55, 0.78, 0.62))
    private(set) static var chartUp = Color.fl(light: (0.92, 0.48, 0.20), dark: (1.0, 0.55, 0.28))

    // Categorical palette for the sunburst / pie — derived from the accent set so the
    // template (and custom accents) reach the chart instead of a fixed rainbow wheel.
    private static var seriesSeedsLight: [ThemeHSB] = ThemeHSB.series(from: .forest, mono: false, isDark: false)
    private static var seriesSeedsDark: [ThemeHSB] = ThemeHSB.series(
        from: ThemeAccentSet.forest.elevatedForDark(),
        mono: false,
        isDark: true
    )

    // Ranking / disk values
    private(set) static var diskRead = Color.fl(light: (0.90, 0.58, 0.22), dark: (0.95, 0.68, 0.32))
    private(set) static var diskWrite = Color.fl(light: (0.88, 0.50, 0.18), dark: (0.95, 0.60, 0.28))

    /// Route palette: direct · system · proxy.
    private(set) static var routeDirect = Color.fl(light: (0.22, 0.55, 0.40), dark: (0.35, 0.85, 0.55))
    private(set) static var routeSystem = Color.fl(light: (0.42, 0.44, 0.46), dark: (0.62, 0.64, 0.66))
    private(set) static var routeProxy = Color.fl(light: (0.92, 0.48, 0.20), dark: (1.0, 0.55, 0.28))

    private(set) static var isMono = false

    static func routeColor(_ route: String) -> Color {
        switch route.lowercased() {
        case "direct": return routeDirect
        // "Follow" is the unruled default: macOS decides, so tint it like the system path.
        case "system", "system proxy", "follow", "follow system": return routeSystem
        case "socks5", "proxy", "custom proxy": return routeProxy
        case "blocked": return accentRed
        default: return textSecondary
        }
    }

    /// Concrete (non-dynamic) route colors for `Canvas` / menu-bar drawing.
    /// Dynamic `Color.fl` tokens can resolve against the status item’s ambient
    /// appearance and drift from the main window — these stay locked to the app scheme.
    @MainActor
    static func canvasRouteDirect(colorScheme: ColorScheme) -> Color {
        if isMono {
            return colorScheme == .dark
                ? Color(red: 0.72, green: 0.72, blue: 0.72)
                : Color(red: 0.38, green: 0.38, blue: 0.38)
        }
        let accents = colorScheme == .dark ? ThemeStore.accents.elevatedForDark() : ThemeStore.accents
        return accents.accent.color
    }

    @MainActor
    static func canvasRouteProxy(colorScheme: ColorScheme) -> Color {
        let accents = colorScheme == .dark ? ThemeStore.accents.elevatedForDark() : ThemeStore.accents
        return accents.proxy.color
    }

    /// Categorical slice color for the sunburst / pie.
    /// - Parameters:
    ///   - index: series slot (app rank). Wraps to the same hues, progressively softer.
    ///   - variant: sibling offset inside one app (destinations) — tonal step, never a new hue.
    ///   - ring: 0 inner, 1 outer shell.
    static func seriesColor(index: Int, variant: Int = 0, ring: Int = 0, hovered: Bool = false) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hsb = ThemeHSB.slice(
                seeds: isDark ? seriesSeedsDark : seriesSeedsLight,
                index: index,
                variant: variant,
                ring: ring,
                hovered: hovered,
                isDark: isDark
            )
            let rgb = hsb.rgb
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }))
    }

    /// Perceived luminance (0…1) of a slice, so in-slice labels can flip to dark text.
    static func seriesLuminance(
        index: Int,
        variant: Int = 0,
        ring: Int = 0,
        hovered: Bool = false,
        isDark: Bool
    ) -> Double {
        let hsb = ThemeHSB.slice(
            seeds: isDark ? seriesSeedsDark : seriesSeedsLight,
            index: index,
            variant: variant,
            ring: ring,
            hovered: hovered,
            isDark: isDark
        )
        let rgb = hsb.rgb
        return 0.2126 * Double(rgb.r) + 0.7152 * Double(rgb.g) + 0.0722 * Double(rgb.b)
    }

    static func cardShadow(for scheme: ColorScheme) -> (Color, CGFloat, CGFloat) {
        switch scheme {
        case .light:
            return (Color.black.opacity(isMono ? 0.08 : 0.06), 12, 4)
        default:
            return (Color.black.opacity(0.35), 18, 8)
        }
    }

    /// Rebuild every semantic token from a template + accent set.
    static func rebuild(template: ColorThemeTemplate, accents: ThemeAccentSet) {
        isMono = template == .mono
        let darkAccents = accents.elevatedForDark()

        if isMono {
            background = Color.fl(light: (0.96, 0.96, 0.96), dark: (0.07, 0.07, 0.07))
            backgroundSecondary = Color.fl(light: (0.99, 0.99, 0.99), dark: (0.11, 0.11, 0.11))
            card = Color.fl(light: (1, 1, 1), dark: (0.14, 0.14, 0.14), lightAlpha: 0.94, darkAlpha: 0.58)
            cardBorder = Color.fl(light: (0.72, 0.72, 0.72), dark: (1, 1, 1), lightAlpha: 0.40, darkAlpha: 0.12)
            trackFill = Color.fl(light: (0.88, 0.88, 0.88), dark: (1, 1, 1), lightAlpha: 0.55, darkAlpha: 0.08)
            hairline = Color.fl(light: (0.70, 0.70, 0.70), dark: (1, 1, 1), lightAlpha: 0.35, darkAlpha: 0.10)
            textPrimary = Color.fl(light: (0.10, 0.10, 0.10), dark: (0.96, 0.96, 0.96))
            textSecondary = Color.fl(light: (0.45, 0.45, 0.45), dark: (0.62, 0.62, 0.62))
        } else {
            background = Color.fl(light: (0.965, 0.955, 0.935), dark: (0.075, 0.080, 0.090))
            backgroundSecondary = Color.fl(light: (0.99, 0.985, 0.975), dark: (0.10, 0.11, 0.13))
            card = Color.fl(light: (1.0, 1.0, 1.0), dark: (0.14, 0.15, 0.17), lightAlpha: 0.92, darkAlpha: 0.55)
            cardBorder = Color.fl(light: (0.78, 0.76, 0.72), dark: (1, 1, 1), lightAlpha: 0.45, darkAlpha: 0.12)
            trackFill = Color.fl(light: (0.88, 0.86, 0.82), dark: (1, 1, 1), lightAlpha: 0.55, darkAlpha: 0.08)
            hairline = Color.fl(light: (0.75, 0.73, 0.70), dark: (1, 1, 1), lightAlpha: 0.35, darkAlpha: 0.10)
            textPrimary = Color.fl(light: (0.12, 0.14, 0.16), dark: (0.96, 0.96, 0.97))
            textSecondary = Color.fl(light: (0.42, 0.44, 0.46), dark: (0.62, 0.64, 0.66))
        }

        cardHighlight = Color.fl(light: (1, 1, 1), dark: (1, 1, 1), lightAlpha: 0.9, darkAlpha: 0.18)

        brandGreen = Color.fl(rgbLight: accents.brand, rgbDark: darkAccents.brand)
        accentGreen = Color.fl(rgbLight: accents.accent, rgbDark: darkAccents.accent)
        accentBlue = Color.fl(rgbLight: accents.secondary, rgbDark: darkAccents.secondary)
        accentPurple = Color.fl(rgbLight: accents.tertiary, rgbDark: darkAccents.tertiary)
        accentAmber = Color.fl(rgbLight: accents.warning, rgbDark: darkAccents.warning)
        accentOrange = Color.fl(rgbLight: accents.proxy, rgbDark: darkAccents.proxy)
        accentRed = Color.fl(rgbLight: accents.danger, rgbDark: darkAccents.danger)
        gold = Color.fl(rgbLight: accents.gold, rgbDark: darkAccents.gold)

        seriesSeedsLight = ThemeHSB.series(from: accents, mono: isMono, isDark: false)
        seriesSeedsDark = ThemeHSB.series(from: darkAccents, mono: isMono, isDark: true)

        if isMono {
            // Only proxy traffic keeps color; charts / disk / direct path stay neutral.
            chartDown = Color.fl(light: (0.48, 0.48, 0.48), dark: (0.58, 0.58, 0.58))
            chartUp = Color.fl(light: (0.32, 0.32, 0.32), dark: (0.72, 0.72, 0.72))
            diskRead = Color.fl(light: (0.42, 0.42, 0.42), dark: (0.62, 0.62, 0.62))
            diskWrite = Color.fl(light: (0.32, 0.32, 0.32), dark: (0.70, 0.70, 0.70))
            routeDirect = Color.fl(light: (0.38, 0.38, 0.38), dark: (0.72, 0.72, 0.72))
            routeSystem = textSecondary
            routeProxy = accentOrange
        } else {
            chartDown = Color.fl(
                light: (accents.accent.r * 0.7 + 0.12, accents.accent.g * 0.7 + 0.18, accents.accent.b * 0.7 + 0.14),
                dark: (darkAccents.accent.r, darkAccents.accent.g, darkAccents.accent.b)
            )
            chartUp = accentOrange
            diskRead = Color.fl(rgbLight: accents.warning, rgbDark: darkAccents.warning)
            diskWrite = Color.fl(rgbLight: accents.proxy, rgbDark: darkAccents.proxy)
            routeDirect = accentGreen
            routeSystem = textSecondary
            routeProxy = accentOrange
        }
    }
}

// MARK: - Chart series palette

/// HSB working color for the categorical chart palette. Slices need saturation /
/// brightness steps off a shared hue, which `ThemeRGB` can't express directly.
struct ThemeHSB {
    var h: Double
    var s: Double
    var b: Double

    init(h: Double, s: Double, b: Double) {
        self.h = h
        self.s = s
        self.b = b
    }

    init(_ rgb: ThemeRGB) {
        let maxV = max(rgb.r, rgb.g, rgb.b)
        let minV = min(rgb.r, rgb.g, rgb.b)
        let delta = maxV - minV
        var hue = 0.0
        if delta > 0 {
            if maxV == rgb.r {
                hue = (rgb.g - rgb.b) / delta
            } else if maxV == rgb.g {
                hue = 2 + (rgb.b - rgb.r) / delta
            } else {
                hue = 4 + (rgb.r - rgb.g) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        self.init(h: hue, s: maxV == 0 ? 0 : delta / maxV, b: maxV)
    }

    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let sector = floor(h * 6)
        let f = h * 6 - sector
        let p = b * (1 - s)
        let q = b * (1 - f * s)
        let t = b * (1 - (1 - f) * s)
        let triple: (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: triple = (b, t, p)
        case 1: triple = (q, b, p)
        case 2: triple = (p, b, t)
        case 3: triple = (p, q, b)
        case 4: triple = (t, p, b)
        default: triple = (b, p, q)
        }
        return (CGFloat(triple.0), CGFloat(triple.1), CGFloat(triple.2))
    }

    /// Seed slots ordered so neighbouring slices land on clearly different hues.
    static func series(from accents: ThemeAccentSet, mono: Bool, isDark: Bool) -> [ThemeHSB] {
        if mono {
            // Grayscale template: slices separate by brightness, and the ramp is
            // interleaved so adjacent ranks never sit one step apart.
            let low = isDark ? 0.40 : 0.26
            let high = isDark ? 0.88 : 0.76
            let steps = [0.0, 1.0, 0.34, 0.72, 0.16, 0.88, 0.50, 0.60]
            return steps.map { ThemeHSB(h: 0, s: 0, b: low + (high - low) * $0) }
        }
        return [
            accents.accent,
            accents.secondary,
            accents.proxy,
            accents.tertiary,
            accents.gold,
            accents.brand,
            accents.danger,
            accents.warning
        ].map(ThemeHSB.init)
    }

    /// Resolve one slice: series slot + sibling variant + ring depth + hover.
    static func slice(
        seeds: [ThemeHSB],
        index: Int,
        variant: Int,
        ring: Int,
        hovered: Bool,
        isDark: Bool
    ) -> ThemeHSB {
        guard !seeds.isEmpty else { return ThemeHSB(h: 0, s: 0, b: 0.5) }
        let safeIndex = max(0, index)
        var hsb = seeds[safeIndex % seeds.count]

        // Past the first lap, reuse the hues but soften them so ranks stay tellable apart.
        let cycle = min(3, safeIndex / seeds.count)
        if cycle > 0 {
            hsb.s *= 1 - 0.16 * Double(cycle)
            hsb.b += (isDark ? 0.08 : -0.10) * Double(cycle)
        }

        // Destinations inside one app: tonal step only, so the app stays recognizable.
        if variant > 0 {
            let step = Double(variant % 5)
            hsb.s *= 1 - 0.09 * step
            hsb.b += 0.05 * step
        }

        // Outer ring reads as a lighter shell of its parent slice.
        if ring > 0 {
            hsb.s *= 0.68
            hsb.b += isDark ? 0.06 : 0.12
        }

        if hovered {
            hsb.s = min(1, hsb.s * 1.08)
            hsb.b += 0.10
        }

        hsb.s = min(1, max(0, hsb.s))
        hsb.b = min(0.98, max(0.22, hsb.b))
        return hsb
    }
}

// MARK: - Adaptive Color helper

private extension Color {
    /// sRGB adaptive color for light / dark appearances.
    static func fl(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat),
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            let a = isDark ? darkAlpha : lightAlpha
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a)
        }))
    }

    static func fl(rgbLight: ThemeRGB, rgbDark: ThemeRGB, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        fl(
            light: (CGFloat(rgbLight.r), CGFloat(rgbLight.g), CGFloat(rgbLight.b)),
            dark: (CGFloat(rgbDark.r), CGFloat(rgbDark.g), CGFloat(rgbDark.b)),
            lightAlpha: lightAlpha,
            darkAlpha: darkAlpha
        )
    }
}

// MARK: - AppKit visual effect

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Surfaces

enum GlassStyle {
    case card
    case bar
    case chip
    case popover
    case inset

    var cornerRadius: CGFloat {
        switch self {
        case .card: return 18
        case .bar: return 0
        case .chip: return 12
        case .popover: return 14
        case .inset: return 12
        }
    }

    func material(for scheme: ColorScheme) -> NSVisualEffectView.Material {
        switch self {
        case .card:
            return scheme == .light ? .headerView : .hudWindow
        case .bar:
            return .titlebar
        case .chip:
            return scheme == .light ? .menu : .menu
        case .popover:
            return .popover
        case .inset:
            return scheme == .light ? .contentBackground : .sidebar
        }
    }

    var swiftUIMaterial: Material {
        switch self {
        case .card: return .regularMaterial
        case .bar: return .bar
        case .chip: return .thinMaterial
        case .popover: return .regularMaterial
        case .inset: return .ultraThinMaterial
        }
    }
}

struct LiquidGlassBackground: View {
    var style: GlassStyle = .card
    var cornerRadius: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var radius: CGFloat { cornerRadius ?? style.cornerRadius }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let isLight = colorScheme == .light
        let shadow = EyesOnYouTheme.cardShadow(for: colorScheme)

        ZStack {
            if isLight {
                // Soft opaque card like the cream ref
                shape.fill(EyesOnYouTheme.backgroundSecondary.opacity(0.96))
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color.white.opacity(0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            } else {
                VisualEffectBlur(
                    material: style.material(for: colorScheme),
                    blendingMode: .withinWindow
                )
                .clipShape(shape)

                shape.fill(style.swiftUIMaterial)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.02),
                            Color.black.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }

            shape.strokeBorder(
                LinearGradient(
                    colors: isLight
                        ? [Color.white.opacity(0.95), EyesOnYouTheme.cardBorder.opacity(0.5)]
                        : [EyesOnYouTheme.cardHighlight, EyesOnYouTheme.cardBorder.opacity(0.5), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isLight ? 0.8 : 1
            )
        }
        .compositingGroup()
        .shadow(color: shadow.0, radius: shadow.1, x: 0, y: shadow.2)
        .shadow(
            color: isLight ? Color.black.opacity(0.03) : Color.white.opacity(0.04),
            radius: isLight ? 2 : 0.5,
            x: 0,
            y: isLight ? 1 : 0.5
        )
    }
}

struct LiquidGlassWindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLight = colorScheme == .light
        let mono = EyesOnYouTheme.isMono
        ZStack {
            EyesOnYouTheme.background

            if isLight {
                Circle()
                    .fill(EyesOnYouTheme.brandGreen.opacity(mono ? 0.04 : 0.06))
                    .frame(width: 480, height: 480)
                    .blur(radius: 90)
                    .offset(x: -200, y: -160)
                Circle()
                    .fill((mono ? EyesOnYouTheme.routeProxy : EyesOnYouTheme.gold).opacity(mono ? 0.04 : 0.05))
                    .frame(width: 360, height: 360)
                    .blur(radius: 80)
                    .offset(x: 220, y: 200)
            } else {
                Circle()
                    .fill(EyesOnYouTheme.accentBlue.opacity(mono ? 0.06 : 0.16))
                    .frame(width: 420, height: 420)
                    .blur(radius: 80)
                    .offset(x: -220, y: -180)
                Circle()
                    .fill(EyesOnYouTheme.accentPurple.opacity(mono ? 0.05 : 0.12))
                    .frame(width: 380, height: 380)
                    .blur(radius: 90)
                    .offset(x: 260, y: 40)
                Circle()
                    .fill((mono ? EyesOnYouTheme.routeProxy : EyesOnYouTheme.gold).opacity(mono ? 0.07 : 0.08))
                    .frame(width: 300, height: 300)
                    .blur(radius: 70)
                    .offset(x: 40, y: 280)
                RadialGradient(
                    colors: [Color.clear, Color.black.opacity(0.32)],
                    center: .center,
                    startRadius: 120,
                    endRadius: 700
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - View modifiers

struct CardBackground: ViewModifier {
    var style: GlassStyle = .card

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                LiquidGlassBackground(style: style)
            }
    }
}

struct GlassBarBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if colorScheme == .light {
                        EyesOnYouTheme.backgroundSecondary.opacity(0.92)
                    } else {
                        VisualEffectBlur(material: .headerView, blendingMode: .withinWindow)
                        Color.white.opacity(0.03)
                    }
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(EyesOnYouTheme.hairline)
                            .frame(height: 0.5)
                    }
                }
                .ignoresSafeArea(edges: .horizontal)
            }
    }
}

extension View {
    func flowCard(style: GlassStyle = .card) -> some View {
        modifier(CardBackground(style: style))
    }

    func liquidGlassBar() -> some View {
        modifier(GlassBarBackground())
    }

    func liquidGlassChip(cornerRadius: CGFloat = 10) -> some View {
        background {
            LiquidGlassBackground(style: .chip, cornerRadius: cornerRadius)
        }
    }
}

// MARK: - Chips / badges

struct StatusChip: View {
    let title: String
    let color: Color
    var icon: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(colorScheme == .light ? 0.25 : 0.55), radius: 2)
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(colorScheme == .light ? Color.white.opacity(0.75) : Color.white.opacity(0.06))
                .overlay(Capsule().fill(color.opacity(colorScheme == .light ? 0.08 : 0.12)))
                .overlay(
                    Capsule().strokeBorder(
                        color.opacity(colorScheme == .light ? 0.35 : 0.4),
                        lineWidth: 0.8
                    )
                )
        }
    }
}

struct RouteBadge: View {
    let label: String
    var fontSize: CGFloat = 11
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 3
    var minScale: CGFloat = 0.55

    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = EyesOnYouTheme.routeColor(label)
        Text(l10n.routeChip(label))
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(minScale)
            .allowsTightening(true)
            .truncationMode(.tail)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity)
            .background {
                Capsule()
                    .fill(color.opacity(colorScheme == .light ? 0.12 : 0.16))
                    .overlay(
                        Capsule().strokeBorder(color.opacity(colorScheme == .light ? 0.28 : 0.32), lineWidth: 0.7)
                    )
            }
            .id(l10n.revision)
    }
}

// MARK: - Appearance picker (Auto / Light / Dark)

/// Compact top-trailing control: Auto · Light · Dark.
struct AppearanceModePicker: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        Menu {
            ForEach(AppModel.AppearanceMode.allCases) { mode in
                Button {
                    model.setAppearanceMode(mode)
                } label: {
                    HStack {
                        Label(l10n.t(mode.localizationKey), systemImage: mode.systemImage)
                        if model.appearanceMode == mode {
                            Spacer(minLength: 8)
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: model.appearanceMode.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(EyesOnYouTheme.cardBorder.opacity(0.8), lineWidth: 0.7)
                        )
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.t("appearance.help"))
        .accessibilityLabel(l10n.t("appearance.help"))
        .id(l10n.revision)
        .animation(nil, value: model.themeRevision)
    }
}
