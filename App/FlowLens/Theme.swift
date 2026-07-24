import SwiftUI
import AppKit

// MARK: - Palette

enum FlowLensTheme {
    /// Deep base behind glass layers (slightly cooler for refraction feel).
    static let background = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let backgroundSecondary = Color(red: 0.10, green: 0.12, blue: 0.16)
    /// Fallback solid tint when material is unavailable.
    static let card = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.14)
    static let cardHighlight = Color.white.opacity(0.22)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)
    static let accentGreen = Color(red: 0.35, green: 0.85, blue: 0.55)
    static let accentBlue = Color(red: 0.40, green: 0.70, blue: 1.0)
    static let accentPurple = Color(red: 0.70, green: 0.50, blue: 0.98)
    static let accentAmber = Color(red: 0.95, green: 0.72, blue: 0.35)
    static let accentRed = Color(red: 0.95, green: 0.38, blue: 0.38)
    static let chipGreen = Color(red: 0.20, green: 0.45, blue: 0.30)
    static let chipAmber = Color(red: 0.45, green: 0.35, blue: 0.15)
    static let gold = Color(red: 0.90, green: 0.76, blue: 0.42)

    static func routeColor(_ route: String) -> Color {
        switch route.lowercased() {
        case "direct": return accentGreen
        case "system", "system proxy": return accentAmber
        case "socks5", "proxy", "custom proxy": return accentPurple
        case "blocked": return accentRed
        default: return textSecondary
        }
    }
}

// MARK: - AppKit visual effect (true system blur)

/// NSVisualEffectView wrapper — real macOS frosted glass behind SwiftUI content.
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

// MARK: - Liquid glass surfaces

enum GlassStyle {
    /// Main bento cards
    case card
    /// Header / footer bars
    case bar
    /// Floating chips, search field
    case chip
    /// Menu bar popover panels
    case popover
    /// Dense nested rows
    case inset

    var cornerRadius: CGFloat {
        switch self {
        case .card: return 16
        case .bar: return 0
        case .chip: return 12
        case .popover: return 14
        case .inset: return 10
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .card: return .hudWindow
        case .bar: return .titlebar
        case .chip: return .menu
        case .popover: return .popover
        case .inset: return .sidebar
        }
    }

    var swiftUIMaterial: Material {
        switch self {
        case .card: return .ultraThinMaterial
        case .bar: return .bar
        case .chip: return .thinMaterial
        case .popover: return .regularMaterial
        case .inset: return .ultraThinMaterial
        }
    }
}

/// Liquid-glass panel: system blur + specular rim + soft inner wash.
struct LiquidGlassBackground: View {
    var style: GlassStyle = .card
    var cornerRadius: CGFloat? = nil

    private var radius: CGFloat { cornerRadius ?? style.cornerRadius }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            // True window blur (AppKit)
            VisualEffectBlur(material: style.material, blendingMode: .withinWindow)
                .clipShape(shape)

            // SwiftUI material stack for liquid refraction tint
            shape.fill(style.swiftUIMaterial)

            // Cool depth wash
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.02),
                        Color.black.opacity(0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            // Specular top edge (liquid highlight)
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        FlowLensTheme.cardHighlight,
                        FlowLensTheme.cardBorder.opacity(0.4),
                        Color.white.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.28), radius: 18, x: 0, y: 8)
        .shadow(color: Color.white.opacity(0.04), radius: 0.5, x: 0, y: 0.5)
    }
}

/// Full-window ambient backdrop for glass to refract against.
struct LiquidGlassWindowBackdrop: View {
    var body: some View {
        ZStack {
            FlowLensTheme.background

            // Soft color orbs (give blur something colorful to sample)
            Circle()
                .fill(FlowLensTheme.accentBlue.opacity(0.22))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: -220, y: -180)

            Circle()
                .fill(FlowLensTheme.accentPurple.opacity(0.18))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: 260, y: 40)

            Circle()
                .fill(FlowLensTheme.gold.opacity(0.10))
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: 40, y: 280)

            // Subtle noise-like vignette
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.35)],
                center: .center,
                startRadius: 120,
                endRadius: 700
            )
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
    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    VisualEffectBlur(material: .headerView, blendingMode: .withinWindow)
                    Color.white.opacity(0.04)
                    // Bottom hairline
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.02)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
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

    /// Compact glass fill for chips / segmented controls.
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

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(color.opacity(0.12)))
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [color.opacity(0.45), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                )
        }
    }
}

struct RouteBadge: View {
    let label: String
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        let color = FlowLensTheme.routeColor(label)
        Text(l10n.routeChip(label))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(color.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.7))
            }
            .id(l10n.revision)
    }
}
