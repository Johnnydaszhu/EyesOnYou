import SwiftUI

/// Breakpoints + size tokens for Overview bento extreme adaptivity.
struct BentoMetrics: Equatable {
    enum WidthClass: Equatable {
        /// ≥ 1200: roomy 3-up metrics + wide ranking
        case xl
        /// ≥ 980: standard 3-up
        case large
        /// ≥ 760: 2+1 metrics, side-by-side row2
        case medium
        /// ≥ 560: stacked metrics pairs, stacked row2
        case compact
        /// < 560: single column, slim columns
        case tiny
    }

    let container: CGSize
    let widthClass: WidthClass
    let gap: CGFloat
    let outerPadding: CGFloat

    /// Row 1 height scales with width and remaining viewport.
    let metricsRowHeight: CGFloat
    /// Row 2 height for sunburst + ranking.
    let detailRowHeight: CGFloat
    /// Sunburst column width ratio (0...1 of content width).
    let sunburstWidthRatio: CGFloat
    /// Content scale for type / icons (0.85...1.15).
    let typeScale: CGFloat
    /// Area chart height inside live card.
    let areaChartHeight: CGFloat
    /// Metric icon size.
    let metricIconSize: CGFloat
    /// Primary value font size.
    let valueFontSize: CGFloat
    /// Whether ranking shows the trailing tag columns (egress / online).
    /// Both are narrow text cells, so only the tiniest layout drops them.
    let showTagColumns: Bool
    /// Ranking header font.
    let rankingHeaderFont: CGFloat
    let rankingRowFont: CGFloat

    init(container: CGSize) {
        let w = max(container.width, 320)
        let h = max(container.height, 400)
        self.container = CGSize(width: w, height: h)

        let wc: WidthClass
        switch w {
        case 1200...: wc = .xl
        case 980..<1200: wc = .large
        case 760..<980: wc = .medium
        case 560..<760: wc = .compact
        default: wc = .tiny
        }
        self.widthClass = wc

        switch wc {
        case .xl:
            gap = 14
            outerPadding = 0
            typeScale = 1.08
            sunburstWidthRatio = 0.30
            showTagColumns = true
        case .large:
            gap = 12
            outerPadding = 0
            typeScale = 1.0
            sunburstWidthRatio = 0.32
            showTagColumns = true
        case .medium:
            gap = 12
            outerPadding = 0
            typeScale = 0.96
            sunburstWidthRatio = 0.36
            showTagColumns = true
        case .compact:
            gap = 10
            outerPadding = 0
            typeScale = 0.92
            sunburstWidthRatio = 1.0
            showTagColumns = true
        case .tiny:
            gap = 8
            outerPadding = 0
            typeScale = 0.88
            sunburstWidthRatio = 1.0
            showTagColumns = false
        }

        // Metrics row: keep totals / live / proxy cards on one shared height.
        let idealMetrics = h * (wc == .tiny || wc == .compact ? 0.38 : 0.22)
        metricsRowHeight = min(max(idealMetrics, 148), wc == .xl ? 200 : 176)

        // Detail row height token (used when side-by-side fills remaining flex space).
        let idealDetail = h * (wc == .tiny || wc == .compact ? 0.55 : 0.58)
        detailRowHeight = min(max(idealDetail, 280), max(h * 0.72, 320))

        areaChartHeight = min(max(metricsRowHeight * 0.38, 48), 96)
        metricIconSize = 14 * typeScale
        valueFontSize = 15 * typeScale
        rankingHeaderFont = 10 * typeScale
        rankingRowFont = 11 * typeScale
    }

    var contentWidth: CGFloat { container.width }
    var isThreeUpMetrics: Bool {
        widthClass == .xl || widthClass == .large
    }
    var isTwoUpMetrics: Bool {
        widthClass == .medium
    }
    var isSideBySideDetail: Bool {
        widthClass == .xl || widthClass == .large || widthClass == .medium
    }

    /// Fixed height for the metrics block so the page never needs outer scroll.
    var metricsBlockHeight: CGFloat {
        switch widthClass {
        case .xl, .large:
            return metricsRowHeight
        case .medium:
            // 2-up + proxy strip
            return metricsRowHeight + gap + metricsRowHeight * 0.85
        case .compact, .tiny:
            // Stacked metrics: cap so ranking always keeps room to scroll inside its card.
            return min(max(container.height * 0.34, 200), 280)
        }
    }

    /// Sunburst height when stacked above ranking (narrow layouts).
    var stackedSunburstHeight: CGFloat {
        min(max(container.height * 0.22, 160), 240)
    }

    /// Width of one equal column in the 3-up bento grid.
    func columnWidth(in total: CGFloat, columns: Int = 3) -> CGFloat {
        let cols = max(1, columns)
        return floor((total - gap * CGFloat(cols - 1)) / CGFloat(cols))
    }
}

// MARK: - Equal-height flexible row

/// Lays children in a row (or column) with equal heights and flexible widths.
struct BentoEqualRow<Content: View>: View {
    let spacing: CGFloat
    let minHeight: CGFloat
    let columns: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Use Grid for true equal-height cells when multi-column.
        if columns <= 1 {
            VStack(spacing: spacing, content: content)
        } else {
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                GridRow {
                    content()
                }
                .frame(minHeight: minHeight, maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: minHeight, maxHeight: minHeight + 40)
        }
    }
}

extension View {
    /// Fill a bento cell: expand width/height, clip overflow softly.
    func bentoCell(minHeight: CGFloat) -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: minHeight)
    }
}
