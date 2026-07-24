import SwiftUI
import FlowLensCore
import FlowLensRuleEngine

/// Adaptive bento Overview — sizes derived from container via `BentoMetrics`.
/// Page itself does not scroll; only the ranking card list scrolls.
struct OverviewTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    /// Local filter for the ranking table (independent of header global search).
    @State private var rankingQuery: String = ""
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
        bentoCard(title: l10n.t("overview.totals"), systemImage: "chart.bar.fill", scale: m.typeScale) {
            ViewThatFits(in: .vertical) {
                totalsBody(m, compact: false)
                totalsBody(m, compact: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8 * m.typeScale)
        }
    }

    private func totalsBody(_ m: BentoMetrics, compact: Bool) -> some View {
        let stackSpacing: CGFloat = compact ? 6 : 12
        return VStack(spacing: stackSpacing) {
            VStack(spacing: compact ? 4 : 8) {
                Text(l10n.t("overview.networkTraffic"))
                    .font(.system(size: 11 * m.typeScale, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.accentBlue)
                HStack(spacing: 8) {
                    metricCell(m, icon: "arrow.down.circle.fill", iconColor: FlowLensTheme.accentBlue,
                               title: l10n.t("overview.netDown"),
                               value: ByteFormat.string(for: model.periodNetworkDown), compact: compact)
                    metricCell(m, icon: "arrow.up.circle.fill", iconColor: FlowLensTheme.accentPurple,
                               title: l10n.t("overview.netUp"),
                               value: ByteFormat.string(for: model.periodNetworkUp), compact: compact)
                }
            }

            if !compact {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: compact ? 4 : 8) {
                Text(l10n.t("overview.diskIO"))
                    .font(.system(size: 11 * m.typeScale, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.accentAmber)
                HStack(spacing: 8) {
                    metricCell(m, icon: "internaldrive.fill", iconColor: FlowLensTheme.accentAmber,
                               title: l10n.t("overview.diskRead"),
                               value: ByteFormat.string(for: model.periodDiskRead), compact: compact)
                    metricCell(m, icon: "externaldrive.fill.badge.plus", iconColor: FlowLensTheme.gold,
                               title: l10n.t("overview.diskWrite"),
                               value: ByteFormat.string(for: model.periodDiskWrite), compact: compact)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func metricCell(
        _ m: BentoMetrics,
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        compact: Bool
    ) -> some View {
        VStack(spacing: compact ? 2 : 4) {
            Image(systemName: icon)
                .font(.system(size: (compact ? 13 : 16) * m.typeScale, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.system(size: 10 * m.typeScale))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: m.valueFontSize * (compact ? 0.9 : 1), weight: .semibold, design: .rounded))
                .foregroundStyle(FlowLensTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Live traffic (area chart)

    private func liveTrafficCard(_ m: BentoMetrics) -> some View {
        bentoCard(title: l10n.t("overview.liveTraffic"), systemImage: "waveform.path", scale: m.typeScale) {
            VStack(spacing: 8 * m.typeScale) {
                HStack(spacing: 12) {
                    rateBlock(
                        m,
                        icon: "arrow.down",
                        tint: FlowLensTheme.accentBlue,
                        title: l10n.t("overview.netDown"),
                        value: ByteFormat.rateMBps(bytesPerSecond: model.rateDownBps)
                    )
                    rateBlock(
                        m,
                        icon: "arrow.up",
                        tint: FlowLensTheme.accentPurple,
                        title: l10n.t("overview.netUp"),
                        value: ByteFormat.rateMBps(bytesPerSecond: model.rateUpBps)
                    )
                }

                AreaChartView(down: model.sparklineDown, up: model.sparklineUp)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: m.areaChartHeight * 0.7, idealHeight: m.areaChartHeight, maxHeight: m.areaChartHeight * 1.15)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8 * m.typeScale)
        }
    }

    private func rateBlock(_ m: BentoMetrics, icon: String, tint: Color, title: String, value: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11 * m.typeScale, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10 * m.typeScale))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value)
                .font(.system(size: 18 * m.typeScale, weight: .bold, design: .rounded))
                .foregroundStyle(FlowLensTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Proxy routing

    private func proxyRoutingCard(_ m: BentoMetrics) -> some View {
        bentoCard(title: l10n.t("overview.proxyRouting"), systemImage: "arrow.triangle.branch", scale: m.typeScale) {
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
                    Capsule().fill(Color.white.opacity(0.06))
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
        let rows = filteredRankingRows(model.visibleRankingRows)

        return VStack(alignment: .leading, spacing: 8 * m.typeScale) {
            HStack(spacing: 10) {
                Label(l10n.t("overview.ranking"), systemImage: "list.number")
                    .font(.system(size: 10 * m.typeScale, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                rankingSearchField(m)
            }

            // Adaptive header — columns collapse with width class
            rankingHeader(m)

            Divider().overlay(Color.white.opacity(0.06))

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
                            rankingQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? l10n.t("overview.pieEmpty")
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

    private func rankingSearchField(_ m: BentoMetrics) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11 * m.typeScale, weight: .medium))
                .foregroundStyle(FlowLensTheme.textSecondary)
            TextField(l10n.t("overview.rankingSearch"), text: $rankingQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11 * m.typeScale))
                .foregroundStyle(FlowLensTheme.textPrimary)
                .focused($rankingSearchFocused)
            if !rankingQuery.isEmpty {
                Button {
                    rankingQuery = ""
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
        .frame(minWidth: 140, idealWidth: 180, maxWidth: 220)
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

    private func filteredRankingRows(_ rows: [AppModel.AppRankingRow]) -> [AppModel.AppRankingRow] {
        let q = rankingQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            let snap = row.snapshot
            if snap.displayName.lowercased().contains(q) { return true }
            if snap.app.signingIdentifier.lowercased().contains(q) { return true }
            if let group = row.groupName, group.lowercased().contains(q) { return true }
            return false
        }
    }

    private func rankingHeader(_ m: BentoMetrics) -> some View {
        HStack(spacing: 4) {
            Text("#").frame(width: 18, alignment: .leading)
            Text(l10n.t("overview.colApp")).frame(minWidth: 72, maxWidth: .infinity, alignment: .leading)
            Text(l10n.t("overview.colDown")).frame(width: colW(m, base: 56), alignment: .trailing)
            Text(l10n.t("overview.colUp")).frame(width: colW(m, base: 56), alignment: .trailing)
            if m.showDiskColumns {
                Text(l10n.t("overview.colDiskRead")).frame(width: colW(m, base: 56), alignment: .trailing)
                Text(l10n.t("overview.colDiskWrite")).frame(width: colW(m, base: 56), alignment: .trailing)
            }
            Text(l10n.t("overview.colRequests")).frame(width: colW(m, base: 44), alignment: .trailing)
            if m.showRouteStatusColumns {
                Text(l10n.t("overview.colRoute")).frame(width: colW(m, base: 56))
                Text(l10n.t("overview.colStatus")).frame(width: colW(m, base: 48))
            }
            if m.showGroupProxyColumns {
                Text(l10n.t("overview.colGroup")).frame(width: colW(m, base: 48), alignment: .leading)
                Text(l10n.t("overview.colProxy")).frame(width: colW(m, base: 40))
            }
        }
        .font(.system(size: m.rankingHeaderFont, weight: .medium))
        .foregroundStyle(FlowLensTheme.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    private func colW(_ m: BentoMetrics, base: CGFloat) -> CGFloat {
        max(32, base * m.typeScale)
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
        let statusBlocked = app.firewallStatus == .block
        let hoverID = drilled ? "\(app.app.storageKey)|\(app.displayName)" : row.id
        let highlighted = isRowHighlighted(row.id) || isRowHighlighted(hoverID)
            || (drilled && model.hoverNodeID?.hasSuffix("|" + destinationKeyHint(row)) == true)
            || (drilled && model.hoverNodeID?.contains("|" + row.snapshot.displayName.lowercased()) == true)
        let dimmed = model.hoverNodeID != nil && !highlighted && !isDrilledChildHighlighted(row)
        let dw = colW(m, base: 56)
        let iconSize: CGFloat = 16 * m.typeScale

        return HStack(spacing: 4) {
            Text("\(index)")
                .foregroundStyle(FlowLensTheme.textSecondary)
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
                            .minimumScaleFactor(0.7)
                        if !drilled, model.isFavorite(app.app) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8 * m.typeScale))
                                .foregroundStyle(FlowLensTheme.gold)
                        }
                    }
                    if !drilled && !app.sites.isEmpty {
                        Text(childCountLabel(app))
                            .font(.system(size: 9 * m.typeScale))
                            .foregroundStyle(FlowLensTheme.accentBlue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)

            Text(ByteFormat.string(for: app.totals.bytesDown))
                .frame(width: dw, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(ByteFormat.string(for: app.totals.bytesUp))
                .frame(width: dw, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if m.showDiskColumns {
                Text(ByteFormat.string(for: row.diskRead))
                    .frame(width: dw, alignment: .trailing)
                    .foregroundStyle(FlowLensTheme.accentAmber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(ByteFormat.string(for: row.diskWrite))
                    .frame(width: dw, alignment: .trailing)
                    .foregroundStyle(FlowLensTheme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            Text("\(app.totals.flowsOpened)")
                .frame(width: colW(m, base: 44), alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            if m.showRouteStatusColumns {
                RouteBadge(label: app.route.chipLabel)
                    .frame(width: colW(m, base: 56))
                    .scaleEffect(min(1, m.typeScale))

                HStack(spacing: 3) {
                    Circle()
                        .fill(statusBlocked ? FlowLensTheme.accentRed : FlowLensTheme.accentGreen)
                        .frame(width: 6, height: 6)
                    Text(statusBlocked ? l10n.t("overview.blocked") : l10n.t("overview.allowed"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                .frame(width: colW(m, base: 48))
                .foregroundStyle(statusBlocked ? FlowLensTheme.accentRed : FlowLensTheme.accentGreen)
            }

            if m.showGroupProxyColumns {
                Text(row.groupName ?? l10n.t("overview.ungrouped"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(row.groupName == nil ? FlowLensTheme.textSecondary : FlowLensTheme.textPrimary)
                    .frame(width: colW(m, base: 48), alignment: .leading)

                Toggle("", isOn: Binding(
                    get: { ProxyToggleLogic.isProxyEnabled(app.route) },
                    set: { _ in model.toggleAppProxy(app) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: colW(m, base: 40))
            }
        }
        .font(.system(size: m.rankingRowFont))
        .foregroundStyle(FlowLensTheme.textPrimary)
        .padding(.vertical, 6 * m.typeScale)
        .padding(.horizontal, 2)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(FlowLensTheme.accentBlue.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7)
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
            if !drilled, !app.sites.isEmpty {
                model.drillInto(nodeID: row.id)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.hoverNodeID)
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

/// Dual-series area chart: download (blue) + upload (purple) with gradient fills.
struct AreaChartView: View {
    let down: [Double]
    let up: [Double]
    var lineWidth: CGFloat = 1.8

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let maxV = max(down.max() ?? 1, up.max() ?? 1, 1)

            ZStack {
                // Baseline grid
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w, y: h))
                }
                .stroke(Color.white.opacity(0.06), lineWidth: 1)

                // Download area + line
                filledArea(values: down, width: w, height: h, maxV: maxV)
                    .fill(
                        LinearGradient(
                            colors: [
                                FlowLensTheme.accentBlue.opacity(0.45),
                                FlowLensTheme.accentBlue.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                linePath(values: down, width: w, height: h, maxV: maxV)
                    .stroke(
                        FlowLensTheme.accentBlue,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )

                // Upload area + line
                filledArea(values: up, width: w, height: h, maxV: maxV)
                    .fill(
                        LinearGradient(
                            colors: [
                                FlowLensTheme.accentPurple.opacity(0.40),
                                FlowLensTheme.accentPurple.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                linePath(values: up, width: w, height: h, maxV: maxV)
                    .stroke(
                        FlowLensTheme.accentPurple,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
