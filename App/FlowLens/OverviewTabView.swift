import SwiftUI
import FlowLensCore
import FlowLensRuleEngine

/// Adaptive bento Overview — sizes derived from container via `BentoMetrics`.
/// Page itself does not scroll; only the ranking card list scrolls.
struct OverviewTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @FocusState private var rankingSearchFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let m = BentoMetrics(container: geo.size)
            let metricsH = m.metricsBlockHeight

            VStack(alignment: .leading, spacing: m.gap) {
                metricsBento(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: metricsH)
                detailBento(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .id(l10n.revision)
    }

    // MARK: - Row 1 metrics

    @ViewBuilder
    private func metricsBento(_ m: BentoMetrics) -> some View {
        let h = m.metricsRowHeight
        if m.isThreeUpMetrics {
            // True equal-height 3-up using Grid
            Grid(horizontalSpacing: m.gap, verticalSpacing: m.gap) {
                GridRow {
                    totalsCard(m).gridCellColumns(1)
                    liveTrafficCard(m).gridCellColumns(1)
                    proxyRoutingCard(m).gridCellColumns(1)
                }
            }
            .frame(height: h)
        } else if m.isTwoUpMetrics {
            VStack(spacing: m.gap) {
                Grid(horizontalSpacing: m.gap, verticalSpacing: m.gap) {
                    GridRow {
                        totalsCard(m)
                        liveTrafficCard(m)
                    }
                }
                .frame(height: h)
                proxyRoutingCard(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: h * 0.85)
            }
        } else {
            // compact / tiny — fill fixed metrics block height; no page scroll.
            VStack(spacing: m.gap) {
                totalsCard(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                liveTrafficCard(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                proxyRoutingCard(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Row 2 detail

    @ViewBuilder
    private func detailBento(_ m: BentoMetrics) -> some View {
        if m.isSideBySideDetail {
            GeometryReader { rowGeo in
                let sunW = m.sunburstWidth(in: rowGeo.size.width)
                HStack(alignment: .top, spacing: m.gap) {
                    pieCard(m)
                        .frame(width: sunW)
                        .frame(maxHeight: .infinity)
                    rankingTable(m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Stacked: sunburst takes a fixed share; ranking fills the rest and scrolls inside.
            VStack(spacing: m.gap) {
                pieCard(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: m.stackedSunburstHeight)
                rankingTable(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Shared card chrome (title top, body centered)

    /// Title pinned top; remaining space centers the body for consistent card alignment.
    private func bentoCard<Body: View>(
        title: String,
        systemImage: String,
        scale: CGFloat = 1,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)

            body()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flowCard()
    }

    // MARK: - Totals

    private func totalsCard(_ m: BentoMetrics) -> some View {
        bentoCard(title: totalsCardTitle, systemImage: "chart.bar.fill", scale: m.typeScale) {
            ViewThatFits(in: .vertical) {
                totalsBody(m, compact: false)
                totalsBody(m, compact: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8 * m.typeScale)
        }
    }

    private var totalsCardTitle: String {
        if let name = model.selectedAppDisplayName {
            return "\(l10n.t("overview.totals")) · \(name)"
        }
        return l10n.t("overview.totals")
    }

    private func totalsBody(_ m: BentoMetrics, compact: Bool) -> some View {
        let stackSpacing: CGFloat = compact ? 6 : 10
        return VStack(spacing: stackSpacing) {
            VStack(spacing: compact ? 4 : 6) {
                Text(l10n.t("overview.networkTraffic"))
                    .font(.system(size: 11 * m.typeScale, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.brandGreen)
                    .frame(maxWidth: .infinity, alignment: .leading)

                trendMetricRow(
                    m,
                    icon: "arrow.down.circle.fill",
                    iconColor: FlowLensTheme.brandGreen,
                    title: l10n.t("overview.netDown"),
                    value: ByteFormat.string(for: model.periodNetworkDown),
                    trend: model.periodTrendDown,
                    tint: FlowLensTheme.chartDown,
                    compact: compact
                )
                trendMetricRow(
                    m,
                    icon: "arrow.up.circle.fill",
                    iconColor: FlowLensTheme.accentOrange,
                    title: l10n.t("overview.netUp"),
                    value: ByteFormat.string(for: model.periodNetworkUp),
                    trend: model.periodTrendUp,
                    tint: FlowLensTheme.chartUp,
                    compact: compact
                )
            }

            if !compact {
                Rectangle()
                    .fill(FlowLensTheme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 4)
            }

            VStack(spacing: compact ? 4 : 6) {
                Text(l10n.t("overview.diskIO"))
                    .font(.system(size: 11 * m.typeScale, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.diskRead)
                    .frame(maxWidth: .infinity, alignment: .leading)

                inlineMetricRow(
                    m,
                    icon: "internaldrive.fill",
                    iconColor: FlowLensTheme.diskRead,
                    title: l10n.t("overview.diskRead"),
                    value: ByteFormat.string(for: model.periodDiskRead),
                    compact: compact
                )
                inlineMetricRow(
                    m,
                    icon: "externaldrive.fill.badge.plus",
                    iconColor: FlowLensTheme.diskWrite,
                    title: l10n.t("overview.diskWrite"),
                    value: ByteFormat.string(for: model.periodDiskWrite),
                    compact: compact
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Icon + label/value on the left, mini area chart on the right (same row).
    private func trendMetricRow(
        _ m: BentoMetrics,
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        trend: [Double],
        tint: Color,
        compact: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: (compact ? 12 : 14) * m.typeScale, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 16 * m.typeScale)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10 * m.typeScale))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(value)
                    .font(.system(size: m.valueFontSize * (compact ? 0.85 : 0.95), weight: .semibold, design: .rounded))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)

            MiniAreaChartView(values: trend, tint: tint)
                .frame(width: compact ? 56 : 72, height: compact ? 22 : 28)
        }
    }

    /// Icon to the left of label + value (disk rows).
    private func inlineMetricRow(
        _ m: BentoMetrics,
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        compact: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: (compact ? 12 : 14) * m.typeScale, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 16 * m.typeScale)
            Text(title)
                .font(.system(size: 10 * m.typeScale))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: m.valueFontSize * (compact ? 0.85 : 0.95), weight: .semibold, design: .rounded))
                .foregroundStyle(FlowLensTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }

    // MARK: - Live traffic (area chart)

    private func liveTrafficCard(_ m: BentoMetrics) -> some View {
        bentoCard(title: liveTrafficCardTitle, systemImage: "waveform.path", scale: m.typeScale) {
            VStack(spacing: 8 * m.typeScale) {
                // Compact rates on one line (ref layout)
                HStack(spacing: 16) {
                    rateInline(
                        m,
                        icon: "arrow.down",
                        tint: FlowLensTheme.chartDown,
                        title: l10n.t("overview.netDown"),
                        value: ByteFormat.rateMBps(bytesPerSecond: model.rateDownBps)
                    )
                    rateInline(
                        m,
                        icon: "arrow.up",
                        tint: FlowLensTheme.chartUp,
                        title: l10n.t("overview.netUp"),
                        value: ByteFormat.rateMBps(bytesPerSecond: model.rateUpBps)
                    )
                    Spacer(minLength: 0)
                }

                AreaChartView(down: model.sparklineDown, up: model.sparklineUp)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: m.areaChartHeight * 0.75, idealHeight: m.areaChartHeight, maxHeight: m.areaChartHeight * 1.2)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8 * m.typeScale)
        }
    }

    private var liveTrafficCardTitle: String {
        if let name = model.selectedAppDisplayName {
            return "\(l10n.t("overview.liveTraffic")) · \(name)"
        }
        return l10n.t("overview.liveTraffic")
    }

    private func rateInline(
        _ m: BentoMetrics,
        icon: String,
        tint: Color,
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11 * m.typeScale, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 15 * m.typeScale, weight: .bold, design: .rounded))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(title)
                    .font(.system(size: 9 * m.typeScale))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Proxy routing

    private func proxyRoutingCard(_ m: BentoMetrics) -> some View {
        bentoCard(title: proxyRoutingCardTitle, systemImage: "arrow.triangle.branch", scale: m.typeScale) {
            VStack(spacing: 10 * m.typeScale) {
                VStack(spacing: 8 * m.typeScale) {
                    routeBar(m, label: l10n.t("overview.routeDirect"), percent: model.routeMix.directPercent, color: FlowLensTheme.accentGreen)
                    routeBar(m, label: l10n.t("overview.routeSystemProxy"), percent: model.routeMix.systemProxyPercent, color: FlowLensTheme.accentAmber)
                    routeBar(m, label: l10n.t("overview.routeCustomProxy"), percent: model.routeMix.customProxyPercent, color: FlowLensTheme.accentPurple)
                }
                .frame(maxWidth: min(320, m.contentWidth * 0.9))

                HStack(spacing: 6) {
                    Text(l10n.t("overview.activeRules"))
                        .font(.system(size: 12 * m.typeScale))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(model.routeMix.activeRules)")
                        .font(.system(size: 14 * m.typeScale, weight: .bold, design: .rounded))
                        .foregroundStyle(FlowLensTheme.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8 * m.typeScale)
        }
    }

    private var proxyRoutingCardTitle: String {
        if let name = model.selectedAppDisplayName {
            return "\(l10n.t("overview.proxyRouting")) · \(name)"
        }
        return l10n.t("overview.proxyRouting")
    }

    private func routeBar(_ m: BentoMetrics, label: String, percent: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11 * m.typeScale))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text("\(Int(percent))%")
                    .font(.system(size: 11 * m.typeScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(FlowLensTheme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(FlowLensTheme.trackFill)
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, geo.size.width * percent / 100))
                }
            }
            .frame(height: max(5, 7 * m.typeScale))
        }
    }

    // MARK: - Pie chart

    private func pieCard(_ m: BentoMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8 * m.typeScale) {
            Label(l10n.t("sunburst.trafficMix"), systemImage: "chart.pie.fill")
                .font(.system(size: 10 * m.typeScale, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if model.rankingRows.isEmpty {
                Text(l10n.t("overview.pieEmpty"))
                    .font(.system(size: 12 * m.typeScale))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SunburstChart()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flowCard()
    }

    // MARK: - Fused ranking table

    private func rankingTable(_ m: BentoMetrics) -> some View {
        let rows = model.displayedRankingRows

        return VStack(alignment: .leading, spacing: 8 * m.typeScale) {
            HStack(spacing: 10) {
                Label(
                    model.isArchivePanelPresented
                        ? l10n.t("ranking.archiveTitle")
                        : l10n.t("overview.ranking"),
                    systemImage: model.isArchivePanelPresented ? "archivebox.fill" : "list.number"
                )
                .font(.system(size: 10 * m.typeScale, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                rankingColumnSpacingControl(m)
                if model.selectedApp != nil {
                    Button {
                        model.clearRankingSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            Text(l10n.t("ranking.clearFilter"))
                        }
                        .font(.system(size: 10 * m.typeScale, weight: .medium))
                        .foregroundStyle(FlowLensTheme.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.t("ranking.clearFilter.help"))
                }
                Spacer(minLength: 8)
                rankingSearchField(m)
                archiveToggleButton(m)
            }

            // Adaptive header — columns collapse with width class
            rankingHeader(m)

            Divider().overlay(FlowLensTheme.hairline)

            if !model.sunburstPath.isEmpty {
                HStack {
                    Button {
                        model.sunburstGoBack()
                    } label: {
                        Label(l10n.t("sunburst.back"), systemImage: "chevron.left")
                            .font(.system(size: 11 * m.typeScale, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FlowLensTheme.accentBlue)

                    if let title = model.drilledAppTitle {
                        Text("· \(title)")
                            .font(.system(size: 11 * m.typeScale, weight: .medium))
                            .foregroundStyle(FlowLensTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                    Text(drillSubtitle)
                        .font(.system(size: 10 * m.typeScale))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            // Only this list scrolls — page chrome stays fixed.
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        Text(
                            model.rankingFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? (model.isArchivePanelPresented
                                    ? l10n.t("ranking.archiveEmpty")
                                    : l10n.t("overview.pieEmpty"))
                                : l10n.t("search.empty")
                        )
                        .font(.system(size: 12 * m.typeScale))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rankingRow(m, index: index + 1, row: row, drilled: !model.sunburstPath.isEmpty)
                            if index < rows.count - 1 {
                                Divider().overlay(Color.white.opacity(0.04))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flowCard()
    }

    private func archiveToggleButton(_ m: BentoMetrics) -> some View {
        Button {
            model.isArchivePanelPresented.toggle()
            if model.isArchivePanelPresented {
                model.sunburstReset()
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: model.isArchivePanelPresented ? "archivebox.fill" : "archivebox")
                    .font(.system(size: 13 * m.typeScale, weight: .semibold))
                    .foregroundStyle(
                        model.isArchivePanelPresented
                            ? FlowLensTheme.accentAmber
                            : FlowLensTheme.textSecondary
                    )
                    .frame(width: 28, height: 28)
                if !model.archivedRankingRows.isEmpty {
                    Text("\(min(99, model.archivedRankingRows.count))")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(FlowLensTheme.accentAmber))
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(l10n.t("ranking.archive.help"))
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(model.isArchivePanelPresented ? 0.10 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            model.isArchivePanelPresented
                                ? FlowLensTheme.accentAmber.opacity(0.55)
                                : Color.white.opacity(0.12),
                            lineWidth: 0.8
                        )
                )
        }
    }

    private func rankingSearchField(_ m: BentoMetrics) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11 * m.typeScale, weight: .medium))
                .foregroundStyle(FlowLensTheme.textSecondary)
            TextField(l10n.t("overview.rankingSearch"), text: $model.rankingFilterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11 * m.typeScale))
                .foregroundStyle(FlowLensTheme.textPrimary)
                .focused($rankingSearchFocused)
                .help(l10n.t("overview.rankingSearch.help"))
            if !model.rankingFilterQuery.isEmpty {
                Button {
                    model.rankingFilterQuery = ""
                    rankingSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11 * m.typeScale))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 140, idealWidth: 200, maxWidth: 260)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(rankingSearchFocused ? 0.08 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            rankingSearchFocused
                                ? FlowLensTheme.accentBlue.opacity(0.55)
                                : Color.white.opacity(0.12),
                            lineWidth: 0.8
                        )
                )
        }
    }

    /// Compact − / value / + control for column title spacing (persisted on AppModel).
    private func rankingColumnSpacingControl(_ m: BentoMetrics) -> some View {
        HStack(spacing: 4) {
            Button {
                model.nudgeRankingColumnSpacing(-1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9 * m.typeScale, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlowLensTheme.textSecondary)
            .disabled(model.rankingColumnSpacing <= AppModel.rankingColumnSpacingRange.lowerBound)
            .help(l10n.t("overview.colSpacing.decrease"))

            Text("\(Int(model.rankingColumnSpacing))")
                .font(.system(size: 10 * m.typeScale, weight: .semibold, design: .monospaced))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .monospacedDigit()
                .frame(minWidth: 14)
                .help(l10n.t("overview.colSpacing.help"))

            Button {
                model.nudgeRankingColumnSpacing(1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9 * m.typeScale, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlowLensTheme.textSecondary)
            .disabled(model.rankingColumnSpacing >= AppModel.rankingColumnSpacingRange.upperBound)
            .help(l10n.t("overview.colSpacing.increase"))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background {
            Capsule()
                .fill(Color.white.opacity(0.05))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(l10n.t("overview.colSpacing.help"))
        .accessibilityValue("\(Int(model.rankingColumnSpacing))")
    }

    private func rankingHeader(_ m: BentoMetrics) -> some View {
        let gap = CGFloat(model.rankingColumnSpacing)
        return HStack(spacing: gap) {
            Text("#").frame(width: 18, alignment: .leading)
            Text(l10n.t("overview.colApp")).frame(minWidth: 72, maxWidth: .infinity, alignment: .leading)
            headerCell(l10n.t("overview.colDown"), width: colW(m, base: 56), align: .trailing)
            headerCell(l10n.t("overview.colUp"), width: colW(m, base: 56), align: .trailing)
            if m.showDiskColumns {
                headerCell(l10n.t("overview.colDiskRead"), width: colW(m, base: 56), align: .trailing)
                headerCell(l10n.t("overview.colDiskWrite"), width: colW(m, base: 56), align: .trailing)
            }
            headerCell(l10n.t("overview.colRequests"), width: colW(m, base: 44), align: .trailing)
            if m.showRouteStatusColumns {
                headerCell(l10n.t("overview.colRoute"), width: colW(m, base: 64), align: .center)
                headerCell(l10n.t("overview.colStatus"), width: colW(m, base: 56), align: .center)
            }
            if m.showGroupProxyColumns {
                headerCell(l10n.t("overview.colGroup"), width: colW(m, base: 52), align: .leading)
                headerCell(l10n.t("overview.colProxy"), width: colW(m, base: 40), align: .center)
            }
        }
        .font(.system(size: m.rankingHeaderFont, weight: .medium))
        .foregroundStyle(FlowLensTheme.textSecondary)
    }

    private func headerCell(_ title: String, width: CGFloat, align: Alignment) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .allowsTightening(true)
            .frame(width: width, alignment: align)
    }

    private func colW(_ m: BentoMetrics, base: CGFloat) -> CGFloat {
        max(36, base * m.typeScale)
    }

    /// Single-line numeric / label cell with width-adaptive type scaling.
    private func adaptiveCell(
        _ text: String,
        width: CGFloat,
        align: Alignment = .trailing,
        color: Color = FlowLensTheme.textPrimary,
        minScale: CGFloat = 0.5
    ) -> some View {
        Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(minScale)
            .allowsTightening(true)
            .truncationMode(.tail)
            .frame(width: width, alignment: align)
    }

    private var drillSubtitle: String {
        guard let id = model.sunburstPath.first,
              let row = model.rankingRows.first(where: { $0.id == id }) else {
            return ""
        }
        let key = DrillableIdentity.childLabelKey(for: row.snapshot.app)
        return l10n.t(key)
    }

    private func rankingRow(_ m: BentoMetrics, index: Int, row: AppModel.AppRankingRow, drilled: Bool) -> some View {
        let app = row.snapshot
        let statusBlocked = model.isBlocked(app.app) || app.firewallStatus == .block
        let hoverID = drilled ? "\(app.app.storageKey)|\(app.displayName)" : row.id
        let isSelected = !drilled && model.selectedApp == app.app
        let highlighted = isSelected
            || isRowHighlighted(row.id) || isRowHighlighted(hoverID)
            || (drilled && model.hoverNodeID?.hasSuffix("|" + destinationKeyHint(row)) == true)
            || (drilled && model.hoverNodeID?.contains("|" + row.snapshot.displayName.lowercased()) == true)
        let dimmed = model.hoverNodeID != nil && !highlighted && !isDrilledChildHighlighted(row) && !isSelected
        let dw = colW(m, base: 56)
        let iconSize: CGFloat = 16 * m.typeScale

        let routeW = colW(m, base: 64)
        let statusW = colW(m, base: 56)
        let groupW = colW(m, base: 52)
        let proxyW = colW(m, base: 40)
        let badgeFont = max(9, m.rankingRowFont * 0.95)
        let gap = CGFloat(model.rankingColumnSpacing)

        return HStack(spacing: gap) {
            Text("\(index)")
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 18, alignment: .leading)

            HStack(spacing: 5) {
                if !drilled {
                    FavoriteButton(app: app.app, size: 10 * m.typeScale)
                } else {
                    Image(systemName: drillIcon(for: app.app))
                        .font(.system(size: 10 * m.typeScale))
                        .foregroundStyle(FlowLensTheme.accentPurple)
                        .frame(width: 12)
                }
                AppIconView(app: app.app, displayName: app.displayName, size: iconSize)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(app.displayName)
                            .foregroundStyle(FlowLensTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .allowsTightening(true)
                        if !drilled, model.isFavorite(app.app) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8 * m.typeScale))
                                .foregroundStyle(FlowLensTheme.gold)
                        }
                        if !drilled, statusBlocked {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 8 * m.typeScale))
                                .foregroundStyle(FlowLensTheme.accentRed)
                        }
                    }
                    if !drilled && !app.sites.isEmpty {
                        Text(childCountLabel(app))
                            .font(.system(size: 9 * m.typeScale))
                            .foregroundStyle(FlowLensTheme.accentBlue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .allowsTightening(true)
                    }
                }
                .layoutPriority(1)
            }
            .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)

            adaptiveCell(ByteFormat.string(for: app.totals.bytesDown), width: dw)
            adaptiveCell(ByteFormat.string(for: app.totals.bytesUp), width: dw)
            if m.showDiskColumns {
                adaptiveCell(
                    ByteFormat.string(for: row.diskRead),
                    width: dw,
                    color: FlowLensTheme.diskRead
                )
                adaptiveCell(
                    ByteFormat.string(for: row.diskWrite),
                    width: dw,
                    color: FlowLensTheme.diskWrite
                )
            }
            adaptiveCell("\(app.totals.flowsOpened)", width: colW(m, base: 44))

            if m.showRouteStatusColumns {
                RouteBadge(
                    label: app.route.chipLabel,
                    fontSize: badgeFont,
                    horizontalPadding: 6,
                    verticalPadding: 2,
                    minScale: 0.5
                )
                .frame(width: routeW)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 3) {
                    Circle()
                        .fill(statusBlocked ? FlowLensTheme.accentRed : FlowLensTheme.accentGreen)
                        .frame(width: 6, height: 6)
                        .layoutPriority(1)
                    Text(statusBlocked ? l10n.t("overview.blocked") : l10n.t("overview.allowed"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                        .truncationMode(.tail)
                }
                .frame(width: statusW, alignment: .leading)
                .foregroundStyle(statusBlocked ? FlowLensTheme.accentRed : FlowLensTheme.accentGreen)
            }

            if m.showGroupProxyColumns {
                adaptiveCell(
                    row.groupName ?? l10n.t("overview.ungrouped"),
                    width: groupW,
                    align: .leading,
                    color: row.groupName == nil ? FlowLensTheme.textSecondary : FlowLensTheme.textPrimary,
                    minScale: 0.45
                )

                Toggle("", isOn: Binding(
                    get: { ProxyToggleLogic.isProxyEnabled(app.route) },
                    set: { _ in model.toggleAppProxy(app) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: proxyW)
            }
        }
        .font(.system(size: m.rankingRowFont))
        .foregroundStyle(FlowLensTheme.textPrimary)
        .padding(.vertical, 6 * m.typeScale)
        .padding(.horizontal, 2)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FlowLensTheme.brandGreen.opacity(isSelected ? 0.16 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                FlowLensTheme.brandGreen.opacity(isSelected ? 0.45 : 0.28),
                                lineWidth: isSelected ? 1.1 : 0.8
                            )
                    )
            }
        }
        .opacity(dimmed ? 0.38 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.setHoverNode(row.id)
            } else if model.hoverNodeID == row.id {
                model.setHoverNode(nil)
            }
        }
        .onTapGesture(count: 2) {
            if !drilled, !app.sites.isEmpty {
                model.drillInto(nodeID: row.id)
            }
        }
        .onTapGesture(count: 1) {
            if drilled { return }
            model.selectRankingApp(app.app)
        }
        .contextMenu {
            if !drilled {
                rankingContextMenu(for: app.app, displayName: app.displayName, hasSites: !app.sites.isEmpty, rowID: row.id)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.hoverNodeID)
        .animation(.easeOut(duration: 0.15), value: model.selectedApp)
    }

    @ViewBuilder
    private func rankingContextMenu(
        for app: AppIdentityKey,
        displayName: String,
        hasSites: Bool,
        rowID: String
    ) -> some View {
        Button {
            model.selectRankingApp(app)
        } label: {
            Label(
                model.selectedApp == app ? l10n.t("ranking.clearFilter") : l10n.t("ranking.filterCards"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }

        if hasSites {
            Button {
                model.drillInto(nodeID: rowID)
            } label: {
                Label(l10n.t("ranking.drill"), systemImage: "arrow.down.right.and.arrow.up.left")
            }
        }

        Divider()

        Button {
            model.toggleFavorite(app)
        } label: {
            Label(
                model.isFavorite(app) ? l10n.t("favorite.unpin") : l10n.t("favorite.pin"),
                systemImage: model.isFavorite(app) ? "star.slash" : "star"
            )
        }

        Button {
            model.toggleBlock(app)
        } label: {
            Label(
                model.isBlocked(app) ? l10n.t("ranking.unblock") : l10n.t("ranking.block"),
                systemImage: model.isBlocked(app) ? "hand.raised.slash" : "hand.raised"
            )
        }

        Button {
            model.toggleArchive(app)
        } label: {
            Label(
                model.isArchived(app) ? l10n.t("ranking.unarchive") : l10n.t("ranking.archive"),
                systemImage: model.isArchived(app) ? "tray.and.arrow.up" : "archivebox"
            )
        }

        Divider()

        Button {
            model.revealInFinder(app)
        } label: {
            Label(l10n.t("ranking.revealFinder"), systemImage: "folder")
        }

        Button(role: .destructive) {
            model.deleteAppFromRanking(app)
        } label: {
            Label(l10n.t("ranking.delete"), systemImage: "trash")
        }
    }

    private func isRowHighlighted(_ rowID: String) -> Bool {
        guard let hover = model.hoverNodeID else { return false }
        if hover == rowID { return true }
        if hover.hasPrefix(rowID + "|") { return true }
        return false
    }

    private func isDrilledChildHighlighted(_ row: AppModel.AppRankingRow) -> Bool {
        guard let hover = model.hoverNodeID else { return false }
        return hover.contains("|") && (
            hover.hasSuffix("|" + row.snapshot.displayName)
            || hover.contains("|" + row.snapshot.displayName)
            || hover.lowercased().contains(row.snapshot.displayName.lowercased())
        )
    }

    private func destinationKeyHint(_ row: AppModel.AppRankingRow) -> String {
        row.snapshot.displayName
    }

    private func childCountLabel(_ app: AppTrafficSnapshot) -> String {
        let kind = DrillableIdentity.segmentKind(for: app.app)
        let key: String
        switch kind {
        case .website: key = "overview.sitesCount"
        case .project: key = "overview.projectsCount"
        case .session: key = "overview.sessionsCount"
        case .destination: key = "overview.destinationsCount"
        }
        return l10n.t(key, app.sites.count)
    }

    private func drillIcon(for app: AppIdentityKey) -> String {
        switch DrillableIdentity.segmentKind(for: app) {
        case .website: return "globe"
        case .project: return "folder.fill"
        case .session: return "bubble.left.and.bubble.right.fill"
        case .destination: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Area chart (live traffic)

/// Single-series mini area chart for totals card trend rows.
struct MiniAreaChartView: View {
    let values: [Double]
    var tint: Color = FlowLensTheme.chartDown
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let maxV = max(values.max() ?? 1, 1)
            let top = tint.opacity(colorScheme == .light ? 0.30 : 0.42)
            let bot = tint.opacity(0.04)

            ZStack {
                filledArea(values: values, width: w, height: h, maxV: maxV)
                    .fill(
                        LinearGradient(colors: [top, bot], startPoint: .top, endPoint: .bottom)
                    )
                linePath(values: values, width: w, height: h, maxV: maxV)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func linePath(values: [Double], width: CGFloat, height: CGFloat, maxV: Double) -> Path {
        guard values.count > 1 else { return Path() }
        var p = Path()
        for (i, v) in values.enumerated() {
            let x = width * CGFloat(i) / CGFloat(values.count - 1)
            let y = height - (height * CGFloat(v / maxV)) * 0.88
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }

    private func filledArea(values: [Double], width: CGFloat, height: CGFloat, maxV: Double) -> Path {
        guard values.count > 1 else { return Path() }
        var p = Path()
        p.move(to: CGPoint(x: 0, y: height))
        for (i, v) in values.enumerated() {
            let x = width * CGFloat(i) / CGFloat(values.count - 1)
            let y = height - (height * CGFloat(v / maxV)) * 0.88
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: width, y: height))
        p.closeSubpath()
        return p
    }
}

/// Dual-series area chart: download (soft green) + upload (orange) — matches design refs.
struct AreaChartView: View {
    let down: [Double]
    let up: [Double]
    var lineWidth: CGFloat = 1.8
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let maxV = max(down.max() ?? 1, up.max() ?? 1, 1)
            let isLight = colorScheme == .light
            let downFillTop = FlowLensTheme.chartDown.opacity(isLight ? 0.28 : 0.38)
            let downFillBot = FlowLensTheme.chartDown.opacity(isLight ? 0.04 : 0.05)
            let upStroke = FlowLensTheme.chartUp

            ZStack {
                // Soft horizontal guides
                ForEach(0..<3, id: \.self) { i in
                    let y = h * CGFloat(i + 1) / 4
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(FlowLensTheme.hairline.opacity(0.7), lineWidth: 0.5)
                }

                // Download area + line (primary series)
                filledArea(values: down, width: w, height: h, maxV: maxV)
                    .fill(
                        LinearGradient(
                            colors: [downFillTop, downFillBot],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                linePath(values: down, width: w, height: h, maxV: maxV)
                    .stroke(
                        FlowLensTheme.chartDown.opacity(isLight ? 0.55 : 0.75),
                        style: StrokeStyle(lineWidth: lineWidth * 0.85, lineCap: .round, lineJoin: .round)
                    )

                // Upload line (orange accent; lighter fill so green stays dominant)
                filledArea(values: up, width: w, height: h, maxV: maxV)
                    .fill(
                        LinearGradient(
                            colors: [
                                upStroke.opacity(isLight ? 0.14 : 0.22),
                                upStroke.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                linePath(values: up, width: w, height: h, maxV: maxV)
                    .stroke(
                        upStroke,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func linePath(values: [Double], width: CGFloat, height: CGFloat, maxV: Double) -> Path {
        guard values.count > 1 else { return Path() }
        var p = Path()
        for (i, v) in values.enumerated() {
            let x = width * CGFloat(i) / CGFloat(values.count - 1)
            let y = height - (height * CGFloat(v / maxV)) * 0.92
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }

    private func filledArea(values: [Double], width: CGFloat, height: CGFloat, maxV: Double) -> Path {
        guard values.count > 1 else { return Path() }
        var p = Path()
        p.move(to: CGPoint(x: 0, y: height))
        for (i, v) in values.enumerated() {
            let x = width * CGFloat(i) / CGFloat(values.count - 1)
            let y = height - (height * CGFloat(v / maxV)) * 0.92
            if i == 0 {
                p.addLine(to: CGPoint(x: x, y: y))
            } else {
                p.addLine(to: CGPoint(x: x, y: y))
            }
        }
        p.addLine(to: CGPoint(x: width, y: height))
        p.closeSubpath()
        return p
    }
}

/// Thin dual-line sparkline for compact surfaces (menu bar).
struct SparklineView: View {
    let down: [Double]
    let up: [Double]

    var body: some View {
        AreaChartView(down: down, up: up, lineWidth: 1.2)
    }
}
