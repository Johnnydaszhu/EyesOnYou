import SwiftUI
import FlowLensCore
import FlowLensRuleEngine

/// Adaptive bento Overview — sizes derived from container via `BentoMetrics`.
/// Page itself does not scroll; only the ranking card list scrolls.
struct OverviewTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @FocusState private var rankingSearchFocused: Bool
    @State private var isGroupManagerPresented = false
    @State private var spacingDragOrigin: Double? = nil

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
            // Shared 3-column grid — col1 width locks totals ↔ pie gutter.
            // Trailing cells expand so right edges stay flush.
            let col1 = m.columnWidth(in: w, columns: 3)
            let metricsH = m.metricsRowHeight

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    totalsCard(m)
                        .frame(width: col1, height: metricsH)
                    liveTrafficCard(m)
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
            // Shared 2-column grid — pie under totals, ranking under live.
            let col1 = m.columnWidth(in: w, columns: 2)
            let metricsH = m.metricsRowHeight
            let proxyH = metricsH * 0.85
            let metricsBlock = metricsH + gap + proxyH

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    totalsCard(m)
                        .frame(width: col1, height: metricsH)
                    liveTrafficCard(m)
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
            // compact / tiny — single column stack
            VStack(spacing: gap) {
                totalsCard(m)
                    .frame(maxWidth: .infinity)
                    .frame(height: m.metricsRowHeight * 0.72)
                liveTrafficCard(m)
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
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16 * scale, alignment: .leading)

            body()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
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

            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Icon + label/value on the left (intrinsic), mini area chart fills remaining width.
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
        let chartH: CGFloat = (compact ? 26 : 34) * m.typeScale
        return HStack(alignment: .center, spacing: 10) {
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
                    .monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)

            MiniAreaChartView(values: trend, tint: tint)
                .frame(minWidth: 72, maxWidth: .infinity)
                .frame(height: chartH)
                .layoutPriority(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let metaH = 36 * m.typeScale
        let footerH = 18 * m.typeScale
        return bentoCard(title: liveTrafficCardTitle, systemImage: "waveform.path", scale: m.typeScale) {
            VStack(spacing: 8 * m.typeScale) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: metaH, alignment: .center)

                AreaChartView(down: model.sparklineDown, up: model.sparklineUp)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Spacer matching proxy card footer so chart bottoms align.
                Color.clear
                    .frame(height: footerH)
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
        let metaH = 36 * m.typeScale
        let footerH = 18 * m.typeScale
        return bentoCard(title: proxyRoutingCardTitle, systemImage: "arrow.triangle.branch", scale: m.typeScale) {
            VStack(spacing: 8 * m.typeScale) {
                HStack(spacing: 12) {
                    routeLegendChip(
                        m,
                        tint: FlowLensTheme.accentGreen,
                        title: l10n.t("overview.routeDirect"),
                        percent: model.routeMix.directPercent
                    )
                    routeLegendChip(
                        m,
                        tint: FlowLensTheme.accentAmber,
                        title: l10n.t("overview.routeSystemProxy"),
                        percent: model.routeMix.systemProxyPercent
                    )
                    routeLegendChip(
                        m,
                        tint: FlowLensTheme.accentPurple,
                        title: l10n.t("overview.routeCustomProxy"),
                        percent: model.routeMix.customProxyPercent
                    )
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: metaH, alignment: .center)

                RouteMixAreaChartView(
                    direct: model.sparklineRouteDirect,
                    system: model.sparklineRouteSystem,
                    custom: model.sparklineRouteCustom
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack(spacing: 6) {
                    Text(l10n.t("overview.activeRules"))
                        .font(.system(size: 11 * m.typeScale))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(model.routeMix.activeRules)")
                        .font(.system(size: 13 * m.typeScale, weight: .bold, design: .rounded))
                        .foregroundStyle(FlowLensTheme.textPrimary)
                        .monospacedDigit()
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
                    .foregroundStyle(FlowLensTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 9 * m.typeScale))
                    .foregroundStyle(FlowLensTheme.textSecondary)
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
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16 * m.typeScale, alignment: .leading)

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
                .foregroundStyle(FlowLensTheme.textSecondary)
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
                        .foregroundStyle(FlowLensTheme.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.t("ranking.clearFilter.help"))
                }
                Spacer(minLength: 8)
                rankingSearchField(m)
                groupsManageButton(m)
                archiveToggleButton(m)
            }

            // Adaptive header — same horizontal inset as rows for strict column lock.
            rankingHeader(m)
                .padding(.horizontal, colInset)

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
                .padding(.horizontal, colInset)
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
                .padding(.horizontal, colInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flowCard()
        .sheet(isPresented: $isGroupManagerPresented) {
            GroupManagerSheet()
                .environmentObject(model)
                .environmentObject(l10n)
        }
    }

    private func groupsManageButton(_ m: BentoMetrics) -> some View {
        Button {
            isGroupManagerPresented = true
        } label: {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 13 * m.typeScale, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                        )
                }
        }
        .buttonStyle(.plain)
        .help(l10n.t("groups.manage.help"))
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

    /// Drag handle between metric columns and tag columns — adjusts tag/title spacing.
    private func rankingSpacingDragHandle(_ m: BentoMetrics) -> some View {
        let hitWidth: CGFloat = max(8, model.rankingColumnSpacing)
        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: hitWidth, height: 18)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(FlowLensTheme.hairline)
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

    private func rankingHeader(_ m: BentoMetrics) -> some View {
        let gap = CGFloat(model.rankingColumnSpacing)
        return HStack(spacing: gap) {
            Text("#").frame(width: Self.rankingIndexWidth, alignment: .leading)
            Text(l10n.t("overview.colApp")).frame(minWidth: 72, maxWidth: .infinity, alignment: .leading)
            headerCell(l10n.t("overview.colDown"), width: colW(m, base: 56), align: .trailing)
            headerCell(l10n.t("overview.colUp"), width: colW(m, base: 56), align: .trailing)
            if m.showDiskColumns {
                headerCell(l10n.t("overview.colDiskRead"), width: colW(m, base: 56), align: .trailing)
                headerCell(l10n.t("overview.colDiskWrite"), width: colW(m, base: 56), align: .trailing)
            }
            headerCell(l10n.t("overview.colRequests"), width: colW(m, base: 44), align: .trailing)

            // Draggable divider between metrics and tag columns (route / status / group).
            rankingSpacingDragHandle(m)

            if m.showRouteStatusColumns {
                headerCell(l10n.t("overview.colRoute"), width: colW(m, base: 64), align: .leading)
                headerCell(l10n.t("overview.colStatus"), width: colW(m, base: 56), align: .leading)
            }
            if m.showGroupProxyColumns {
                headerCell(l10n.t("overview.colGroup"), width: colW(m, base: 72), align: .leading)
                headerCell(l10n.t("overview.colProxy"), width: colW(m, base: 40), align: .center)
            }
        }
        .font(.system(size: m.rankingHeaderFont, weight: .medium))
        .foregroundStyle(FlowLensTheme.textSecondary)
    }

    private static let rankingIndexWidth: CGFloat = 22

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
            .monospacedDigit()
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
        let groupW = colW(m, base: 72)
        let proxyW = colW(m, base: 40)
        let badgeFont = max(9, m.rankingRowFont * 0.95)
        let gap = CGFloat(model.rankingColumnSpacing)

        let favSlot: CGFloat = 14 * m.typeScale

        return HStack(spacing: gap) {
            Text("\(index)")
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
                .frame(width: Self.rankingIndexWidth, alignment: .leading)

            HStack(spacing: 5) {
                if !drilled {
                    FavoriteButton(app: app.app, size: 10 * m.typeScale)
                        .frame(width: favSlot, alignment: .center)
                } else {
                    Image(systemName: drillIcon(for: app.app))
                        .font(.system(size: 10 * m.typeScale))
                        .foregroundStyle(FlowLensTheme.accentPurple)
                        .frame(width: favSlot, alignment: .center)
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

            // Match header drag-handle width so tag columns stay aligned.
            Color.clear
                .frame(width: max(8, model.rankingColumnSpacing), height: 1)

            if m.showRouteStatusColumns {
                RouteBadge(
                    label: app.route.chipLabel,
                    fontSize: badgeFont,
                    horizontalPadding: 6,
                    verticalPadding: 2,
                    minScale: 0.5
                )
                .frame(width: routeW, alignment: .leading)
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
                rankingGroupPicker(m, app: app.app, width: groupW)

                Toggle("", isOn: Binding(
                    get: { ProxyToggleLogic.isProxyEnabled(app.route) },
                    set: { _ in model.toggleAppProxy(app) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: proxyW, alignment: .center)
            }
        }
        .font(.system(size: m.rankingRowFont))
        .foregroundStyle(FlowLensTheme.textPrimary)
        .padding(.vertical, 6 * m.typeScale)
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
        .onTapGesture {
            if drilled { return }
            if !app.sites.isEmpty {
                model.drillInto(nodeID: row.id)
            } else {
                model.selectRankingApp(app.app)
            }
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

        Menu {
            groupAssignmentMenu(for: app)
        } label: {
            Label(l10n.t("groups.assign"), systemImage: "folder")
        }

        Button {
            isGroupManagerPresented = true
        } label: {
            Label(l10n.t("groups.manage"), systemImage: "folder.badge.gearshape")
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

    @ViewBuilder
    private func groupAssignmentMenu(for app: AppIdentityKey) -> some View {
        let current = model.group(containing: app)
        Button {
            model.setAppGroup(app, groupID: nil)
        } label: {
            HStack {
                Text(l10n.t("overview.ungrouped"))
                if current == nil {
                    Image(systemName: "checkmark")
                }
            }
        }
        if !model.groups.isEmpty {
            Divider()
            ForEach(model.groups) { group in
                Button {
                    model.setAppGroup(app, groupID: group.id)
                } label: {
                    HStack {
                        Text(group.name)
                        if current?.id == group.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        Divider()
        Button {
            isGroupManagerPresented = true
        } label: {
            Label(l10n.t("groups.createNew"), systemImage: "plus")
        }
    }

    private func rankingGroupPicker(_ m: BentoMetrics, app: AppIdentityKey, width: CGFloat) -> some View {
        let current = model.group(containing: app)
        return Menu {
            groupAssignmentMenu(for: app)
        } label: {
            HStack(spacing: 3) {
                Text(current?.name ?? l10n.t("overview.ungrouped"))
                    .font(.system(size: m.rankingRowFont))
                    .foregroundStyle(
                        current == nil ? FlowLensTheme.textSecondary : FlowLensTheme.textPrimary
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .allowsTightening(true)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textSecondary)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(l10n.t("groups.assign.help"))
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
                    .stroke(FlowLensTheme.hairline.opacity(0.7), lineWidth: 0.5)
                }

                stackedBand(lower: Array(repeating: 0.0, count: count), upper: customEdge, width: w, height: h)
                    .fill(
                        LinearGradient(
                            colors: [
                                FlowLensTheme.accentPurple.opacity(isLight ? 0.32 : 0.42),
                                FlowLensTheme.accentPurple.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                stackedBand(lower: customEdge, upper: systemEdge, width: w, height: h)
                    .fill(
                        LinearGradient(
                            colors: [
                                FlowLensTheme.accentAmber.opacity(isLight ? 0.30 : 0.40),
                                FlowLensTheme.accentAmber.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                stackedBand(lower: systemEdge, upper: directEdge, width: w, height: h)
                    .fill(
                        LinearGradient(
                            colors: [
                                FlowLensTheme.accentGreen.opacity(isLight ? 0.28 : 0.38),
                                FlowLensTheme.accentGreen.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                linePath(values: directEdge, width: w, height: h)
                    .stroke(
                        FlowLensTheme.accentGreen.opacity(isLight ? 0.65 : 0.85),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                linePath(values: systemEdge, width: w, height: h)
                    .stroke(
                        FlowLensTheme.accentAmber.opacity(isLight ? 0.7 : 0.9),
                        style: StrokeStyle(lineWidth: lineWidth * 0.85, lineCap: .round, lineJoin: .round)
                    )
                linePath(values: customEdge, width: w, height: h)
                    .stroke(
                        FlowLensTheme.accentPurple.opacity(isLight ? 0.7 : 0.9),
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
