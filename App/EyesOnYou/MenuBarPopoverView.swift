import SwiftUI
import EyesOnYouCore

/// Single-column menu bar dropdown:
/// 1) Live / history traffic + period picker + full-width chart
/// 2) App list (at least top 10 visible)
/// 3) Footer actions: open panel / settings / menu style (opens sub-panel)
struct MenuBarPopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @State private var showingStylePicker = false
    /// Menu bar traffic scope — defaults to real-time; other picks show history traffic.
    @State private var menuTrafficPeriod: MenuBarTrafficPeriod = .realtime

    private let popoverWidth: CGFloat = 340
    private let popoverHeight: CGFloat = 640

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
        .frame(width: popoverWidth, height: popoverHeight)
        .background {
            LiquidGlassWindowBackdrop()
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(model.appearanceMode.preferredColorScheme)
        .id(l10n.revision)
        .animation(nil, value: model.themeRevision)
        .onAppear {
            applyMenuTrafficPeriod(menuTrafficPeriod)
        }
        .onChange(of: menuTrafficPeriod) { newValue in
            applyMenuTrafficPeriod(newValue)
        }
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(spacing: 0) {
            liveTrafficBlock
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

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

    // MARK: - Live / history traffic (rates + period + chart)

    private var isRealtime: Bool {
        menuTrafficPeriod == .realtime
    }

    private var liveTrafficBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isRealtime ? l10n.t("menu.liveTraffic") : l10n.t("menu.historyTraffic"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 6) {
                pathRateLine(
                    label: l10n.t("status.path.direct"),
                    downText: pathDownText(isDirect: true),
                    upText: pathUpText(isDirect: true),
                    share: pathShare(isDirect: true),
                    color: EyesOnYouTheme.routeDirect
                )
                pathRateLine(
                    label: l10n.t("status.path.proxy"),
                    downText: pathDownText(isDirect: false),
                    upText: pathUpText(isDirect: false),
                    share: pathShare(isDirect: false),
                    color: EyesOnYouTheme.routeProxy
                )
            }

            periodSegmentedControl

            AreaChartView(
                down: isRealtime ? model.sparklineDown : model.periodTrendDown,
                up: isRealtime ? model.sparklineUp : model.periodTrendUp,
                lineWidth: 1.5
            )
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .accessibilityHidden(true)
        }
    }

    private func pathDownText(isDirect: Bool) -> String {
        if isRealtime {
            return ByteFormat.rateMBps(
                bytesPerSecond: isDirect ? model.directDownBps : model.proxyDownBps
            )
        }
        let share = pathShare(isDirect: isDirect)
        let bytes = UInt64((Double(model.periodNetworkDown) * share).rounded())
        return ByteFormat.string(for: bytes)
    }

    private func pathUpText(isDirect: Bool) -> String {
        if isRealtime {
            return ByteFormat.rateMBps(
                bytesPerSecond: isDirect ? model.directUpBps : model.proxyUpBps
            )
        }
        let share = pathShare(isDirect: isDirect)
        let bytes = UInt64((Double(model.periodNetworkUp) * share).rounded())
        return ByteFormat.string(for: bytes)
    }

    private func pathShare(isDirect: Bool) -> Double {
        if isRealtime {
            return isDirect ? model.directShare : model.proxyShare
        }
        let direct = max(0, model.routeMix.directPercent) / 100
        let proxy = max(
            0,
            (model.routeMix.systemProxyPercent + model.routeMix.customProxyPercent) / 100
        )
        let sum = direct + proxy
        if sum <= 0.000_1 {
            return isDirect ? 1 : 0
        }
        return isDirect ? (direct / sum) : (proxy / sum)
    }

    private func pathRateLine(
        label: String,
        downText: String,
        upText: String,
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                Text(downText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(EyesOnYouTheme.textPrimary)
            .frame(minWidth: 72, alignment: .trailing)

            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                Text(upText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(EyesOnYouTheme.textPrimary.opacity(0.9))
            .frame(minWidth: 68, alignment: .trailing)

            Text("\(Int((share * 100).rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
    }

    /// Unified pill segmented control — real-time first, then history ranges.
    private var periodSegmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarTrafficPeriod.allCases) { period in
                periodSegment(period)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
    }

    private func periodSegment(_ period: MenuBarTrafficPeriod) -> some View {
        let selected = menuTrafficPeriod == period
        return Button {
            menuTrafficPeriod = period
        } label: {
            Text(periodTitle(period))
                .font(.system(size: 9, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? EyesOnYouTheme.textPrimary : EyesOnYouTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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

    private func periodTitle(_ period: MenuBarTrafficPeriod) -> String {
        switch period {
        case .realtime: return l10n.t("menu.period.realtime")
        case .today: return l10n.t("menu.period.today")
        case .week: return l10n.t("menu.period.week")
        case .month: return l10n.t("menu.period.month")
        case .last30Days: return l10n.t("menu.period.last30Days")
        }
    }

    private func applyMenuTrafficPeriod(_ period: MenuBarTrafficPeriod) {
        if let overview = period.overviewPeriod {
            model.overviewPeriod = overview
        }
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
                    ForEach(Array(visibleApps.enumerated()), id: \.element.id) { index, app in
                        appRow(rank: index + 1, app: app)
                    }
                }
            }
            // Tall enough for ~10 compact rows without scrolling.
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var visibleApps: [AppTrafficSnapshot] {
        let source: [AppTrafficSnapshot] = {
            if !model.rankingRows.isEmpty {
                return model.rankingRows.map(\.snapshot)
            }
            return model.topApps
        }()
        if isRealtime {
            return Array(
                source
                    .sorted {
                        ($0.rateDownBps + $0.rateUpBps) > ($1.rateDownBps + $1.rateUpBps)
                    }
                    .prefix(24)
            )
        }
        return Array(source.prefix(24))
    }

    private func appRow(rank: Int, app: AppTrafficSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .frame(width: 16, alignment: .trailing)
            AppIconView(app: app.app, displayName: app.displayName, size: 18)
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
        .padding(.vertical, 5)
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

// MARK: - Menu bar traffic period

private enum MenuBarTrafficPeriod: String, CaseIterable, Identifiable {
    case realtime
    case today
    case week
    case month
    case last30Days

    var id: String { rawValue }

    /// Maps to dashboard overview period when showing history; nil keeps live chart/rates.
    var overviewPeriod: AppModel.OverviewPeriod? {
        switch self {
        case .realtime: return nil
        case .today: return .today
        case .week: return .week
        case .month: return .month
        case .last30Days: return .last30Days
        }
    }
}
