import SwiftUI
import AppKit
import EyesOnYouCore
import EyesOnYouRuleEngine

/// Adaptive bento Overview — sizes derived from container via `BentoMetrics`.
/// Page itself does not scroll; only the ranking card list scrolls.
struct OverviewTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @FocusState private var rankingSearchFocused: Bool
    @State private var spacingDragOrigin: Double? = nil
    @State private var isSystemProxyEndpointRevealed = false

    var body: some View {
        GeometryReader { geo in
            let m = BentoMetrics(container: geo.size)
            bentoLayout(m, size: geo.size)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .id(l10n.revision)
    }

    /// Single column grid for the whole page so gutters line up across rows.
    @ViewBuilder
    private func bentoLayout(_ m: BentoMetrics, size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let gap = m.gap

        if m.isThreeUpMetrics {
            // Live → cumulative network → proxy; col1 width locks left card ↔ pie.
            let col1 = m.columnWidth(in: w, columns: 3)
            let metricsH = m.metricsRowHeight

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    liveTrafficCard(m)
                        .frame(width: col1, height: metricsH)
                    networkTrafficCard(m)
                        .frame(maxWidth: .infinity)
                        .frame(height: metricsH)
                    proxyRoutingCard(m)
                        .frame(maxWidth: .infinity)
                        .frame(height: metricsH)
                }
                .frame(width: w, height: metricsH, alignment: .leading)

                HStack(alignment: .top, spacing: gap) {
                    pieCard(m)
                        .frame(width: col1)
                        .frame(maxHeight: .infinity)
                    rankingTable(m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: w, height: max(0, h - metricsH - gap), alignment: .topLeading)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        } else if m.isTwoUpMetrics {
            // Live | cumulative on row 1; proxy strip; pie under live.
            let col1 = m.columnWidth(in: w, columns: 2)
            let metricsH = m.metricsRowHeight
            let proxyH = metricsH * 0.85
            let metricsBlock = metricsH + gap + proxyH

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    liveTrafficCard(m)
                        .frame(width: col1, height: metricsH)
                    networkTrafficCard(m)
                        .frame(maxWidth: .infinity)
                        .frame(height: metricsH)
                }
                .frame(width: w, height: metricsH, alignment: .leading)

                proxyRoutingCard(m)
                    .frame(width: w, height: proxyH)

                HStack(alignment: .top, spacing: gap) {
                    pieCard(m)
                        .frame(width: col1)
                        .frame(maxHeight: .infinity)
                    rankingTable(m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: w, height: max(0, h - metricsBlock - gap), alignment: .topLeading)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        } else {
            // compact / tiny — live, cumulative network, proxy, pie, ranking
            VStack(spacing: gap) {
                liveTrafficCard(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: m.metricsRowHeight * 0.72)
                networkTrafficCard(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: m.metricsRowHeight * 0.72)
                proxyRoutingCard(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: m.metricsRowHeight * 0.72)
                pieCard(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: m.stackedSunburstHeight)
                rankingTable(m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
    }

    // MARK: - Shared card chrome (title band + top-aligned body)

    /// Fixed title band so all metric cards share the same content origin.
    private func bentoCard<Body: View>(
        title: String,
        systemImage: String,
        scale: CGFloat = 1,
        showsTitle: Bool = true,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(EyesOnYouTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16 * scale, alignment: .leading)
            }

            body()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flowCard()
    }

    // MARK: - Network traffic (cumulative period trend)

    private var hasNetworkTrendSamples: Bool {
        model.periodTrendDown.contains(where: { $0 > 0 })
            || model.periodTrendUp.contains(where: { $0 > 0 })
            || model.periodNetworkDown > 0
            || model.periodNetworkUp > 0
    }

    /// Cumulative download / upload for the selected period — same chart chrome as live.
    private func networkTrafficCard(_ m: BentoMetrics) -> some View {
        let metaH = 36 * m.typeScale
        let footerH = 18 * m.typeScale
        return bentoCard(title: networkTrafficCardTitle, systemImage: "chart.xyaxis.line", scale: m.typeScale) {
            VStack(spacing: 8 * m.typeScale) {
                HStack(spacing: 16) {
                    rateInline(
                        m,
                        icon: "arrow.down",
                        tint: EyesOnYouTheme.chartDown,
                        title: l10n.t("overview.netDown"),
                        value: ByteFormat.string(for: model.periodNetworkDown)
                    )
                    rateInline(
                        m,
                        icon: "arrow.up",
                        tint: EyesOnYouTheme.chartUp,
                        title: l10n.t("overview.netUp"),
                        value: ByteFormat.string(for: model.periodNetworkUp)
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: metaH, alignment: .center)

                ZStack {
                    AreaChartView(down: model.periodTrendDown, up: model.periodTrendUp)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(hasNetworkTrendSamples ? 1 : 0.28)
                    if !hasNetworkTrendSamples {
                        Text(l10n.t("overview.networkTrafficEmpty"))
                            .font(.system(size: 11 * m.typeScale))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                metricTimeCaption(
                    String(
                        format: l10n.t("overview.cumulativePeriod"),
                        l10n.overviewRangeCaption(
                            start: model.periodRangeStart,
                            end: model.periodRangeEnd
                        )
                    ),
                    height: footerH,
                    scale: m.typeScale
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8 * m.typeScale)
        }
    }

    private var networkTrafficCardTitle: String {
        if let name = model.selectedAppDisplayName {
            return "\(l10n.t("overview.networkTraffic")) · \(name)"
        }
        return l10n.t("overview.networkTraffic")
    }

    // MARK: - Live traffic (area chart)

    private var hasLiveTrafficSamples: Bool {
        model.rateDownBps > 1 || model.rateUpBps > 1
            || model.sparklineDown.contains(where: { $0 > 1 })
            || model.sparklineUp.contains(where: { $0 > 1 })
    }

    private func liveTrafficCard(_ m: BentoMetrics) -> some View {
        let metaH = 36 * m.typeScale
        let footerH = 18 * m.typeScale
        return bentoCard(title: liveTrafficCardTitle, systemImage: "waveform.path", scale: m.typeScale) {
            VStack(spacing: 8 * m.typeScale) {
                HStack(spacing: 16) {
                    rateInline(
                        m,
                        icon: "arrow.down",
                        tint: EyesOnYouTheme.chartDown,
                        title: l10n.t("overview.netDown"),
                        value: ByteFormat.rateMBps(bytesPerSecond: model.rateDownBps)
                    )
                    rateInline(
                        m,
                        icon: "arrow.up",
                        tint: EyesOnYouTheme.chartUp,
                        title: l10n.t("overview.netUp"),
                        value: ByteFormat.rateMBps(bytesPerSecond: model.rateUpBps)
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: metaH, alignment: .center)

                ZStack {
                    AreaChartView(down: model.sparklineDown, up: model.sparklineUp)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(hasLiveTrafficSamples ? 1 : 0.28)
                    if !hasLiveTrafficSamples {
                        Text(l10n.t("overview.liveTrafficEmpty"))
                            .font(.system(size: 11 * m.typeScale))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                metricTimeCaption(
                    l10n.t("overview.liveWindow"),
                    height: footerH,
                    scale: m.typeScale
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    .foregroundStyle(EyesOnYouTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(title)
                    .font(.system(size: 9 * m.typeScale))
                    .foregroundStyle(EyesOnYouTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Short time scope directly inside each speed / total card, so a rate cannot be
    /// mistaken for a cumulative value and the cumulative range remains visible after
    /// the global picker scrolls out of view.
    private func metricTimeCaption(_ text: String, height: CGFloat, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9 * scale, weight: .medium, design: .rounded))
            .foregroundStyle(EyesOnYouTheme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .center)
    }

    // MARK: - Proxy routing

    /// True when path mix comes from observed bytes, a local proxy client, or an app selection.
    private var hasRouteTrafficSamples: Bool {
        if model.selectedApp != nil { return true }
        if model.systemProxy.isEnabled { return true }
        if model.systemProxyNodeIP != nil { return true }
        if model.rankingRows.contains(where: { $0.snapshot.totals.totalBytes > 0 }) { return true }
        // Proxy off → 100% direct is the real fail-open policy, not a placeholder.
        if !model.proxyEnabled { return true }
        return model.routeMix.systemProxyPercent > 0 || model.routeMix.customProxyPercent > 0
    }

    private func proxyRoutingCard(_ m: BentoMetrics) -> some View {
        let metaH = 36 * m.typeScale
        let footerH = 18 * m.typeScale
        return bentoCard(title: proxyRoutingCardTitle, systemImage: "arrow.triangle.branch", scale: m.typeScale) {
            VStack(spacing: 8 * m.typeScale) {
                HStack(spacing: 12) {
                    routeLegendChip(
                        m,
                        tint: EyesOnYouTheme.routeDirect,
                        title: l10n.t("overview.routeDirect"),
                        percent: model.routeMix.directPercent
                    )
                    routeLegendChip(
                        m,
                        tint: EyesOnYouTheme.routeSystem,
                        title: l10n.t("overview.routeSystemProxy"),
                        percent: model.routeMix.systemProxyPercent
                    )
                    routeLegendChip(
                        m,
                        tint: EyesOnYouTheme.routeProxy,
                        title: l10n.t("overview.routeCustomProxy"),
                        percent: model.routeMix.customProxyPercent
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: metaH, alignment: .center)

                ZStack {
                    RouteMixAreaChartView(
                        direct: model.sparklineRouteDirect,
                        system: model.sparklineRouteSystem,
                        custom: model.sparklineRouteCustom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(hasRouteTrafficSamples ? 1 : 0.28)
                    if !hasRouteTrafficSamples {
                        Text(l10n.t("overview.proxyRoutingEmpty"))
                            .font(.system(size: 11 * m.typeScale))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 6) {
                    if let nodeIP = model.systemProxyNodeIP {
                        Text(l10n.t("overview.systemProxyEndpoint.ipLabel"))
                            .font(.system(size: 11 * m.typeScale))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(isSystemProxyEndpointRevealed ? nodeIP : String(repeating: "•", count: min(nodeIP.count, 11)))
                            .font(.system(size: 11 * m.typeScale, weight: .semibold, design: .monospaced))
                            .foregroundStyle(EyesOnYouTheme.routeSystem)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .help(isSystemProxyEndpointRevealed ? nodeIP : l10n.t("overview.systemProxyEndpoint.hidden"))
                        Button {
                            isSystemProxyEndpointRevealed.toggle()
                        } label: {
                            Image(systemName: isSystemProxyEndpointRevealed ? "eye.slash" : "eye")
                                .font(.system(size: 11 * m.typeScale, weight: .semibold))
                                .foregroundStyle(EyesOnYouTheme.textSecondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(
                            isSystemProxyEndpointRevealed
                                ? l10n.t("overview.systemProxyEndpoint.hide")
                                : l10n.t("overview.systemProxyEndpoint.show")
                        )
                    } else {
                        Text(l10n.t("overview.activeRules"))
                            .font(.system(size: 11 * m.typeScale))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("\(model.routeMix.activeRules)")
                            .font(.system(size: 13 * m.typeScale, weight: .bold, design: .rounded))
                            .foregroundStyle(EyesOnYouTheme.textPrimary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: footerH, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8 * m.typeScale)
        }
    }

    private var proxyRoutingCardTitle: String {
        if let name = model.selectedAppDisplayName {
            return "\(l10n.t("overview.proxyRouting")) · \(name)"
        }
        return l10n.t("overview.proxyRouting")
    }

    private func routeLegendChip(
        _ m: BentoMetrics,
        tint: Color,
        title: String,
        percent: Double
    ) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Int(percent.rounded()))%")
                    .font(.system(size: 13 * m.typeScale, weight: .bold, design: .rounded))
                    .foregroundStyle(EyesOnYouTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 9 * m.typeScale))
                    .foregroundStyle(EyesOnYouTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    // MARK: - Pie chart

    private func pieCard(_ m: BentoMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8 * m.typeScale) {
            Label(l10n.t("sunburst.trafficMix"), systemImage: "chart.pie.fill")
                .font(.system(size: 10 * m.typeScale, weight: .semibold))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16 * m.typeScale, alignment: .leading)

            if model.rankingRows.isEmpty {
                Text(l10n.t("overview.pieEmpty"))
                    .font(.system(size: 12 * m.typeScale))
                    .foregroundStyle(EyesOnYouTheme.textSecondary)
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

    /// Card shell: measures its own content width so the table can spread columns
    /// across it instead of hugging the left edge.
    private func rankingTable(_ m: BentoMetrics) -> some View {
        GeometryReader { geo in
            rankingTableBody(m, available: geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flowCard()
    }

    private func rankingTableBody(_ m: BentoMetrics, available: CGFloat) -> some View {
        let rows = model.displayedRankingRows
        let colInset: CGFloat = 2

        return VStack(alignment: .leading, spacing: 8 * m.typeScale) {
            HStack(spacing: 10) {
                Label(
                    model.isArchivePanelPresented
                        ? l10n.t("ranking.archiveTitle")
                        : l10n.t("overview.ranking"),
                    systemImage: model.isArchivePanelPresented ? "archivebox.fill" : "list.number"
                )
                .font(.system(size: 10 * m.typeScale, weight: .semibold))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(height: 16 * m.typeScale, alignment: .leading)
                if model.selectedApp != nil {
                    Button {
                        model.clearRankingSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            Text(l10n.t("ranking.clearFilter"))
                        }
                        .font(.system(size: 10 * m.typeScale, weight: .medium))
                        .foregroundStyle(EyesOnYouTheme.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.t("ranking.clearFilter.help"))
                }
                Spacer(minLength: 8)
                rankingSearchField(m)
                rankingColumnsButton(m)
                archiveToggleButton(m)
            }

            // Adaptive header — same metrics as rows for strict column lock.
            let cols = makeRankingColumns(m, rows: rows, available: max(0, available - colInset * 2))
            rankingHeader(m, cols: cols)
                .padding(.horizontal, colInset)

            Divider().overlay(EyesOnYouTheme.hairline)

            if !model.sunburstPath.isEmpty {
                HStack {
                    Button {
                        model.sunburstGoBack()
                    } label: {
                        Label(l10n.t("sunburst.back"), systemImage: "chevron.left")
                            .font(.system(size: 11 * m.typeScale, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(EyesOnYouTheme.accentBlue)

                    if let title = model.drilledAppTitle {
                        Text("· \(title)")
                            .font(.system(size: 11 * m.typeScale, weight: .medium))
                            .foregroundStyle(EyesOnYouTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                    Text(drillSubtitle)
                        .font(.system(size: 10 * m.typeScale))
                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, colInset)
            }

            // Only this list scrolls — page chrome stays fixed.
            ScrollViewReader { scroller in
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
                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rankingRow(
                                m,
                                cols: cols,
                                index: index + 1,
                                row: row,
                                drilled: !model.sunburstPath.isEmpty
                            )
                            if index < rows.count - 1 {
                                Divider().overlay(Color.white.opacity(0.04))
                            }
                        }
                    }
                }
                .padding(.horizontal, colInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Hovering a pie segment brings its row into view, so the highlight
                // the chart just lit up is actually on screen.
                .onChange(of: model.pieHoverRowID) { hovered in
                    guard let hovered, rows.contains(where: { $0.id == hovered }) else { return }
                    withAnimation(.easeOut(duration: 0.22)) {
                        scroller.scrollTo(hovered, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func rankingColumnsButton(_ m: BentoMetrics) -> some View {
        Menu {
            rankingColumnsMenu(m)
        } label: {
            Image(systemName: model.hasHiddenRankingColumns ? "eye.slash" : "eye")
                .font(.system(size: 13 * m.typeScale, weight: .semibold))
                .foregroundStyle(
                    model.hasHiddenRankingColumns
                        ? EyesOnYouTheme.accentBlue
                        : EyesOnYouTheme.textSecondary
                )
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(model.hasHiddenRankingColumns ? 0.10 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    model.hasHiddenRankingColumns
                                        ? EyesOnYouTheme.accentBlue.opacity(0.55)
                                        : Color.white.opacity(0.12),
                                    lineWidth: 0.8
                                )
                        )
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(l10n.t("ranking.columns.help"))
    }

    @ViewBuilder
    private func rankingColumnsMenu(_ m: BentoMetrics) -> some View {
        ForEach(AppModel.RankingColumnID.allCases) { column in
            if isColumnAvailable(column, m: m) {
                Button {
                    model.toggleRankingColumnHidden(column)
                } label: {
                    HStack {
                        Text(l10n.t(column.titleKey))
                        if model.isRankingColumnVisible(column) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        if model.hasHiddenRankingColumns {
            Divider()
            Button {
                model.resetRankingColumns()
            } label: {
                Label(l10n.t("ranking.resetColumns"), systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func isColumnAvailable(_ column: AppModel.RankingColumnID, m: BentoMetrics) -> Bool {
        switch column {
        case .egress, .online:
            return m.showTagColumns
        case .down, .up, .trend, .lastSeen, .requests:
            return true
        }
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
                            ? EyesOnYouTheme.accentAmber
                            : EyesOnYouTheme.textSecondary
                    )
                    .frame(width: 28, height: 28)
                if !model.archivedRankingRows.isEmpty {
                    Text("\(min(99, model.archivedRankingRows.count))")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(EyesOnYouTheme.accentAmber))
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
                                ? EyesOnYouTheme.accentAmber.opacity(0.55)
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
                .foregroundStyle(EyesOnYouTheme.textSecondary)
            TextField(l10n.t("overview.rankingSearch"), text: $model.rankingFilterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11 * m.typeScale))
                .foregroundStyle(EyesOnYouTheme.textPrimary)
                .focused($rankingSearchFocused)
                .help(l10n.t("overview.rankingSearch.help"))
            if !model.rankingFilterQuery.isEmpty {
                Button {
                    model.rankingFilterQuery = ""
                    rankingSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11 * m.typeScale))
                        .foregroundStyle(EyesOnYouTheme.textSecondary)
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
                                ? EyesOnYouTheme.accentBlue.opacity(0.55)
                                : Color.white.opacity(0.12),
                            lineWidth: 0.8
                        )
                )
        }
    }

    /// Drag handle between metric columns and tag columns — adjusts tag/title spacing.
    private func rankingSpacingDragHandle(_ m: BentoMetrics) -> some View {
        let hitWidth: CGFloat = max(8, model.rankingColumnSpacing)
        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: hitWidth, height: 18)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(EyesOnYouTheme.hairline)
                .frame(width: 2, height: 14)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if spacingDragOrigin == nil {
                        spacingDragOrigin = model.rankingColumnSpacing
                    }
                    let origin = spacingDragOrigin ?? model.rankingColumnSpacing
                    let next = origin + Double(value.translation.width) / 5.0
                    model.rankingColumnSpacing = AppModel.clampRankingColumnSpacing(next)
                }
                .onEnded { _ in
                    spacingDragOrigin = nil
                }
        )
        .help(l10n.t("overview.colSpacing.dragHelp"))
        .accessibilityLabel(l10n.t("overview.colSpacing.help"))
        .accessibilityValue("\(Int(model.rankingColumnSpacing))")
    }

    private func rankingHeader(_ m: BentoMetrics, cols: RankingColumnMetrics) -> some View {
        HStack(spacing: cols.gap) {
            // `#` is the default order — clicking it drops any column sort.
            Text("#")
                .frame(width: cols.index, alignment: .leading)
                .foregroundStyle(
                    model.rankingSortKey == nil
                        ? EyesOnYouTheme.textSecondary
                        : EyesOnYouTheme.accentBlue
                )
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onTapGesture { model.clearRankingSort() }
                .help(l10n.t("ranking.sort.reset.help"))
            headerCell(
                l10n.t("overview.colApp"),
                width: cols.app,
                align: .leading,
                column: nil,
                sort: .name,
                m: m
            )
            if cols.down > 0 {
                headerCell(l10n.t("overview.colDown"), width: cols.down, align: .trailing, column: .down, sort: .down, m: m)
            }
            if cols.up > 0 {
                headerCell(l10n.t("overview.colUp"), width: cols.up, align: .trailing, column: .up, sort: .up, m: m)
            }
            if cols.trend > 0 {
                headerCell(l10n.t("overview.colTrend"), width: cols.trend, align: .leading, column: .trend, sort: .trend, m: m)
            }
            if cols.lastSeen > 0 {
                headerCell(l10n.t("overview.colLastSeen"), width: cols.lastSeen, align: .trailing, column: .lastSeen, sort: .lastSeen, m: m)
            }
            if cols.requests > 0 {
                headerCell(l10n.t("overview.colRequests"), width: cols.requests, align: .trailing, column: .requests, sort: .requests, m: m)
            }

            // Draggable divider between metrics and tag columns (egress / online).
            if cols.handle > 0 {
                rankingSpacingDragHandle(m)
                    .frame(width: cols.handle)
            }

            if cols.egress > 0 {
                headerCell(l10n.t("overview.colEgress"), width: cols.egress, align: .leading, column: .egress, sort: .egress, m: m)
            }
            if cols.online > 0 {
                headerCell(l10n.t("overview.colOnline"), width: cols.online, align: .leading, column: .online, sort: .online, m: m)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: m.rankingHeaderFont, weight: .medium))
        .foregroundStyle(EyesOnYouTheme.textSecondary)
        .contextMenu {
            rankingColumnsMenu(m)
        }
    }

    /// Header label. Clicking re-sorts by that column: natural direction, then
    /// reversed, then back to the default ranking order.
    private func headerCell(
        _ title: String,
        width: CGFloat,
        align: Alignment,
        column: AppModel.RankingColumnID?,
        sort: AppModel.RankingSortKey,
        m: BentoMetrics
    ) -> some View {
        let direction = model.rankingSortDirection(for: sort)
        let active = direction != nil
        return HStack(spacing: 2) {
            if align == .trailing { Spacer(minLength: 0) }
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
            Image(systemName: direction == true ? "chevron.up" : "chevron.down")
                .font(.system(size: max(6, m.rankingHeaderFont - 3), weight: .bold))
                .opacity(active ? 1 : 0)
            if align != .trailing { Spacer(minLength: 0) }
        }
        .foregroundStyle(active ? EyesOnYouTheme.accentBlue : EyesOnYouTheme.textSecondary)
        .frame(width: width, alignment: align)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture {
            model.cycleRankingSort(sort)
        }
        .contextMenu {
            if let column {
                Button {
                    model.setRankingColumnHidden(column, hidden: true)
                } label: {
                    Label(l10n.t("ranking.hideColumn"), systemImage: "eye.slash")
                }
                Divider()
            }
            if model.rankingSortKey != nil {
                Button {
                    model.clearRankingSort()
                } label: {
                    Label(l10n.t("ranking.sort.reset"), systemImage: "arrow.up.arrow.down")
                }
                Divider()
            }
            rankingColumnsMenu(m)
        }
        .help(l10n.t("ranking.sort.help"))
    }

    /// Single-line numeric / label cell sized to the shared column width.
    private func adaptiveCell(
        _ text: String,
        width: CGFloat,
        align: Alignment = .trailing,
        color: Color = EyesOnYouTheme.textPrimary,
        minScale: CGFloat = 0.5
    ) -> some View {
        Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(minScale)
            .allowsTightening(true)
            .truncationMode(.tail)
            .monospacedDigit()
            .frame(width: width, alignment: align)
    }

    /// Measured egress, rendered as text: `Direct`, `Proxy`, `Proxy 62%`, or an em
    /// dash when the app moved no bytes in range. Never a rule — always what happened.
    static func egressLabel(_ egress: AppModel.ObservedEgress, l10n: LocalizationStore) -> String {
        switch egress {
        case .noTraffic:
            return "—"
        case .direct:
            return l10n.t("overview.routeDirect")
        case .proxy:
            return l10n.t("overview.egressProxy")
        case .mixed(let share):
            return "\(l10n.t("overview.egressProxy")) \(Int((share * 100).rounded()))%"
        }
    }

    /// Widest egress label the column has to fit, so the width never jitters per tick.
    static func egressWidthSamples(_ l10n: LocalizationStore) -> [String] {
        [
            l10n.t("overview.routeDirect"),
            "\(l10n.t("overview.egressProxy")) 100%"
        ]
    }

    /// Content-hugging column widths from visible rows; app/service names are capped.
    private func makeRankingColumns(
        _ m: BentoMetrics,
        rows: [AppModel.AppRankingRow],
        available: CGFloat
    ) -> RankingColumnMetrics {
        RankingColumnMetrics(
            m: m,
            spacing: model.rankingColumnSpacing,
            available: available,
            rows: rows,
            showDown: model.isRankingColumnVisible(.down),
            showUp: model.isRankingColumnVisible(.up),
            showTrend: model.isRankingColumnVisible(.trend),
            showLastSeen: model.isRankingColumnVisible(.lastSeen),
            showRequests: model.isRankingColumnVisible(.requests),
            showEgress: m.showTagColumns && model.isRankingColumnVisible(.egress),
            showOnline: m.showTagColumns && model.isRankingColumnVisible(.online),
            headerFont: m.rankingHeaderFont,
            bodyFont: m.rankingRowFont,
            appHeader: l10n.t("overview.colApp"),
            downHeader: l10n.t("overview.colDown"),
            upHeader: l10n.t("overview.colUp"),
            trendHeader: l10n.t("overview.colTrend"),
            lastSeenHeader: l10n.t("overview.colLastSeen"),
            requestsHeader: l10n.t("overview.colRequests"),
            egressHeader: l10n.t("overview.colEgress"),
            onlineHeader: l10n.t("overview.colOnline"),
            egressSamples: Self.egressWidthSamples(l10n),
            onlineSamples: [l10n.t("overview.onlineActive"), l10n.t("overview.onlineIdle")],
            lastSeenLabel: { date in l10n.relativeTrafficTime(date) }
        )
    }

    private var drillSubtitle: String {
        guard let id = model.sunburstPath.first,
              let row = model.rankingRows.first(where: { $0.id == id }) else {
            return ""
        }
        let key = DrillableIdentity.childLabelKey(for: row.snapshot.app)
        return l10n.t(key)
    }

    private func rankingRow(
        _ m: BentoMetrics,
        cols: RankingColumnMetrics,
        index: Int,
        row: AppModel.AppRankingRow,
        drilled: Bool
    ) -> some View {
        let app = row.snapshot
        let hoverID = drilled ? "\(app.app.storageKey)|\(app.displayName)" : row.id
        let isSelected = !drilled && model.selectedApp == app.app
        let highlighted = isSelected
            || isRowHighlighted(row.id) || isRowHighlighted(hoverID)
            || (drilled && model.hoverNodeID?.hasSuffix("|" + destinationKeyHint(row)) == true)
            || (drilled && model.hoverNodeID?.contains("|" + row.snapshot.displayName.lowercased()) == true)
        let dimmed = model.hoverNodeID != nil && !highlighted && !isDrilledChildHighlighted(row) && !isSelected
        let iconSize: CGFloat = 16 * m.typeScale
        let badgeFont = max(9, m.rankingRowFont * 0.95)
        let favSlot: CGFloat = 14 * m.typeScale

        return HStack(spacing: cols.gap) {
            Text("\(index)")
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
                .frame(width: cols.index, alignment: .leading)

            HStack(spacing: 5) {
                if !drilled {
                    FavoriteButton(app: app.app, size: 10 * m.typeScale)
                        .frame(width: favSlot, alignment: .center)
                } else {
                    Image(systemName: drillIcon(for: app.app))
                        .font(.system(size: 10 * m.typeScale))
                        .foregroundStyle(EyesOnYouTheme.accentPurple)
                        .frame(width: favSlot, alignment: .center)
                }
                AppIconView(app: app.app, displayName: app.displayName, size: iconSize)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(app.displayName)
                            .foregroundStyle(EyesOnYouTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !drilled, model.isFavorite(app.app) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8 * m.typeScale))
                                .foregroundStyle(EyesOnYouTheme.gold)
                        }
                    }
                    if !drilled && !app.sites.isEmpty {
                        Text(childCountLabel(app))
                            .font(.system(size: 9 * m.typeScale))
                            .foregroundStyle(EyesOnYouTheme.accentBlue)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: cols.appNameMax, alignment: .leading)
            }
            .frame(width: cols.app, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if drilled { return }
                if !app.sites.isEmpty {
                    model.drillInto(nodeID: row.id)
                } else {
                    model.selectRankingApp(app.app)
                }
            }

            if cols.down > 0 {
                adaptiveCell(ByteFormat.string(for: app.totals.bytesDown), width: cols.down)
            }
            if cols.up > 0 {
                adaptiveCell(ByteFormat.string(for: app.totals.bytesUp), width: cols.up)
            }
            if cols.trend > 0 {
                RankingMiniAreaChart(
                    values: row.rateSeries,
                    scaleMax: cols.trafficTrendScaleMax,
                    tint: rankingTrendTint(for: row)
                )
                .frame(width: cols.trend, height: max(16, 20 * m.typeScale))
            }
            if cols.lastSeen > 0 {
                adaptiveCell(
                    l10n.relativeTrafficTime(row.lastTrafficAt),
                    width: cols.lastSeen,
                    align: .trailing,
                    color: EyesOnYouTheme.textSecondary,
                    minScale: 0.45
                )
            }

            if cols.requests > 0 {
                adaptiveCell("\(app.totals.flowsOpened)", width: cols.requests)
            }

            // Match header drag-handle width so tag columns stay aligned.
            if cols.handle > 0 {
                Color.clear
                    .frame(width: cols.handle, height: 1)
            }

            if cols.egress > 0 {
                egressCell(row: row, width: cols.egress, fontSize: badgeFont)
            }
            if cols.online > 0 {
                onlineCell(row: row, width: cols.online, fontSize: badgeFont)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: m.rankingRowFont))
        .foregroundStyle(EyesOnYouTheme.textPrimary)
        .padding(.vertical, 6 * m.typeScale)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EyesOnYouTheme.brandGreen.opacity(isSelected ? 0.16 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                EyesOnYouTheme.brandGreen.opacity(isSelected ? 0.45 : 0.28),
                                lineWidth: isSelected ? 1.1 : 0.8
                            )
                    )
            }
        }
        .opacity(dimmed ? 0.38 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                // Highlight the matching pie segment now; only swap the pie into this
                // app's destinations once the pointer actually rests here.
                model.setHoverNode(row.id)
                if !drilled {
                    model.scheduleRankingHoverFilter(row.id)
                }
            } else {
                if model.hoverNodeID == row.id {
                    model.setHoverNode(nil)
                }
                model.clearRankingHoverFilter(ifMatching: row.id)
            }
        }
        .contextMenu {
            if !drilled {
                rankingContextMenu(for: app.app, displayName: app.displayName, hasSites: !app.sites.isEmpty, rowID: row.id)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.hoverNodeID)
        .animation(.easeOut(duration: 0.15), value: model.rankingHoverFilterID)
        .animation(.easeOut(duration: 0.15), value: model.selectedApp)
    }

    @ViewBuilder
    private func rankingContextMenu(
        for app: AppIdentityKey,
        displayName: String,
        hasSites: Bool,
        rowID: String
    ) -> some View {
        let isFiltered = model.selectedApp == app
        let isFavorite = model.isFavorite(app)
        let isArchived = model.isArchived(app)

        Button {
            model.selectRankingApp(app)
        } label: {
            Label(
                isFiltered ? l10n.t("ranking.clearFilter") : l10n.t("ranking.filterCards"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .help(l10n.t(isFiltered ? "ranking.clearFilter.help" : "ranking.filterCards.help"))

        if hasSites {
            Button {
                model.drillInto(nodeID: rowID)
            } label: {
                Label(l10n.t("ranking.drill"), systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .help(l10n.t("ranking.drill.help"))
        }

        Divider()

        Button {
            model.toggleFavorite(app)
        } label: {
            Label(
                isFavorite ? l10n.t("favorite.unpin") : l10n.t("favorite.pin"),
                systemImage: isFavorite ? "star.slash" : "star"
            )
        }
        .help(l10n.t(isFavorite ? "favorite.unpin.help" : "favorite.pin.help"))

        Button {
            model.toggleArchive(app)
        } label: {
            Label(
                isArchived ? l10n.t("ranking.unarchive") : l10n.t("ranking.archive"),
                systemImage: isArchived ? "tray.and.arrow.up" : "archivebox"
            )
        }
        .help(l10n.t(isArchived ? "ranking.unarchive.help" : "ranking.archive.actionHelp"))

        Divider()

        Button {
            model.revealInFinder(app)
        } label: {
            Label(l10n.t("ranking.revealFinder"), systemImage: "folder")
        }
        .help(l10n.t("ranking.revealFinder.help"))

        Button(role: .destructive) {
            model.deleteAppFromRanking(app)
        } label: {
            Label(l10n.t("ranking.delete"), systemImage: "trash")
        }
        .help(l10n.t("ranking.delete.help"))
    }

    /// Measured egress. Read-only on purpose: the table states what traffic did,
    /// it does not offer to change it.
    private func egressCell(
        row: AppModel.AppRankingRow,
        width: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        let egress = row.observedEgress
        let tint: Color
        switch egress {
        case .noTraffic: tint = EyesOnYouTheme.textSecondary
        case .direct: tint = EyesOnYouTheme.routeDirect
        case .proxy, .mixed: tint = EyesOnYouTheme.routeProxy
        }
        return Text(Self.egressLabel(egress, l10n: l10n))
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(egress == .noTraffic ? 0 : 0.10))
            }
            .frame(width: width, alignment: .leading)
            .help(l10n.t("ranking.egress.help"))
    }

    /// Live connection state — whether the app is holding sockets right now.
    private func onlineCell(
        row: AppModel.AppRankingRow,
        width: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        let state = row.onlineState
        let tint: Color
        let title: String
        switch state {
        case .active:
            tint = EyesOnYouTheme.accentGreen
            title = l10n.t("overview.onlineActive")
        case .idle:
            tint = EyesOnYouTheme.textSecondary
            title = l10n.t("overview.onlineIdle")
        case .noTraffic:
            tint = EyesOnYouTheme.textSecondary
            title = "—"
        }
        return HStack(spacing: 4) {
            if state != .noTraffic {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .layoutPriority(1)
            }
            Text(title)
                .font(.system(size: fontSize, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(width: width, alignment: .leading)
        .help(l10n.t("ranking.online.help"))
    }

    private func isRowHighlighted(_ rowID: String) -> Bool {
        guard let hover = model.hoverNodeID else { return false }
        if hover == rowID { return true }
        if hover.hasPrefix(rowID + "|") { return true }
        return false
    }

    /// Tint the sparkline by the path the bytes actually took, so it agrees with the
    /// egress column instead of with a rule nobody set.
    private func rankingTrendTint(for row: AppModel.AppRankingRow) -> Color {
        switch row.observedEgress {
        case .proxy, .mixed:
            return EyesOnYouTheme.routeProxy
        case .direct:
            return EyesOnYouTheme.routeDirect
        case .noTraffic:
            return EyesOnYouTheme.textSecondary
        }
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

/// Shared ranking column widths — content-hugging from visible rows; app/service names capped.
private struct RankingColumnMetrics {
    let gap: CGFloat
    let index: CGFloat
    let app: CGFloat
    let appNameMax: CGFloat
    let down: CGFloat
    let up: CGFloat
    let trend: CGFloat
    let lastSeen: CGFloat
    let requests: CGFloat
    let handle: CGFloat
    let egress: CGFloat
    let online: CGFloat
    /// Shared Y-max so cumulative sparklines compare across apps.
    let trafficTrendScaleMax: Double

    init(
        m: BentoMetrics,
        spacing: Double,
        available: CGFloat,
        rows: [AppModel.AppRankingRow],
        showDown: Bool,
        showUp: Bool,
        showTrend: Bool,
        showLastSeen: Bool,
        showRequests: Bool,
        showEgress: Bool,
        showOnline: Bool,
        headerFont: CGFloat,
        bodyFont: CGFloat,
        appHeader: String,
        downHeader: String,
        upHeader: String,
        trendHeader: String,
        lastSeenHeader: String,
        requestsHeader: String,
        egressHeader: String,
        onlineHeader: String,
        egressSamples: [String],
        onlineSamples: [String],
        lastSeenLabel: (Date?) -> String
    ) {
        let s = m.typeScale
        var gapW = CGFloat(spacing)
        let showTags = showEgress || showOnline
        let handleW: CGFloat = showTags ? max(8, gapW) : 0
        // Sparkline keeps a compact minimum visual width (at least header label).
        var trendW = showTrend
            ? max(
                40,
                ceil(48 * s),
                RankingTextMeasure.width(trendHeader, size: headerFont, weight: .medium)
                    + Self.sortIndicator
            )
            : 0
        trafficTrendScaleMax = max(rows.compactMap { $0.rateSeries.max() }.max() ?? 0, 1)

        let indexW = max(
            RankingTextMeasure.width("#", size: headerFont, weight: .medium),
            RankingTextMeasure.width("99", size: bodyFont),
            16
        )

        // App / service display names: hug content up to a cap that grows with slack.
        var appNameCap = ceil(160 * s)
        let favSlot = ceil(14 * s)
        let icon = ceil(16 * s)
        let appChrome = favSlot + 5 + icon + 5
        let longestName = rows.map(\.snapshot.displayName).max(by: {
            RankingTextMeasure.width($0, size: bodyFont) < RankingTextMeasure.width($1, size: bodyFont)
        }) ?? ""
        let nameW = min(appNameCap, RankingTextMeasure.width(longestName, size: bodyFont))
        let headerAppW = RankingTextMeasure.width(appHeader, size: headerFont, weight: .medium)
            + Self.sortIndicator
        var appW = max(appChrome + nameW, headerAppW, 72)

        let downW = showDown
            ? Self.hug(
                header: downHeader,
                samples: rows.map { ByteFormat.string(for: $0.snapshot.totals.bytesDown) },
                headerFont: headerFont,
                bodyFont: bodyFont
            )
            : 0
        let upW = showUp
            ? Self.hug(
                header: upHeader,
                samples: rows.map { ByteFormat.string(for: $0.snapshot.totals.bytesUp) },
                headerFont: headerFont,
                bodyFont: bodyFont
            )
            : 0

        let lastSeenW = showLastSeen
            ? Self.hug(
                header: lastSeenHeader,
                samples: rows.map { lastSeenLabel($0.lastTrafficAt) },
                headerFont: headerFont,
                bodyFont: bodyFont
            )
            : 0
        let requestsW = showRequests
            ? Self.hug(
                header: requestsHeader,
                samples: rows.map { "\($0.snapshot.totals.flowsOpened)" },
                headerFont: headerFont,
                bodyFont: bodyFont
            )
            : 0

        // Widths come from the widest possible label, not the current rows, so the
        // column does not resize every tick as apps switch path or go idle.
        let egressW = showEgress
            ? Self.hug(
                header: egressHeader,
                samples: egressSamples,
                headerFont: headerFont,
                bodyFont: bodyFont,
                extra: 12 // capsule padding
            )
            : 0
        let onlineW = showOnline
            ? Self.hug(
                header: onlineHeader,
                samples: onlineSamples,
                headerFont: headerFont,
                bodyFont: bodyFont,
                extra: 18 // status dot + padding
            )
            : 0

        // Spread whatever the card has left over instead of parking it all on the
        // right edge: longer names first, then a wider sparkline, then even gaps.
        let widths = [indexW, appW, downW, upW, trendW, lastSeenW, requestsW, handleW, egressW, onlineW]
        let occupied = widths.filter { $0 > 0 }
        // One gap per column: the inter-column gaps plus the row's trailing spacer.
        let gapUnits = CGFloat(occupied.count)
        let natural = occupied.reduce(0, +) + gapW * gapUnits
        var slack = max(0, available - natural - 2)
        if slack > 1 {
            let nameGrowth = min(slack * 0.42, 150)
            appW += nameGrowth
            appNameCap += nameGrowth
            slack -= nameGrowth

            if trendW > 0 {
                let trendGrowth = min(slack * 0.5, 140)
                trendW += trendGrowth
                slack -= trendGrowth
            }

            if gapUnits > 0 {
                // Cap per-gap growth so columns stay grouped rather than scattered.
                let perGap = min(slack / gapUnits, 22)
                gapW += perGap
                slack -= perGap * gapUnits
            }

            // Anything still unclaimed goes to the name column, which can always use it.
            appW += slack
            appNameCap += slack
        }

        gap = gapW
        index = indexW
        app = appW
        appNameMax = appNameCap
        down = downW
        up = upW
        trend = trendW
        lastSeen = lastSeenW
        requests = requestsW
        handle = handleW
        egress = egressW
        online = onlineW
    }

    /// Room reserved next to every sortable header label for its direction chevron.
    private static let sortIndicator: CGFloat = 11

    private static func hug(
        header: String,
        samples: [String],
        headerFont: CGFloat,
        bodyFont: CGFloat,
        extra: CGFloat = 0
    ) -> CGFloat {
        let hw = RankingTextMeasure.width(header, size: headerFont, weight: .medium) + sortIndicator
        let sw = samples.map { RankingTextMeasure.width($0, size: bodyFont) }.max() ?? 0
        return ceil(max(hw, sw) + extra + 2)
    }
}

private enum RankingTextMeasure {
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let bounds = (text as NSString).size(withAttributes: [.font: font])
        return ceil(bounds.width)
    }
}

/// Compact single-series area chart for ranking rows.
private struct RankingMiniAreaChart: View {
    let values: [Double]
    var scaleMax: Double = 1
    var tint: Color = EyesOnYouTheme.chartDown

    var body: some View {
        let series: [Double] = {
            if values.count >= 2 { return values }
            if let only = values.first { return [only, only] }
            return [0, 0]
        }()
        MiniAreaChartView(values: series, scaleMax: scaleMax, tint: tint)
            .opacity((series.max() ?? 0) > 0 ? 1 : 0.28)
            .accessibilityHidden(true)
    }
}

// MARK: - Area chart (live traffic)

/// Single-series mini area chart for totals card trend rows.
struct MiniAreaChartView: View {
    let values: [Double]
    /// When > 0, use a shared Y scale (ranking rows); otherwise auto-scale to series max.
    var scaleMax: Double = 0
    var tint: Color = EyesOnYouTheme.chartDown
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let localMax = values.max() ?? 1
            let maxV = max(scaleMax > 0 ? scaleMax : localMax, 1)
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

/// Stacked area chart for proxy routing mix: direct / system / custom shares over time.
struct RouteMixAreaChartView: View {
    let direct: [Double]
    let system: [Double]
    let custom: [Double]
    var lineWidth: CGFloat = 1.5
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let count = max(2, max(direct.count, max(system.count, custom.count)))
            let customP = padded(custom, count: count)
            let systemP = padded(system, count: count)
            let directP = padded(direct, count: count)
            let customEdge = customP
            let systemEdge = zipSum(customP, systemP)
            let directEdge = zipSum(systemEdge, directP)
            let isLight = colorScheme == .light

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let y = h * CGFloat(i + 1) / 4
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(EyesOnYouTheme.hairline.opacity(0.7), lineWidth: 0.5)
                }

                stackedBand(lower: Array(repeating: 0.0, count: count), upper: customEdge, width: w, height: h)
                    .fill(
                        LinearGradient(
                            colors: [
                                EyesOnYouTheme.routeProxy.opacity(isLight ? 0.32 : 0.42),
                                EyesOnYouTheme.routeProxy.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                stackedBand(lower: customEdge, upper: systemEdge, width: w, height: h)
                    .fill(
                        LinearGradient(
                            colors: [
                                EyesOnYouTheme.routeSystem.opacity(isLight ? 0.30 : 0.40),
                                EyesOnYouTheme.routeSystem.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                stackedBand(lower: systemEdge, upper: directEdge, width: w, height: h)
                    .fill(
                        LinearGradient(
                            colors: [
                                EyesOnYouTheme.routeDirect.opacity(isLight ? 0.28 : 0.38),
                                EyesOnYouTheme.routeDirect.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                linePath(values: directEdge, width: w, height: h)
                    .stroke(
                        EyesOnYouTheme.routeDirect.opacity(isLight ? 0.65 : 0.85),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                linePath(values: systemEdge, width: w, height: h)
                    .stroke(
                        EyesOnYouTheme.routeSystem.opacity(isLight ? 0.7 : 0.9),
                        style: StrokeStyle(lineWidth: lineWidth * 0.85, lineCap: .round, lineJoin: .round)
                    )
                linePath(values: customEdge, width: w, height: h)
                    .stroke(
                        EyesOnYouTheme.routeProxy.opacity(isLight ? 0.7 : 0.9),
                        style: StrokeStyle(lineWidth: lineWidth * 0.85, lineCap: .round, lineJoin: .round)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func padded(_ values: [Double], count: Int) -> [Double] {
        let n = max(count, 2)
        if values.isEmpty { return Array(repeating: 0, count: n) }
        if values.count == 1 { return Array(repeating: values[0], count: n) }
        if values.count >= n { return Array(values.suffix(n)) }
        var out = values
        while out.count < n { out.insert(out[0], at: 0) }
        return out
    }

    private func zipSum(_ a: [Double], _ b: [Double]) -> [Double] {
        let n = max(a.count, b.count)
        let aa = padded(a, count: n)
        let bb = padded(b, count: n)
        return zip(aa, bb).map { min(100, $0 + $1) }
    }

    private func yPosition(_ value: Double, height: CGFloat) -> CGFloat {
        let clamped = min(100, max(0, value))
        return height - (height * CGFloat(clamped / 100.0)) * 0.92
    }

    private func linePath(values: [Double], width: CGFloat, height: CGFloat) -> Path {
        guard values.count > 1 else { return Path() }
        var p = Path()
        for (i, v) in values.enumerated() {
            let x = width * CGFloat(i) / CGFloat(values.count - 1)
            let y = yPosition(v, height: height)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }

    private func stackedBand(lower: [Double], upper: [Double], width: CGFloat, height: CGFloat) -> Path {
        let n = max(lower.count, upper.count)
        let lo = padded(lower, count: n)
        let hi = padded(upper, count: n)
        guard n > 1 else { return Path() }
        var p = Path()
        for (i, v) in hi.enumerated() {
            let x = width * CGFloat(i) / CGFloat(n - 1)
            let y = yPosition(v, height: height)
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            let x = width * CGFloat(i) / CGFloat(n - 1)
            let y = yPosition(lo[i], height: height)
            p.addLine(to: CGPoint(x: x, y: y))
        }
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
            let downFillTop = EyesOnYouTheme.chartDown.opacity(isLight ? 0.28 : 0.38)
            let downFillBot = EyesOnYouTheme.chartDown.opacity(isLight ? 0.04 : 0.05)
            let upStroke = EyesOnYouTheme.chartUp

            ZStack {
                // Soft horizontal guides
                ForEach(0..<3, id: \.self) { i in
                    let y = h * CGFloat(i + 1) / 4
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(EyesOnYouTheme.hairline.opacity(0.7), lineWidth: 0.5)
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
                        EyesOnYouTheme.chartDown.opacity(isLight ? 0.55 : 0.75),
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
