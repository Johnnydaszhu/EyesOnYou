import SwiftUI
import FlowLensCore

/// Single-column menu bar dropdown:
/// 1) Live traffic + period picker + full-width chart
/// 2) App list
/// 3) Footer actions: open panel / settings / menu style (opens sub-panel)
struct MenuBarPopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @State private var showingStylePicker = false

    private let popoverWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 0) {
            if showingStylePicker {
                stylePickerPanel
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                mainPanel
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingStylePicker)
        .frame(width: popoverWidth)
        .frame(minHeight: 380, maxHeight: 520)
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Circle()
                    .fill(FlowLensTheme.accentBlue.opacity(0.14))
                    .frame(width: 160, height: 160)
                    .blur(radius: 36)
                    .offset(x: -70, y: -80)
                Circle()
                    .fill(FlowLensTheme.gold.opacity(0.08))
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

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(spacing: 0) {
            liveTrafficBlock
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
                .padding(.vertical, 8)
        }
    }

    // MARK: - Live traffic (rates + full-width chart + period)

    private var liveTrafficBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
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
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(AppModel.OverviewPeriod.menuQuickPeriods) { period in
                        periodChip(period)
                    }
                }
            }

            PathDualSparkline(
                direct: model.sparklineDirect,
                proxy: model.sparklineProxy
            )
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .accessibilityHidden(true)
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
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, alignment: .leading)
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                Text(ByteFormat.rateMBps(bytesPerSecond: down))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(FlowLensTheme.textPrimary)
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                Text(ByteFormat.rateMBps(bytesPerSecond: up))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(FlowLensTheme.textPrimary.opacity(0.9))
            Spacer(minLength: 2)
            Text("\(Int((share * 100).rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
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
                .padding(.vertical, 4)
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

    // MARK: - App list

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
            .frame(maxHeight: 260)
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

    // MARK: - Footer (text only, compact)

    private var footerActions: some View {
        HStack(spacing: 6) {
            footerTextButton(title: l10n.t("menu.openDashboard"), prominent: true) {
                model.openDashboard()
                MenuBarController.shared.closePopover()
            }
            footerTextButton(title: l10n.t("settings.title"), prominent: false) {
                model.openSettings()
            }
            footerTextButton(title: l10n.t("menu.menuStyle"), prominent: false) {
                showingStylePicker = true
            }
        }
    }

    private func footerTextButton(
        title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : FlowLensTheme.textPrimary)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            prominent
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            FlowLensTheme.gold.opacity(0.95),
                                            FlowLensTheme.gold.opacity(0.65)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                : AnyShapeStyle(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(prominent ? 0.2 : 0.1), lineWidth: 0.7)
                        )
                }
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - Style picker sub-panel

    private var stylePickerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showingStylePicker = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text(l10n.t("menu.style.back"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(FlowLensTheme.accentBlue)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(l10n.t("menu.menuStyle"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(Color.white.opacity(0.08))

            Text(l10n.t("menu.style.hint"))
                .font(.system(size: 10))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            VStack(spacing: 6) {
                ForEach(AppModel.MenuBarDisplayStyle.allCases) { style in
                    styleOptionRow(style)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func styleOptionRow(_ style: AppModel.MenuBarDisplayStyle) -> some View {
        let selected = model.menuBarDisplayStyle == style
        return Button {
            model.menuBarDisplayStyle = style
            MenuBarController.shared.refreshStatusItemAppearance()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: styleIcon(style))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? FlowLensTheme.accentBlue : FlowLensTheme.textSecondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t(style.localizationKey))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(FlowLensTheme.textPrimary)
                    Text(styleSubtitle(style))
                        .font(.system(size: 10))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FlowLensTheme.accentBlue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? FlowLensTheme.accentBlue.opacity(0.14) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                selected
                                    ? FlowLensTheme.accentBlue.opacity(0.45)
                                    : Color.white.opacity(0.08),
                                lineWidth: selected ? 1 : 0.7
                            )
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func styleIcon(_ style: AppModel.MenuBarDisplayStyle) -> String {
        switch style {
        case .dualPath: return "chart.xyaxis.line"
        case .compactRates: return "speedometer"
        case .iconOnly: return "app.fill"
        }
    }

    private func styleSubtitle(_ style: AppModel.MenuBarDisplayStyle) -> String {
        switch style {
        case .dualPath: return l10n.t("menu.style.dualPath.detail")
        case .compactRates: return l10n.t("menu.style.compactRates.detail")
        case .iconOnly: return l10n.t("menu.style.iconOnly.detail")
        }
    }
}
