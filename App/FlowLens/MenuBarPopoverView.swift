import SwiftUI
import FlowLensCore

/// Single-column menu bar dropdown:
/// 1) Live traffic + period picker
/// 2) App list
/// 3) Footer actions: open panel / settings / menu style
struct MenuBarPopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    private let popoverWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            liveTrafficRow
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider().overlay(Color.white.opacity(0.08))

            appList
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

            Divider().overlay(Color.white.opacity(0.08))

            footerActions
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: popoverWidth)
        .frame(minHeight: 380, maxHeight: 520)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Circle()
                    .fill(FlowLensTheme.accentBlue.opacity(0.16))
                    .frame(width: 160, height: 160)
                    .blur(radius: 36)
                    .offset(x: -70, y: -80)
                Circle()
                    .fill(FlowLensTheme.gold.opacity(0.1))
                    .frame(width: 140, height: 140)
                    .blur(radius: 32)
                    .offset(x: 90, y: 160)
                Color.black.opacity(0.14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.26), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .id(l10n.revision)
    }

    // MARK: - Row 1: live traffic + period picker

    private var liveTrafficRow: some View {
        HStack(alignment: .top, spacing: 10) {
            PathDualSparkline(
                direct: model.sparklineDirect,
                proxy: model.sparklineProxy
            )
            .frame(width: 52, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                pathRateLine(
                    label: l10n.t("status.path.direct"),
                    down: model.directDownBps,
                    up: model.directUpBps,
                    share: model.directShare,
                    color: FlowLensTheme.accentGreen
                )
                pathRateLine(
                    label: l10n.t("status.path.proxy"),
                    down: model.proxyDownBps,
                    up: model.proxyUpBps,
                    share: model.proxyShare,
                    color: FlowLensTheme.accentPurple
                )
            }

            Spacer(minLength: 4)

            // Top-right period picker: 今天 / 本周 / 本月 / 近 30 天
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(AppModel.OverviewPeriod.menuQuickPeriods) { period in
                    periodChip(period)
                }
            }
        }
        .padding(12)
        .background { LiquidGlassBackground(style: .inset, cornerRadius: 12) }
    }

    private func pathRateLine(
        label: String,
        down: Double,
        up: Double,
        share: Double,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, alignment: .leading)
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text(ByteFormat.rateMBps(bytesPerSecond: down))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(FlowLensTheme.textPrimary)
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .bold))
                Text(ByteFormat.rateMBps(bytesPerSecond: up))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(FlowLensTheme.textPrimary.opacity(0.9))
            Text("\(Int((share * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func periodChip(_ period: AppModel.OverviewPeriod) -> some View {
        let selected = model.overviewPeriod == period
        return Button {
            model.overviewPeriod = period
        } label: {
            Text(l10n.overviewPeriodTitle(period))
                .font(.system(size: 10, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.black.opacity(0.88) : FlowLensTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    if selected {
                        Capsule()
                            .fill(FlowLensTheme.accentBlue.opacity(0.92))
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row 2: app list

    private var appList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.t("menu.topApps"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            ScrollView {
                LazyVStack(spacing: 0) {
                    let apps: [AppTrafficSnapshot] = {
                        if !model.rankingRows.isEmpty {
                            return Array(model.rankingRows.prefix(24).map(\.snapshot))
                        }
                        return Array(model.topApps.prefix(24))
                    }()
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        appRow(rank: index + 1, app: app)
                        if index < apps.count - 1 {
                            Divider().overlay(Color.white.opacity(0.05))
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    private func appRow(rank: Int, app: AppTrafficSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .frame(width: 16, alignment: .trailing)
            AppIconView(app: app.app, displayName: app.displayName, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                    .lineLimit(1)
                Text(app.route.chipLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteFormat.string(for: app.totals.totalBytes))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                HStack(spacing: 4) {
                    Text("↓\(ByteFormat.rateMBps(bytesPerSecond: app.rateDownBps))")
                    Text("↑\(ByteFormat.rateMBps(bytesPerSecond: app.rateUpBps))")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(FlowLensTheme.textSecondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            model.hoverNodeID = app.app.storageKey
            model.openDashboard()
            MenuBarController.shared.closePopover()
        }
    }

    // MARK: - Footer actions

    private var footerActions: some View {
        HStack(spacing: 8) {
            footerButton(
                title: l10n.t("menu.openDashboard"),
                systemImage: "macwindow",
                prominent: true
            ) {
                model.openDashboard()
                MenuBarController.shared.closePopover()
            }

            footerButton(
                title: l10n.t("settings.title"),
                systemImage: "gearshape",
                prominent: false
            ) {
                model.openSettings()
                MenuBarController.shared.closePopover()
            }

            footerButton(
                title: l10n.t("menu.menuStyle"),
                systemImage: "menubar.rectangle",
                prominent: false
            ) {
                model.cycleMenuBarDisplayStyle()
                MenuBarController.shared.refreshStatusItemAppearance()
            }
        }
    }

    private func footerButton(
        title: String,
        systemImage: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : FlowLensTheme.textPrimary)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        prominent
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [FlowLensTheme.gold.opacity(0.95), FlowLensTheme.gold.opacity(0.65)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(prominent ? 0.2 : 0.1), lineWidth: 0.7)
                    )
            }
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
