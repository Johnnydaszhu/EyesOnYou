import SwiftUI
import EyesOnYouCore

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
            LiquidGlassWindowBackdrop()
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(model.appearanceMode.preferredColorScheme)
        .id(l10n.revision)
        .animation(nil, value: model.themeRevision)
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(spacing: 0) {
            liveTrafficBlock
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            appList
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 4)

            footerActions
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Live traffic (rates + period + chart)

    private var liveTrafficBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                pathRateLine(
                    label: l10n.t("status.path.direct"),
                    down: model.directDownBps,
                    up: model.directUpBps,
                    share: model.directShare,
                    color: EyesOnYouTheme.routeDirect
                )
                pathRateLine(
                    label: l10n.t("status.path.proxy"),
                    down: model.proxyDownBps,
                    up: model.proxyUpBps,
                    share: model.proxyShare,
                    color: EyesOnYouTheme.routeProxy
                )
            }

            periodSegmentedControl

            // Same series / palette as main dashboard live-traffic card.
            AreaChartView(
                down: model.sparklineDown,
                up: model.sparklineUp,
                lineWidth: 1.5
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .accessibilityHidden(true)
        }
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, alignment: .leading)
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                Text(ByteFormat.rateMBps(bytesPerSecond: down))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(EyesOnYouTheme.textPrimary)
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                Text(ByteFormat.rateMBps(bytesPerSecond: up))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(EyesOnYouTheme.textPrimary.opacity(0.9))
            Spacer(minLength: 2)
            Text("\(Int((share * 100).rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    /// Unified pill segmented control — one surface, no per-chip borders.
    private var periodSegmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.OverviewPeriod.menuQuickPeriods) { period in
                periodSegment(period)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
    }

    private func periodSegment(_ period: AppModel.OverviewPeriod) -> some View {
        let selected = model.overviewPeriod == period
        return Button {
            model.overviewPeriod = period
        } label: {
            Text(l10n.overviewPeriodTitle(period))
                .font(.system(size: 10, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? EyesOnYouTheme.textPrimary : EyesOnYouTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - App list

    private var appList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l10n.t("menu.topApps"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

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
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .frame(width: 16, alignment: .trailing)
            AppIconView(app: app.app, displayName: app.displayName, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(EyesOnYouTheme.textPrimary)
                    .lineLimit(1)
                Text(app.route.chipLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(EyesOnYouTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteFormat.string(for: app.totals.totalBytes))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(EyesOnYouTheme.textPrimary)
                HStack(spacing: 4) {
                    Text("↓\(ByteFormat.rateMBps(bytesPerSecond: app.rateDownBps))")
                    Text("↑\(ByteFormat.rateMBps(bytesPerSecond: app.rateUpBps))")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(EyesOnYouTheme.textSecondary.opacity(0.55))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            model.hoverNodeID = app.app.storageKey
            model.openDashboard()
            MenuBarController.shared.closePopover()
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 8) {
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
                .padding(.vertical, 9)
                .foregroundStyle(EyesOnYouTheme.textPrimary)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(prominent ? 0.1 : 0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(prominent ? 0.16 : 0.1), lineWidth: 0.5)
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
                    .foregroundStyle(EyesOnYouTheme.accentBlue)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(l10n.t("menu.menuStyle"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EyesOnYouTheme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Text(l10n.t("menu.style.hint"))
                .font(.system(size: 10))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            VStack(spacing: 4) {
                ForEach(AppModel.MenuBarDisplayStyle.allCases) { style in
                    styleOptionRow(style)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

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
                    .foregroundStyle(selected ? EyesOnYouTheme.accentBlue : EyesOnYouTheme.textSecondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t(style.localizationKey))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(EyesOnYouTheme.textPrimary)
                    Text(styleSubtitle(style))
                        .font(.system(size: 10))
                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(EyesOnYouTheme.accentBlue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? EyesOnYouTheme.accentBlue.opacity(0.14) : Color.clear)
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
