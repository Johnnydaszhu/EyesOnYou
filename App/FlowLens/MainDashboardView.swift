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

                GlobalTimeRangeBar()
                    .padding(.horizontal, 16)
                    .padding(.top, model.appUpdateAvailable ? 8 : 12)
                    .padding(.bottom, 2)

                content
                    .padding(16)

                footer
                    .liquidGlassBar()
            }
        }
        .preferredColorScheme(.dark)
        .id(l10n.revision)
        .onAppear {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.bind(model: model)
            } else {
                MenuBarController.shared.install(model: model)
            }
        }
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
            Button(l10n.t("update.action")) {
                // Placeholder: wire to real updater later.
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(FlowLensTheme.accentBlue.opacity(0.95)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    private var content: some View {
        OverviewTabView()
    }

    private var footer: some View {
        HStack {
            Text(l10n.t("footer.tagline"))
                .font(.system(size: 11))
                .foregroundStyle(FlowLensTheme.textSecondary)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "wifi")
                Text(l10n.t("footer.network"))
            }
            .font(.system(size: 11))
            .foregroundStyle(FlowLensTheme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// MARK: - Path dual sparkline (used by menu bar status item + popover)

/// Dual-series mini sparkline (direct green / proxy purple), iStat density.
struct PathDualSparkline: View {
    let direct: [Double]
    let proxy: [Double]

    var body: some View {
        Canvas { context, size in
            let d = pad(direct)
            let p = pad(proxy)
            let peak = max(d.max() ?? 0, p.max() ?? 0, 1)
            drawSeries(context: context, size: size, values: p, peak: peak, color: FlowLensTheme.accentPurple.opacity(0.9), fillOpacity: 0.18)
            drawSeries(context: context, size: size, values: d, peak: peak, color: FlowLensTheme.accentGreen.opacity(0.95), fillOpacity: 0.22)
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
        var line = Path()
        var fill = Path()
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * step
            let y = size.height - CGFloat(v / peak) * (size.height - 2) - 1
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
        context.stroke(line, with: .color(color), lineWidth: 1.2)
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
