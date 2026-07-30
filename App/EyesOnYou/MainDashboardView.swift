import SwiftUI
import AppKit
import EyesOnYouCore

struct MainDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.nsAppDelegate) private var appDelegate
    @State private var showEnforcementInfo = false

    var body: some View {
        ZStack {
            LiquidGlassWindowBackdrop()
            VStack(spacing: 0) {
                // Top chrome: only an update banner when an update exists — no logo / search / mini rates.
                if model.appUpdateAvailable {
                    updateBanner
                        .liquidGlassBar()
                }

                topChrome

                GlobalTimeRangeBar()
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 2)

                content
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(model.appearanceMode.preferredColorScheme)
        .id(l10n.revision)
        // Ensure palette rebuilds participate in SwiftUI invalidation (tokens are static).
        .animation(nil, value: model.themeRevision)
        .onAppear {
            AppModel.applyAppearance(model.appearanceMode)
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.bind(model: model)
            } else {
                MenuBarController.shared.install(model: model)
            }
        }
        .onChange(of: model.appearanceMode) { mode in
            AppModel.applyAppearance(mode)
        }
        // Shown once, on first launch only: enabling foreground labeling needs an
        // Accessibility grant the user has to give, and nothing else in the UI
        // explains why the app would ask for it.
        .alert(
            l10n.t("onboarding.title"),
            isPresented: $model.showsForegroundLabelingOnboarding
        ) {
            Button(l10n.t("onboarding.enable")) {
                model.completeForegroundLabelingOnboarding(enable: true)
            }
            Button(l10n.t("onboarding.later"), role: .cancel) {
                model.completeForegroundLabelingOnboarding(enable: false)
            }
        } message: {
            Text(l10n.t("onboarding.body"))
        }
    }

    /// Top bar: app name left-aligned with content cards · version / settings / appearance.
    /// Sits just below the traffic-light band (top inset) so leading can stay at 16pt
    /// and match the time bar / bento cards — no logo, no extra leading gutter.
    private var topChrome: some View {
        HStack(spacing: 8) {
            Text(AppBrand.displayName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(EyesOnYouTheme.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            // Keep trailing controls at intrinsic width. macOS `Menu` otherwise
            // competes with Spacer for flexible space and drifts off the trailing edge.
            HStack(spacing: 8) {
                if model.hasConfiguredAppRoutes || model.proxyEnabled {
                    routeEnforcementStatusControl
                }
                systemProxyStatusControl
                headerVersionControl
                Button {
                    model.openSettings()
                } label: {
                    Image(systemName: "gearshape")
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
                .buttonStyle(.plain)
                .help(l10n.t("settings.title"))
                AppearanceModePicker()
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        // Clear traffic lights only; keep inset tight so the titlebar band stays short.
        .padding(.top, model.appUpdateAvailable ? 6 : 28)
        .padding(.bottom, 2)
    }

    private var routeEnforcementStatusControl: some View {
        let title: String
        let tint: Color
        switch model.proxyEnforcementStatus {
        case .off:
            title = l10n.t("enforcement.badge.off")
            tint = EyesOnYouTheme.textSecondary
        case .starting:
            title = l10n.t("enforcement.badge.starting")
            tint = EyesOnYouTheme.accentAmber
        case .active:
            title = l10n.t("enforcement.badge.active")
            tint = EyesOnYouTheme.accentGreen
        case .shadowedByVPN:
            title = l10n.t("enforcement.badge.shadowed")
            tint = EyesOnYouTheme.accentAmber
        case .failed:
            title = l10n.t("enforcement.badge.failed")
            tint = EyesOnYouTheme.accentAmber
        }
        return Button {
            showEnforcementInfo.toggle()
        } label: {
            Label(title, systemImage: model.isProxyEnforcementActive ? "checkmark.shield.fill" : "shield.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(tint.opacity(0.28), lineWidth: 0.7)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.enforcementStatusExplanation())
        .popover(isPresented: $showEnforcementInfo, arrowEdge: .bottom) {
            enforcementInfoPopover
        }
    }

    /// Why the enforcement badge says what it says, plus the matching action —
    /// so a "failed" state is explained and fixable in place, not just a chip.
    private var enforcementInfoPopover: some View {
        let statusTitle: String
        switch model.proxyEnforcementStatus {
        case .off: statusTitle = l10n.t("enforcement.off")
        case .starting: statusTitle = l10n.t("enforcement.starting")
        case .active: statusTitle = l10n.t("enforcement.active")
        case .shadowedByVPN: statusTitle = l10n.t("enforcement.shadowed")
        case .failed: statusTitle = l10n.t("enforcement.failed")
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(statusTitle)
                .font(.system(size: 12, weight: .semibold))
            Text(model.enforcementStatusExplanation())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch model.proxyEnforcementStatus {
                case .failed:
                    Button(l10n.t("enforcement.popover.retry")) {
                        showEnforcementInfo = false
                        model.retryProxyEnforcement()
                    }
                    Button(l10n.t("enforcement.popover.turnOff")) {
                        showEnforcementInfo = false
                        model.setProxyEnabled(false)
                    }
                case .active, .shadowedByVPN:
                    Button(l10n.t("enforcement.popover.turnOff")) {
                        showEnforcementInfo = false
                        model.setProxyEnabled(false)
                    }
                case .off:
                    Button(l10n.t("enforcement.popover.turnOn")) {
                        showEnforcementInfo = false
                        // Covers both "toggle was off" and "toggle on but not running".
                        model.retryProxyEnforcement()
                    }
                case .starting:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var systemProxyStatusControl: some View {
        let state = model.systemProxy.configurationState
        let tint: Color = {
            switch state {
            case .enabled: return EyesOnYouTheme.accentGreen
            case .invalid: return EyesOnYouTheme.accentAmber
            case .disabled, .unavailable: return EyesOnYouTheme.textSecondary
            }
        }()
        let key: String = {
            switch state {
            case .enabled: return "systemProxy.state.enabled"
            case .disabled: return "systemProxy.state.disabled"
            case .invalid: return "systemProxy.state.invalid"
            case .unavailable: return "systemProxy.state.unavailable"
            }
        }()
        let detail = model.systemProxy.primaryEndpointLabel
        return HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(l10n.t(key))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tint.opacity(0.28), lineWidth: 0.7)
                )
        }
        .help(
            [l10n.t("systemProxy.help"), detail]
                .compactMap { $0 }
                .joined(separator: "\n")
        )
        .accessibilityLabel(l10n.t(key))
        .accessibilityValue(detail ?? "")
    }

    // MARK: - Update banner (only top chrome)

    private var updateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(EyesOnYouTheme.accentBlue)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t("update.available"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EyesOnYouTheme.textPrimary)
                if let ver = model.appUpdateVersion {
                    Text(String(format: l10n.t("update.version"), ver))
                        .font(.system(size: 10))
                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if model.isDownloadingUpdate {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 6)
            }
            Button(l10n.t("update.action")) {
                model.installOrOpenUpdate()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(EyesOnYouTheme.accentBlue.opacity(0.95)))
            .disabled(model.isDownloadingUpdate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private var content: some View {
        OverviewTabView()
    }

    private var headerVersionControl: some View {
        HStack(spacing: 6) {
            Button {
                model.checkForUpdates(manual: true)
            } label: {
                HStack(spacing: 5) {
                    if model.isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: model.appUpdateAvailable ? "arrow.down.circle.fill" : "info.circle")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text("v\(model.appVersion)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(
                    model.appUpdateAvailable
                        ? EyesOnYouTheme.accentBlue
                        : EyesOnYouTheme.textSecondary
                )
                .padding(.horizontal, 8)
                .frame(height: 28)
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
            .buttonStyle(.plain)
            .help(l10n.t("update.check.help"))
            .disabled(model.isCheckingForUpdates || model.isDownloadingUpdate)

            // When an update exists, the top banner owns the install CTA —
            // avoid a second "Update" chip next to the version label.
            if !model.appUpdateAvailable, let key = model.updateCheckMessage {
                Text(l10n.t("update.status.\(key)"))
                    .font(.system(size: 10))
                    .foregroundStyle(EyesOnYouTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Path dual sparkline (used by menu bar status item + popover)

/// Dual-series mini sparkline (direct / proxy), iStat density.
/// Colors match dashboard route tokens (`routeDirect` / `routeProxy`) and status-bar labels.
struct PathDualSparkline: View {
    let direct: [Double]
    let proxy: [Double]
    /// Status-bar density: keep hairline strokes and light fills.
    var lineWidth: CGFloat = 0.8
    var fillOpacity: Double = 0.12

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Resolve against the app appearance (not status-item ambient), and use the
        // same route tokens as Overview / dual-path labels.
        let scheme = model.appearanceMode.preferredColorScheme ?? colorScheme
        let directColor = EyesOnYouTheme.canvasRouteDirect(colorScheme: scheme)
        let proxyColor = EyesOnYouTheme.canvasRouteProxy(colorScheme: scheme)
        let _ = model.themeRevision
        Canvas { context, size in
            let d = pad(direct)
            let p = pad(proxy)
            let peak = max(d.max() ?? 0, p.max() ?? 0, 1)
            drawSeries(
                context: context,
                size: size,
                values: p,
                peak: peak,
                color: proxyColor.opacity(0.9),
                fillOpacity: fillOpacity * 0.85
            )
            drawSeries(
                context: context,
                size: size,
                values: d,
                peak: peak,
                color: directColor.opacity(0.95),
                fillOpacity: fillOpacity
            )
        }
    }

    private func pad(_ values: [Double]) -> [Double] {
        if values.isEmpty { return [0, 0] }
        if values.count == 1 { return [values[0], values[0]] }
        return values
    }

    private func drawSeries(
        context: GraphicsContext,
        size: CGSize,
        values: [Double],
        peak: Double,
        color: Color,
        fillOpacity: Double
    ) {
        guard values.count >= 2, size.width > 1, size.height > 1 else { return }
        let step = size.width / CGFloat(values.count - 1)
        let inset: CGFloat = 0.5
        var line = Path()
        var fill = Path()
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * step
            let usable = max(size.height - inset * 2, 1)
            let y = size.height - inset - CGFloat(v / peak) * usable
            let pt = CGPoint(x: x, y: y)
            if i == 0 {
                line.move(to: pt)
                fill.move(to: CGPoint(x: x, y: size.height))
                fill.addLine(to: pt)
            } else {
                line.addLine(to: pt)
                fill.addLine(to: pt)
            }
        }
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.closeSubpath()
        context.fill(fill, with: .color(color.opacity(fillOpacity)))
        context.stroke(line, with: .color(color), lineWidth: lineWidth)
    }
}

// Convenience for environment (unused stub kept for compile clarity)
private struct NSAppDelegateKey: EnvironmentKey {
    static let defaultValue: AppDelegate? = nil
}
extension EnvironmentValues {
    var nsAppDelegate: AppDelegate? {
        get { self[NSAppDelegateKey.self] }
        set { self[NSAppDelegateKey.self] = newValue }
    }
}
