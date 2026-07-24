import SwiftUI
import FlowLensCore

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
    let hue: Double
}

// MARK: - Chart

struct SunburstChart: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme

    private let innerHole: CGFloat = 0.30
    private let ring0Inner: CGFloat = 0.34
    private let ring0Outer: CGFloat = 0.62
    private let ring1Inner: CGFloat = 0.66
    private let ring1Outer: CGFloat = 0.94
    private let gapDegrees: Double = 0.6
    private let topShareLimit = 5

    var body: some View {
        let current = model.sunburstRoot.node(path: model.sunburstPath)
        let slices = layoutSlices(root: current)
        let topShares = topShareItems(from: current)
        let centerTitle = model.sunburstPath.isEmpty
            ? l10n.t("sunburst.apps")
            : current.title
        let centerValue = ByteFormat.string(for: current.value)
        let hoverDetail = hoveredDetail(slices: slices, root: current)

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
                        .background(Capsule().fill(FlowLensTheme.accentBlue))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button {
                        model.sunburstReset()
                    } label: {
                        Text(l10n.t("sunburst.root"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FlowLensTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(l10n.t("sunburst.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(FlowLensTheme.textSecondary)
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
                        let isHovered = isSliceHovered(slice)
                        let dimmed = model.hoverNodeID != nil && !isRelated(hover: model.hoverNodeID, slice: slice)
                        let ratios = ringRatios(ring: slice.ring)

                        RingSlice(
                            start: slice.start,
                            end: slice.end,
                            innerRatio: ratios.inner,
                            outerRatio: ratios.outer
                        )
                        .fill(color(for: slice.node, ring: slice.ring, hovered: isHovered))
                        .opacity(dimmed ? 0.22 : 1)
                        .overlay(
                            RingSlice(
                                start: slice.start,
                                end: slice.end,
                                innerRatio: ratios.inner,
                                outerRatio: ratios.outer
                            )
                            .stroke(
                                Color.primary.opacity(colorScheme == .light ? 0.12 : 0.35),
                                lineWidth: isHovered ? 1.6 : 0.6
                            )
                        )
                        .shadow(
                            color: isHovered
                                ? color(for: slice.node, ring: slice.ring, hovered: true).opacity(0.45)
                                : .clear,
                            radius: isHovered ? 8 : 0
                        )
                        .scaleEffect(isHovered ? 1.025 : 1.0)
                        .animation(.easeOut(duration: 0.15), value: model.hoverNodeID)

                        // In-slice label for large enough arcs (inner ring).
                        if slice.ring == 0, slice.share >= 0.08, (slice.end - slice.start) >= 18 {
                            sliceCallout(slice: slice, size: size, emphasized: isHovered)
                                .opacity(dimmed ? 0.15 : (isHovered ? 1 : 0.9))
                        }
                    }

                    // Center disc
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.primary.opacity(0.04)))
                        .frame(width: size * innerHole * 2, height: size * innerHole * 2)
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
                                        .foregroundStyle(FlowLensTheme.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                        .padding(.horizontal, 6)
                                    Text(hoverDetail.percentText)
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundStyle(FlowLensTheme.brandGreen)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Text(hoverDetail.bytesText)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(FlowLensTheme.textPrimary.opacity(0.85))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                } else {
                                    Text(centerTitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(FlowLensTheme.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .padding(.horizontal, 8)
                                    Text(centerValue)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundStyle(FlowLensTheme.textPrimary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                    if !model.sunburstPath.isEmpty {
                                        Text(l10n.t("sunburst.centerBack"))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(FlowLensTheme.accentBlue.opacity(0.85))
                                    } else {
                                        Text(l10n.t("sunburst.shareHint", topShares.count))
                                            .font(.system(size: 9))
                                            .foregroundStyle(FlowLensTheme.textSecondary.opacity(0.85))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                }
                            }
                        }
                        .contentShape(Circle())
                        .onTapGesture {
                            model.sunburstGoBack()
                        }
                        .help(model.sunburstPath.isEmpty ? "" : l10n.t("sunburst.centerBack"))

                    // Hit layer
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    handlePointer(
                                        at: value.location,
                                        in: geo.size,
                                        slices: slices
                                    )
                                }
                                .onEnded { value in
                                    handleClick(
                                        at: value.location,
                                        in: geo.size,
                                        slices: slices,
                                        current: current
                                    )
                                }
                        )
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onHover { inside in
                    if !inside {
                        model.setHoverNode(nil)
                    }
                }
            }
            .frame(minHeight: 160)
            .layoutPriority(1)

            topShareLegend(items: topShares)
        }
        .id(l10n.revision)
    }

    // MARK: - Top share legend

    private func topShareLegend(items: [TopShareItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.t("sunburst.topShares"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .textCase(.uppercase)

            ForEach(items) { item in
                let active = isLegendActive(item.id)
                let dimmed = model.hoverNodeID != nil && !active
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hue: item.hue, saturation: 0.7, brightness: active ? 0.95 : 0.78))
                        .frame(width: 7, height: 7)
                    Text(item.title)
                        .font(.system(size: 10, weight: active ? .semibold : .medium))
                        .foregroundStyle(FlowLensTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(percentString(item.share))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(active ? FlowLensTheme.brandGreen : FlowLensTheme.textSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(FlowLensTheme.brandGreen.opacity(0.10))
                    }
                }
                .opacity(dimmed ? 0.35 : 1)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        model.setHoverNode(item.id)
                    } else if model.hoverNodeID == item.id {
                        model.setHoverNode(nil)
                    }
                }
                .onTapGesture {
                    model.drillInto(nodeID: item.id)
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
                hue: node.hue
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
        guard let hover = model.hoverNodeID else { return false }
        if hover == slice.id { return true }
        if slice.parentID == hover { return true }
        if hover.hasPrefix(slice.id + "|") { return true }
        if let parent = slice.parentID, hover.hasPrefix(parent + "|"), slice.id == hover {
            return true
        }
        return false
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
        return VStack(spacing: 0) {
            Text(slice.node.title)
                .font(.system(size: emphasized ? 9 : 8, weight: .semibold))
                .lineLimit(1)
            Text(percentString(slice.share))
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
        .frame(width: max(36, size * 0.18))
        .offset(x: x, y: y)
        .allowsHitTesting(false)
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
                        .foregroundStyle(FlowLensTheme.textSecondary)
                    let title = model.sunburstRoot.node(path: Array(model.sunburstPath.prefix(index + 1))).title
                    if index == model.sunburstPath.count - 1 {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FlowLensTheme.textPrimary)
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
                .foregroundStyle(FlowLensTheme.accentBlue)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layout

    private func layoutSlices(root: AppModel.SunburstNode) -> [LaidOutSlice] {
        let apps = root.children.sorted { $0.value > $1.value }
        guard !apps.isEmpty else { return [] }

        let total = max(1, apps.reduce(UInt64(0)) { $0 &+ $1.value })
        var result: [LaidOutSlice] = []
        var angle = -90.0

        let usable = 340.0

        for app in apps {
            let share = Double(app.value) / Double(total)
            let sweep = max(1.2, share * usable - gapDegrees)
            let start = angle
            let end = angle + sweep
            result.append(LaidOutSlice(
                id: app.id,
                node: app,
                start: start,
                end: end,
                ring: 0,
                parentID: nil,
                share: share
            ))

            if app.hasChildren {
                let sites = app.children.sorted { $0.value > $1.value }
                let siteTotal = max(1, sites.reduce(UInt64(0)) { $0 &+ $1.value })
                var sa = start
                for site in sites {
                    let siteShareOfApp = Double(site.value) / Double(siteTotal)
                    let ss = max(0.4, siteShareOfApp * sweep - 0.15)
                    let se = min(end, sa + ss)
                    result.append(LaidOutSlice(
                        id: site.id,
                        node: site,
                        start: sa,
                        end: se,
                        ring: 1,
                        parentID: app.id,
                        share: share * siteShareOfApp
                    ))
                    sa = se
                }
            } else if model.sunburstPath.isEmpty {
                result.append(LaidOutSlice(
                    id: "\(app.id)#rim",
                    node: app,
                    start: start,
                    end: end,
                    ring: 1,
                    parentID: app.id,
                    share: share
                ))
            }

            angle = end + gapDegrees
        }
        return result
    }

    private func ringRatios(ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        if ring == 0 {
            return (ring0Inner, ring0Outer)
        }
        return (ring1Inner, ring1Outer)
    }

    private func color(for node: AppModel.SunburstNode, ring: Int, hovered: Bool) -> Color {
        let sat = ring == 0 ? 0.72 : 0.55
        let bri = ring == 0 ? (hovered ? 0.95 : 0.78) : (hovered ? 0.98 : 0.88)
        return Color(hue: node.hue, saturation: sat, brightness: bri)
    }

    private func isRelated(hover: String?, slice: LaidOutSlice) -> Bool {
        guard let hover else { return true }
        if slice.id == hover { return true }
        if slice.parentID == hover { return true }
        if hover.hasPrefix(slice.id + "|") { return true }
        if let parent = slice.parentID, hover.hasPrefix(parent + "|") || hover == parent {
            return true
        }
        if slice.id.hasPrefix(hover + "#") { return true }
        if hover.contains("|"), let parent = slice.parentID, hover.hasPrefix(parent) {
            return slice.ring == 1 && (slice.id == hover || slice.parentID == parent)
        }
        return false
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
        if polar.ratio < innerHole { return nil }

        let ring: Int?
        if polar.ratio >= ring0Inner && polar.ratio <= ring0Outer {
            ring = 0
        } else if polar.ratio >= ring1Inner && polar.ratio <= ring1Outer {
            ring = 1
        } else {
            // Prefer nearest ring when pointer is in gaps between rings.
            if polar.ratio > ring0Outer && polar.ratio < ring1Inner {
                ring = polar.ratio < (ring0Outer + ring1Inner) / 2 ? 0 : 1
            } else if polar.ratio > ring1Outer && polar.ratio <= 1.02 {
                ring = 1
            } else {
                ring = nil
            }
        }
        guard let ring else { return nil }

        let angle = polar.angle
        return slices.first { slice in
            guard slice.ring == ring else { return false }
            return angleInRange(angle, start: slice.start, end: slice.end)
        }
    }

    private func angleInRange(_ angle: Double, start: Double, end: Double) -> Bool {
        angle >= start && angle <= end
    }

    private func handlePointer(at point: CGPoint, in size: CGSize, slices: [LaidOutSlice]) {
        if let hit = hitSlice(at: point, size: size, slices: slices) {
            if hit.ring == 1, let parent = hit.parentID {
                if hit.id.contains("|") {
                    model.setHoverNode(hit.id)
                } else {
                    model.setHoverNode(parent)
                }
            } else {
                model.setHoverNode(hit.id)
            }
        } else {
            model.setHoverNode(nil)
        }
    }

    private func handleClick(
        at point: CGPoint,
        in size: CGSize,
        slices: [LaidOutSlice],
        current: AppModel.SunburstNode
    ) {
        guard let polar = polar(at: point, size: size) else { return }
        if polar.ratio < innerHole {
            model.sunburstGoBack()
            return
        }
        guard let hit = hitSlice(at: point, size: size, slices: slices) else { return }

        if hit.ring == 0 {
            model.drillInto(nodeID: hit.id)
        } else if hit.ring == 1, let parent = hit.parentID {
            if model.sunburstPath.last != parent,
               current.children.first(where: { $0.id == parent })?.hasChildren == true {
                model.drillInto(nodeID: parent)
            }
            if hit.id.contains("|") {
                model.setHoverNode(hit.id)
            }
        }
    }
}
