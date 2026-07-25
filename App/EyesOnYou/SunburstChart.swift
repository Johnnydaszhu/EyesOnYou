import SwiftUI
import EyesOnYouCore

// MARK: - Ring geometry

struct RingSlice: Shape {
    var start: Double
    var end: Double
    var innerRatio: CGFloat
    var outerRatio: CGFloat

    var animatableData: AnimatablePair<
        AnimatablePair<Double, Double>,
        AnimatablePair<CGFloat, CGFloat>
    > {
        get {
            AnimatablePair(
                AnimatablePair(start, end),
                AnimatablePair(innerRatio, outerRatio)
            )
        }
        set {
            start = newValue.first.first
            end = newValue.first.second
            innerRatio = newValue.second.first
            outerRatio = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = min(rect.width, rect.height) / 2
        let inner = half * innerRatio
        let outer = half * outerRatio
        var path = Path()
        path.addArc(
            center: center,
            radius: outer,
            startAngle: .degrees(start),
            endAngle: .degrees(end),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: inner,
            startAngle: .degrees(end),
            endAngle: .degrees(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Layout helpers

private struct LaidOutSlice: Identifiable {
    let id: String
    let node: AppModel.SunburstNode
    let start: Double
    let end: Double
    let ring: Int // 0 = inner, 1 = outer
    let parentID: String?
    /// Share of the *current* sunburst root (0...1).
    let share: Double
}

private struct TopShareItem: Identifiable {
    let id: String
    let title: String
    let value: UInt64
    let share: Double
    let colorIndex: Int
    let colorVariant: Int
}

// MARK: - Chart

struct SunburstChart: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme

    /// Radius of the center disc, as a fraction of the chart's half-size — the same
    /// scale `RingSlice` uses, so the band can start exactly where the disc ends
    /// instead of being covered by it (which is what hid the wedge labels).
    private let discRatio: CGFloat = 0.54
    /// One band per level. The chart shows the level you are on — apps at root, that
    /// app's destinations after a drill — never both at once: stacking children around
    /// their parents turned the ring into hairlines and made a child's share read as
    /// the top app's.
    private let bandInner: CGFloat = 0.58
    private let bandOuter: CGFloat = 0.96
    private let gapDegrees: Double = 0.6
    private let topShareLimit = 5
    /// Wedges kept at full detail; the rest fold into one aggregate wedge.
    private let wedgeLimit = 14
    /// Shares below this are too thin to read, so they fold into the aggregate too.
    private let minWedgeShare = 0.008
    private static let aggregateWedgeID = "__eyesonyou.otherWedge__"

    var body: some View {
        // Slice colors come from the theme palette — re-resolve them when it changes.
        let _ = model.themeRevision
        let softFilter = softFilteredRoot()
        let current = softFilter?.node ?? model.sunburstRoot.node(path: model.sunburstPath)
        let isSoftFiltered = softFilter != nil
        let slices = layoutSlices(root: current)
        let topShares = topShareItems(from: current)
        let centerTitle: String = {
            if let soft = softFilter { return soft.node.title }
            if model.sunburstPath.isEmpty { return l10n.t("sunburst.apps") }
            return current.title
        }()
        let centerValue = ByteFormat.string(for: current.value)
        let hoverDetail = isSoftFiltered ? nil : hoveredDetail(slices: slices, root: current)

        VStack(spacing: 8) {
            // Always-visible drill navigation
            HStack(spacing: 8) {
                if !model.sunburstPath.isEmpty {
                    Button {
                        model.sunburstGoBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .bold))
                            Text(l10n.t("sunburst.back"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(EyesOnYouTheme.accentBlue))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button {
                        model.sunburstReset()
                    } label: {
                        Text(l10n.t("sunburst.root"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(EyesOnYouTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                } else if isSoftFiltered {
                    Text(l10n.t("sunburst.hoverFilter"))
                        .font(.system(size: 10))
                        .foregroundStyle(EyesOnYouTheme.brandGreen)
                } else {
                    Text(l10n.t("sunburst.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                }
                Spacer(minLength: 4)
            }

            if !model.sunburstPath.isEmpty {
                breadcrumb
            }

            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        .frame(width: size * 0.96, height: size * 0.96)

                    ForEach(slices) { slice in
                        let isHovered = !isSoftFiltered && isSliceHovered(slice)
                        let dimmed = !isSoftFiltered
                            && model.hoverNodeID != nil
                            && !isRelated(hover: model.hoverNodeID, slice: slice)
                        let ratios = ringRatios(ring: slice.ring)
                        // Pull the hovered wedge out of the ring so the segment the
                        // ranking table just highlighted is unmistakable.
                        let pull = explodeOffset(slice: slice, size: size, active: isHovered)

                        RingSlice(
                            start: slice.start,
                            end: slice.end,
                            innerRatio: ratios.inner,
                            outerRatio: ratios.outer
                        )
                        .fill(wedgeColor(slice, hovered: isHovered))
                        .opacity(dimmed ? 0.22 : 1)
                        .overlay(
                            RingSlice(
                                start: slice.start,
                                end: slice.end,
                                innerRatio: ratios.inner,
                                outerRatio: ratios.outer
                            )
                            .stroke(
                                isHovered
                                    ? EyesOnYouTheme.brandGreen.opacity(0.85)
                                    : Color.primary.opacity(colorScheme == .light ? 0.12 : 0.35),
                                lineWidth: isHovered ? 1.8 : 0.6
                            )
                        )
                        .shadow(
                            color: isHovered ? wedgeColor(slice, hovered: true).opacity(0.45) : .clear,
                            radius: isHovered ? 8 : 0
                        )
                        .scaleEffect(isHovered ? 1.03 : 1.0)
                        .offset(x: pull.width, y: pull.height)
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: model.hoverNodeID)

                        // In-wedge label once the arc is wide enough to hold it.
                        if slice.share >= 0.07, (slice.end - slice.start) >= 16 {
                            sliceCallout(slice: slice, size: size, emphasized: isHovered)
                                .offset(x: pull.width, y: pull.height)
                                .opacity(dimmed ? 0.15 : (isHovered ? 1 : 0.9))
                                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: model.hoverNodeID)
                        }
                    }

                    // Center disc
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.primary.opacity(0.04)))
                        .frame(width: size * discRatio, height: size * discRatio)
                        .overlay(
                            Circle().strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.primary.opacity(colorScheme == .light ? 0.18 : 0.35),
                                        Color.primary.opacity(0.06)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                        )
                        .shadow(color: .black.opacity(colorScheme == .light ? 0.08 : 0.25), radius: 8, y: 2)
                        .overlay {
                            VStack(spacing: 2) {
                                if let hoverDetail {
                                    Text(hoverDetail.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                        .padding(.horizontal, 6)
                                    Text(hoverDetail.percentText)
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundStyle(EyesOnYouTheme.brandGreen)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Text(hoverDetail.bytesText)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(EyesOnYouTheme.textPrimary.opacity(0.85))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                } else {
                                    Text(centerTitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .padding(.horizontal, 8)
                                    Text(centerValue)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(EyesOnYouTheme.textPrimary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                    if isSoftFiltered {
                                        Text(l10n.t("sunburst.hoverFilter"))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(EyesOnYouTheme.brandGreen.opacity(0.9))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    } else if !model.sunburstPath.isEmpty {
                                        Text(l10n.t("sunburst.centerBack"))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(EyesOnYouTheme.accentBlue.opacity(0.85))
                                    } else {
                                        Text(l10n.t("sunburst.shareHint", topShares.count))
                                            .font(.system(size: 9))
                                            .foregroundStyle(EyesOnYouTheme.textSecondary.opacity(0.85))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                }
                            }
                        }
                        .contentShape(Circle())
                        .onTapGesture {
                            if isSoftFiltered, let appID = softFilter?.appID {
                                model.drillInto(nodeID: appID)
                            } else {
                                model.sunburstGoBack()
                            }
                        }
                        .help(
                            isSoftFiltered
                                ? l10n.t("ranking.drill")
                                : (model.sunburstPath.isEmpty ? "" : l10n.t("sunburst.centerBack"))
                        )

                    // Hit layer. Pointer tracking has to be a hover phase: a drag gesture
                    // only reports while a button is held, so plain mouse moves over the
                    // rings never reached the chart. Geometry is the square ring box, not
                    // the reader's full rect, or every angle lands one wedge off.
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let location):
                                handlePointer(
                                    at: location,
                                    in: CGSize(width: size, height: size),
                                    slices: slices
                                )
                            case .ended:
                                model.setHoverNode(nil)
                                model.setPieHoverRow(nil)
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    handleClick(
                                        at: value.location,
                                        in: CGSize(width: size, height: size),
                                        slices: slices,
                                        softFilterAppID: softFilter?.appID
                                    )
                                }
                        )
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onHover { inside in
                    if !inside {
                        model.setHoverNode(nil)
                        model.setPieHoverRow(nil)
                    }
                }
            }
            .frame(minHeight: 160)
            .layoutPriority(1)

            topShareLegend(items: topShares, softFiltered: isSoftFiltered)
        }
        .animation(.easeOut(duration: 0.18), value: softFilter?.appID)
        .id(l10n.revision)
    }

    /// Ranking-row hover temporarily filters the pie to that app's destinations
    /// (real-time preview without committing a drill).
    private func softFilteredRoot() -> (appID: String, node: AppModel.SunburstNode)? {
        guard model.sunburstPath.isEmpty,
              let appID = model.rankingHoverFilterID,
              let focused = model.sunburstRoot.children.first(where: { $0.id == appID }),
              focused.hasChildren
        else {
            return nil
        }
        return (
            appID: focused.id,
            node: AppModel.SunburstNode(
                id: focused.id,
                title: focused.title,
                value: focused.value,
                colorIndex: focused.colorIndex,
                colorVariant: focused.colorVariant,
                children: focused.children
            )
        )
    }

    // MARK: - Top share legend

    private func topShareLegend(items: [TopShareItem], softFiltered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.t(softFiltered ? "sunburst.filteredShares" : "sunburst.topShares"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(EyesOnYouTheme.textSecondary)
                .textCase(.uppercase)

            ForEach(items) { item in
                let active = softFiltered || isLegendActive(item.id)
                let dimmed = !softFiltered && model.hoverNodeID != nil && !active
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            EyesOnYouTheme.seriesColor(
                                index: item.colorIndex,
                                variant: item.colorVariant,
                                hovered: active
                            )
                        )
                        .frame(width: 7, height: 7)
                    Text(item.title)
                        .font(.system(size: 10, weight: active ? .semibold : .medium))
                        .foregroundStyle(EyesOnYouTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(percentString(item.share))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(active ? EyesOnYouTheme.brandGreen : EyesOnYouTheme.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    if active && !softFiltered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(EyesOnYouTheme.brandGreen.opacity(0.10))
                    }
                }
                .opacity(dimmed ? 0.35 : 1)
                .contentShape(Rectangle())
                .onHover { inside in
                    if softFiltered { return }
                    if inside {
                        model.setHoverNode(item.id)
                        model.setPieHoverRow(item.id)
                    } else if model.hoverNodeID == item.id {
                        model.setHoverNode(nil)
                        model.setPieHoverRow(nil)
                    }
                }
                .onTapGesture {
                    if softFiltered, let appID = softFilteredRoot()?.appID {
                        model.drillInto(nodeID: appID)
                    } else {
                        model.drillInto(nodeID: item.id)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: model.hoverNodeID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func topShareItems(from root: AppModel.SunburstNode) -> [TopShareItem] {
        let kids = root.children.sorted { $0.value > $1.value }
        let total = max(1, root.value == 0 ? kids.reduce(UInt64(0)) { $0 &+ $1.value } : root.value)
        return Array(kids.prefix(topShareLimit)).map { node in
            TopShareItem(
                id: node.id,
                title: node.title,
                value: node.value,
                share: Double(node.value) / Double(total),
                colorIndex: node.colorIndex,
                colorVariant: node.colorVariant
            )
        }
    }

    private func isLegendActive(_ id: String) -> Bool {
        guard let hover = model.hoverNodeID else { return false }
        if hover == id { return true }
        if hover.hasPrefix(id + "|") { return true }
        if hover.hasPrefix(id + "#") { return true }
        return false
    }

    private func isSliceHovered(_ slice: LaidOutSlice) -> Bool {
        guard let hover = model.hoverNodeID, !isAggregate(slice.id) else { return false }
        // A drilled row hover carries `app|dest`; at root that still belongs to the app wedge.
        return hover == slice.id || hover.hasPrefix(slice.id + "|")
    }

    // MARK: - Slice callout

    private func sliceCallout(slice: LaidOutSlice, size: CGFloat, emphasized: Bool) -> some View {
        let mid = (slice.start + slice.end) / 2.0
        let ratios = ringRatios(ring: slice.ring)
        let radiusRatio = (ratios.inner + ratios.outer) / 2
        let rad = Angle(degrees: mid).radians
        let r = size / 2 * radiusRatio
        let x = cos(rad) * r
        let y = sin(rad) * r
        // Themed slices can be pale (mono, light accents) — flip the label instead of
        // leaving white-on-white. Resolve against the app appearance, not the ambient one.
        let scheme = model.appearanceMode.preferredColorScheme ?? colorScheme
        let onLightSlice = isAggregate(slice.id)
            ? false
            : EyesOnYouTheme.seriesLuminance(
                index: slice.node.colorIndex,
                variant: slice.node.colorVariant,
                ring: slice.ring,
                hovered: emphasized,
                isDark: scheme == .dark
            ) > 0.62
        // Radial room inside the band decides how many lines the name can take.
        let bandThickness = size / 2 * (ratios.outer - ratios.inner)
        let titleSize = emphasized ? 9.0 : 8.0
        let titleLines = bandThickness >= titleSize * 3.4 ? 2 : 1
        return VStack(spacing: 0) {
            Text(slice.node.title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(titleLines)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
            Text(percentString(slice.share))
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(onLightSlice ? Color.black.opacity(0.80) : Color.white.opacity(0.92))
        .shadow(
            color: onLightSlice ? Color.white.opacity(0.55) : Color.black.opacity(0.45),
            radius: 1.5,
            y: 0.5
        )
        // Keep the label inside its own wedge: wide arcs may hold a long name, narrow
        // ones must not spill into the neighbour.
        .frame(width: calloutWidth(slice: slice, size: size, radiusRatio: radiusRatio))
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    /// Chord the wedge offers at the label's radius, clamped so even a 360° wedge keeps
    /// its text inside the ring rather than running over the hole.
    private func calloutWidth(slice: LaidOutSlice, size: CGFloat, radiusRatio: CGFloat) -> CGFloat {
        let sweep = min(120.0, max(0, slice.end - slice.start))
        let radius = size / 2 * radiusRatio
        let chord = 2 * radius * CGFloat(sin(Angle(degrees: sweep / 2).radians))
        return max(34, min(chord * 0.9, size * 0.30))
    }

    private struct HoverDetail {
        let title: String
        let percentText: String
        let bytesText: String
    }

    private func hoveredDetail(slices: [LaidOutSlice], root: AppModel.SunburstNode) -> HoverDetail? {
        guard let id = model.hoverNodeID else { return nil }
        if let slice = slices.first(where: { $0.id == id }) {
            return HoverDetail(
                title: slice.node.title,
                percentText: percentString(slice.share),
                bytesText: ByteFormat.string(for: slice.node.value)
            )
        }
        if let row = model.rankingRows.first(where: { $0.id == id }) {
            let total = max(1, root.value)
            let share = Double(row.snapshot.totals.totalBytes) / Double(total)
            return HoverDetail(
                title: row.snapshot.displayName,
                percentText: percentString(share),
                bytesText: ByteFormat.string(for: row.snapshot.totals.totalBytes)
            )
        }
        // Outer child matched via parent prefix
        if let slice = slices.first(where: { $0.id == id || id.hasPrefix($0.id) }) {
            return HoverDetail(
                title: slice.node.title,
                percentText: percentString(slice.share),
                bytesText: ByteFormat.string(for: slice.node.value)
            )
        }
        return nil
    }

    private func percentString(_ share: Double) -> String {
        let pct = share * 100
        if pct >= 9.95 {
            return String(format: "%.0f%%", pct)
        }
        if pct >= 1 {
            return String(format: "%.1f%%", pct)
        }
        return String(format: "%.2f%%", pct)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(l10n.t("sunburst.root")) {
                    model.sunburstReset()
                }
                ForEach(Array(model.sunburstPath.enumerated()), id: \.offset) { index, _ in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(EyesOnYouTheme.textSecondary)
                    let title = model.sunburstRoot.node(path: Array(model.sunburstPath.prefix(index + 1))).title
                    if index == model.sunburstPath.count - 1 {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(EyesOnYouTheme.textPrimary)
                            .lineLimit(1)
                    } else {
                        crumb(title) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                model.sunburstPath = Array(model.sunburstPath.prefix(index + 1))
                                model.hoverNodeID = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func crumb(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EyesOnYouTheme.accentBlue)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layout

    private func layoutSlices(root: AppModel.SunburstNode) -> [LaidOutSlice] {
        let wedges = wedgeNodes(of: root)
        guard !wedges.isEmpty else { return [] }

        // Angles are proportional to measured bytes; only the fixed inter-wedge gaps
        // come off the circle, so a wedge's sweep is its share of the whole ring.
        let total = max(1, wedges.reduce(UInt64(0)) { $0 &+ $1.value })
        let usable = max(60.0, 360.0 - gapDegrees * Double(wedges.count))
        var result: [LaidOutSlice] = []
        var angle = -90.0

        for wedge in wedges {
            let share = Double(wedge.value) / Double(total)
            let sweep = max(0.35, share * usable)
            result.append(LaidOutSlice(
                id: wedge.id,
                node: wedge,
                start: angle,
                end: angle + sweep,
                ring: 0,
                parentID: nil,
                share: share
            ))
            angle += sweep + gapDegrees
        }
        return result
    }

    /// Children of the current level, biggest first, with the unreadable tail folded
    /// into one aggregate wedge carrying the tail's real summed bytes.
    private func wedgeNodes(of root: AppModel.SunburstNode) -> [AppModel.SunburstNode] {
        let kids = root.children.sorted { $0.value > $1.value }
        guard !kids.isEmpty else { return [] }
        let total = max(1, kids.reduce(UInt64(0)) { $0 &+ $1.value })

        var kept: [AppModel.SunburstNode] = []
        var tail: [AppModel.SunburstNode] = []
        for (index, kid) in kids.enumerated() {
            let share = Double(kid.value) / Double(total)
            if index < wedgeLimit && share >= minWedgeShare {
                kept.append(kid)
            } else {
                tail.append(kid)
            }
        }
        // A single leftover stays itself — folding one item explains nothing.
        guard tail.count > 1 else { return kept + tail }

        let summed = tail.reduce(UInt64(0)) { $0 &+ $1.value }
        kept.append(
            AppModel.SunburstNode(
                id: Self.aggregateWedgeID,
                title: l10n.t("sunburst.otherWedge", tail.count),
                value: summed,
                colorIndex: 0,
                colorVariant: 0,
                children: []
            )
        )
        return kept
    }

    /// The folded tail wedge: it stands for many rows, so it takes no hover or drill.
    private func isAggregate(_ id: String) -> Bool {
        id == Self.aggregateWedgeID
    }

    /// Radial nudge along the wedge's mid-angle, for the hovered segment only.
    /// Hit testing stays on the un-nudged geometry, so the pointer keeps the slice
    /// it picked instead of sliding off the shape it just moved.
    private func explodeOffset(slice: LaidOutSlice, size: CGFloat, active: Bool) -> CGSize {
        guard active else { return .zero }
        let mid: Double = Angle(degrees: (slice.start + slice.end) / 2).radians
        let push = max(4, size * 0.032)
        return CGSize(width: CGFloat(cos(mid)) * push, height: CGFloat(sin(mid)) * push)
    }

    private func ringRatios(ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        (bandInner, bandOuter)
    }

    /// Palette color for a wedge; the folded tail stays neutral so it never competes
    /// with a real app for attention.
    private func wedgeColor(_ slice: LaidOutSlice, hovered: Bool) -> Color {
        if isAggregate(slice.id) {
            return EyesOnYouTheme.textSecondary.opacity(colorScheme == .light ? 0.28 : 0.32)
        }
        return EyesOnYouTheme.seriesColor(
            index: slice.node.colorIndex,
            variant: slice.node.colorVariant,
            ring: slice.ring,
            hovered: hovered
        )
    }

    /// Everything but the hovered wedge fades, so one segment reads at a time.
    private func isRelated(hover: String?, slice: LaidOutSlice) -> Bool {
        hover == nil ? true : isSliceHovered(slice)
    }

    // MARK: - Hit testing

    private func polar(at point: CGPoint, size: CGSize) -> (angle: Double, ratio: CGFloat)? {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - c.x
        let dy = point.y - c.y
        let half = min(size.width, size.height) / 2
        guard half > 0 else { return nil }
        let r = hypot(dx, dy) / half
        var deg = Double(atan2(dy, dx)) * 180 / .pi
        if deg < -90 { deg += 360 }
        return (deg, r)
    }

    private func hitSlice(at point: CGPoint, size: CGSize, slices: [LaidOutSlice]) -> LaidOutSlice? {
        guard let polar = polar(at: point, size: size) else { return nil }
        // One band: anything from just inside its edge out to the rim counts, so the
        // pointer never falls into a dead zone between rings.
        guard polar.ratio >= bandInner - 0.03, polar.ratio <= 1.02 else { return nil }
        return slices.first { angleInRange(polar.angle, start: $0.start, end: $0.end) }
    }

    private func angleInRange(_ angle: Double, start: Double, end: Double) -> Bool {
        angle >= start && angle <= end
    }

    private func handlePointer(at point: CGPoint, in size: CGSize, slices: [LaidOutSlice]) {
        guard let hit = hitSlice(at: point, size: size, slices: slices), !isAggregate(hit.id) else {
            model.setHoverNode(nil)
            model.setPieHoverRow(nil)
            return
        }
        // Wedge ids are ranking row ids at every level, so the two cards light up
        // the same thing without any translation.
        model.setHoverNode(hit.id)
        model.setPieHoverRow(hit.id)
    }

    private func handleClick(
        at point: CGPoint,
        in size: CGSize,
        slices: [LaidOutSlice],
        softFilterAppID: String?
    ) {
        guard let polar = polar(at: point, size: size) else { return }
        if polar.ratio < discRatio {
            // The hit layer sits above the center disc, so honour what the disc offers:
            // commit the hovered app's preview, otherwise step back out.
            if let softFilterAppID {
                model.drillInto(nodeID: softFilterAppID)
            } else {
                model.sunburstGoBack()
            }
            return
        }
        guard let hit = hitSlice(at: point, size: size, slices: slices), !isAggregate(hit.id) else { return }
        model.drillInto(nodeID: hit.id)
    }
}
