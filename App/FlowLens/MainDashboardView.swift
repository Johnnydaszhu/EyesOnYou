import SwiftUI
import AppKit
import FlowLensCore

struct MainDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.nsAppDelegate) private var appDelegate

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
                    .padding(.top, 4)
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
    }

    /// Top bar: app name left-aligned with content · version / settings / appearance.
    /// Sits in the titlebar band beside traffic lights (leading inset) instead of
    /// stacking a tall empty strip below them.
    private var topChrome: some View {
        HStack(spacing: 8) {
            Text(AppBrand.displayName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(FlowLensTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            headerVersionControl
            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(FlowLensTheme.cardBorder.opacity(0.8), lineWidth: 0.7)
                            )
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t("settings.title"))
            AppearanceModePicker()
        }
        // Trailing matches content inset; leading clears traffic lights when chrome
        // shares the titlebar row (no update banner above).
        .padding(.leading, model.appUpdateAvailable ? 16 : 78)
        .padding(.trailing, 16)
        .padding(.top, model.appUpdateAvailable ? 6 : 8)
        .padding(.bottom, 2)
    }

    // MARK: - Update banner (only top chrome)

    private var updateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(FlowLensTheme.accentBlue)
                .font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t("update.available"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                if let ver = model.appUpdateVersion {
                    Text(String(format: l10n.t("update.version"), ver))
                        .font(.system(size: 10))
                        .foregroundStyle(FlowLensTheme.textSecondary)
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
            .background(Capsule().fill(FlowLensTheme.accentBlue.opacity(0.95)))
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
                        ? FlowLensTheme.accentBlue
                        : FlowLensTheme.textSecondary
                )
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(FlowLensTheme.cardBorder.opacity(0.8), lineWidth: 0.7)
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.t("update.check.help"))
            .disabled(model.isCheckingForUpdates || model.isDownloadingUpdate)

            if model.appUpdateAvailable {
                Button {
                    model.installOrOpenUpdate()
                } label: {
                    Text(
                        model.isDownloadingUpdate
                            ? l10n.t("update.downloading")
                            : l10n.t("update.action")
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(FlowLensTheme.accentBlue.opacity(0.95)))
                }
                .buttonStyle(.plain)
                .disabled(model.isDownloadingUpdate)
                .help(l10n.t("update.action.help"))
            } else if let key = model.updateCheckMessage {
                Text(l10n.t("update.status.\(key)"))
                    .font(.system(size: 10))
                    .foregroundStyle(FlowLensTheme.textSecondary)
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
        let directColor = FlowLensTheme.canvasRouteDirect(colorScheme: scheme)
        let proxyColor = FlowLensTheme.canvasRouteProxy(colorScheme: scheme)
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
