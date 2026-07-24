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
}

// MARK: - Chart

struct SunburstChart: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    private let innerHole: CGFloat = 0.30
    private let ring0Inner: CGFloat = 0.34
    private let ring0Outer: CGFloat = 0.62
    private let ring1Inner: CGFloat = 0.66
    private let ring1Outer: CGFloat = 0.94
    private let gapDegrees: Double = 0.6

    var body: some View {
        let current = model.sunburstRoot.node(path: model.sunburstPath)
        let slices = layoutSlices(root: current)
        let centerTitle = model.sunburstPath.isEmpty
            ? l10n.t("sunburst.apps")
            : current.title
        let centerValue = ByteFormat.string(for: current.value)

        VStack(spacing: 10) {
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
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(l10n.t("sunburst.hint"))
                        .font(.system(size: 10))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                }
                Spacer(minLength: 4)
            }

            // Breadcrumb: All › Chrome › …
            if !model.sunburstPath.isEmpty {
                breadcrumb
            }

            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                ZStack {
                    // Soft outer glow ring
                    Circle()
                        .stroke(Color.white.opacity(0.04), lineWidth: 1)
                        .frame(width: size * 0.96, height: size * 0.96)

                    ForEach(slices) { slice in
                        let isHovered = model.hoverNodeID == slice.id
                            || model.hoverNodeID == slice.parentID
                            || (slice.parentID != nil && model.hoverNodeID == slice.id)
                        let dimmed = model.hoverNodeID != nil && !isRelated(hover: model.hoverNodeID, slice: slice)
                        let ratios = ringRatios(ring: slice.ring)

                        RingSlice(
                            start: slice.start,
                            end: slice.end,
                            innerRatio: ratios.inner,
                            outerRatio: ratios.outer
                        )
                        .fill(color(for: slice.node, ring: slice.ring, hovered: isHovered))
                        .opacity(dimmed ? 0.28 : 1)
                        .overlay(
                            RingSlice(
                                start: slice.start,
                                end: slice.end,
                                innerRatio: ratios.inner,
                                outerRatio: ratios.outer
                            )
                            .stroke(Color.black.opacity(0.35), lineWidth: isHovered ? 1.5 : 0.6)
                        )
                        .shadow(color: isHovered ? color(for: slice.node, ring: slice.ring, hovered: true).opacity(0.45) : .clear,
                                radius: isHovered ? 8 : 0)
                        .scaleEffect(isHovered ? 1.02 : 1.0)
                        .animation(.easeOut(duration: 0.15), value: model.hoverNodeID)
                    }

                    // Center disc — liquid glass
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.white.opacity(0.06)))
                        .frame(width: size * innerHole * 2, height: size * innerHole * 2)
                        .overlay(
                            Circle().strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                        )
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                        .overlay {
                            VStack(spacing: 3) {
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
                                if let hover = hoveredLabel(slices: slices) {
                                    Text(hover)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(FlowLensTheme.accentBlue)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .padding(.horizontal, 6)
                                } else if !model.sunburstPath.isEmpty {
                                    Text(l10n.t("sunburst.centerBack"))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(FlowLensTheme.accentBlue.opacity(0.85))
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
            }
            .frame(minHeight: 200)
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(l10n.t("sunburst.root")) {
                    model.sunburstReset()
                }
                ForEach(Array(model.sunburstPath.enumerated()), id: \.offset) { index, step in
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

        // DaisyDisk-like: leave a small open arc on the right for air
        let usable = 340.0
        let openGap = 20.0

        for app in apps {
            let sweep = max(1.2, Double(app.value) / Double(total) * usable - gapDegrees)
            let start = angle
            let end = angle + sweep
            result.append(LaidOutSlice(
                id: app.id,
                node: app,
                start: start,
                end: end,
                ring: 0,
                parentID: nil
            ))

            // Outer ring: websites / projects / sessions under each app.
            // When already drilled, `app` nodes are leaf segments — still draw outer stubs lightly.
            if app.hasChildren {
                let sites = app.children.sorted { $0.value > $1.value }
                let siteTotal = max(1, sites.reduce(UInt64(0)) { $0 &+ $1.value })
                var sa = start
                for site in sites {
                    let ss = max(0.4, Double(site.value) / Double(siteTotal) * sweep - 0.15)
                    let se = min(end, sa + ss)
                    result.append(LaidOutSlice(
                        id: site.id,
                        node: site,
                        start: sa,
                        end: se,
                        ring: 1,
                        parentID: app.id
                    ))
                    sa = se
                }
            } else if model.sunburstPath.isEmpty {
                // Root-level apps without children: thin outer rim only (no fake stubs for drill noise)
                result.append(LaidOutSlice(
                    id: "\(app.id)#rim",
                    node: app,
                    start: start,
                    end: end,
                    ring: 1,
                    parentID: app.id
                ))
            }

            angle = end + gapDegrees
        }
        _ = openGap
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
        // Hovering a site highlights parent app slice
        if hover.hasPrefix(slice.id + "|") { return true }
        if let parent = slice.parentID, hover.hasPrefix(parent + "|") || hover == parent {
            return true
        }
        // stub ids
        if slice.id.hasPrefix(hover + "#") { return true }
        if hover.contains("|"), let parent = slice.parentID, hover.hasPrefix(parent) {
            return slice.ring == 1 && (slice.id == hover || slice.parentID == parent)
        }
        return false
    }

    private func hoveredLabel(slices: [LaidOutSlice]) -> String? {
        guard let id = model.hoverNodeID else { return nil }
        if let slice = slices.first(where: { $0.id == id }) {
            return "\(slice.node.title) · \(ByteFormat.string(for: slice.node.value))"
        }
        // parent from ranking
        if let row = model.rankingRows.first(where: { $0.id == id }) {
            return "\(row.snapshot.displayName) · \(ByteFormat.string(for: row.snapshot.totals.totalBytes))"
        }
        return nil
    }

    // MARK: - Hit testing

    private func polar(at point: CGPoint, size: CGSize) -> (angle: Double, ratio: CGFloat)? {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - c.x
        let dy = point.y - c.y
        let half = min(size.width, size.height) / 2
        guard half > 0 else { return nil }
        let r = hypot(dx, dy) / half
        // atan2: 0 = east; convert so -90° is top (our layout start)
        var deg = Double(atan2(dy, dx)) * 180 / .pi
        // Our slices use SwiftUI angles where 0 is east, -90 is north — same as atan2
        // Normalize to [-90, 270) matching layout starting at -90
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
            ring = nil
        }
        guard let ring else { return nil }

        let angle = polar.angle
        return slices.first { slice in
            guard slice.ring == ring else { return false }
            return angleInRange(angle, start: slice.start, end: slice.end)
        }
    }

    private func angleInRange(_ angle: Double, start: Double, end: Double) -> Bool {
        // All angles in layout are in [-90, ~270]
        return angle >= start && angle <= end
    }

    private func handlePointer(at point: CGPoint, in size: CGSize, slices: [LaidOutSlice]) {
        if let hit = hitSlice(at: point, size: size, slices: slices) {
            // Prefer app id for list sync when hitting outer ring
            if hit.ring == 1, let parent = hit.parentID {
                // If it's a real site (contains |), hover site; stubs hover parent
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
            // Outer site click: drill into parent if not already, or just highlight
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
