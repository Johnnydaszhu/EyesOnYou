import AppKit
import SwiftUI
import Combine
import EyesOnYouCore

/// Persistent menu-bar status item + click-to-toggle popover (menu extra).
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// Invisible screen-space anchor so the popover opens on the clicked display
    /// (NSPopover + NSStatusItem is unreliable across multiple monitors).
    private var positioningWindow: NSWindow?
    private var model: AppModel?
    private var eventMonitor: Any?
    private var rateCancellable: AnyCancellable?
    private var styleCancellable: AnyCancellable?
    private var titleTimer: Timer?
    private var hostingController: NSHostingController<AnyView>?
    private var statusHostingView: NSHostingView<AnyView>?
    private var didInstall = false

    private override init() {
        super.init()
    }

    /// Call from app launch with the shared AppModel (safe to call multiple times).
    func install(model: AppModel) {
        self.model = model
        if statusItem == nil {
            createStatusItem()
        }
        rebuildPopoverContent()
        bindLiveTitle(to: model)
        refreshStatusItemAppearance()
        didInstall = true
    }

    // MARK: - Status item

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.title = ""
        button.image = nil
        button.toolTip = AppBrand.displayName
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
    }

    private func rebuildPopoverContent() {
        guard let model else { return }

        let root = MenuBarPopoverView()
            .environmentObject(model)
            .environmentObject(LocalizationStore.shared)

        let host = NSHostingController(rootView: AnyView(root))
        let size = preferredPopoverSize(appCount: currentMenuAppCount(in: model))
        host.view.frame = NSRect(origin: .zero, size: size)

        let pop = NSPopover()
        pop.contentSize = size
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.appearance = model.appearanceMode.nsAppearance
            ?? NSApp.effectiveAppearance
        pop.contentViewController = host
        popover = pop
        hostingController = host
    }

    /// Visible frame height of the screen hosting the status item (fallback: main).
    var popoverScreenVisibleHeight: CGFloat {
        let screen = statusItem?.button?.window?.screen
            ?? NSScreen.main
        return screen?.visibleFrame.height ?? 900
    }

    /// Keep `NSPopover.contentSize` aligned with adaptive SwiftUI height.
    func applyPopoverContentSize(appCount: Int) {
        let size = preferredPopoverSize(appCount: appCount)
        if let host = hostingController {
            host.view.frame = NSRect(origin: .zero, size: size)
        }
        popover?.contentSize = size
    }

    private func preferredPopoverSize(appCount: Int) -> NSSize {
        let height = MenuBarPopoverSizing.preferredHeight(
            appCount: appCount,
            screenHeight: popoverScreenVisibleHeight
        )
        return NSSize(width: MenuBarPopoverSizing.width, height: height)
    }

    private func currentMenuAppCount(in model: AppModel) -> Int {
        // Keep in sync with `MenuBarPopoverView.visibleApps` (capped at 24).
        let sourceCount: Int = {
            if !model.rankingRows.isEmpty {
                return model.rankingRows.count
            }
            return model.topApps.count
        }()
        return min(sourceCount, 24)
    }

    /// Keep popover chrome in sync with main-window appearance.
    func refreshPopoverAppearance() {
        guard let model else { return }
        popover?.appearance = model.appearanceMode.nsAppearance
            ?? NSApp.effectiveAppearance
    }

    private func bindLiveTitle(to model: AppModel) {
        rateCancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemAppearance()
            }
        if titleTimer == nil {
            titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatusItemAppearance()
                }
            }
            if let titleTimer {
                RunLoop.main.add(titleTimer, forMode: .common)
            }
        }
        refreshStatusItemAppearance()
    }

    /// Rebuild menu-bar mini chart / rates according to `menuBarDisplayStyle`.
    func refreshStatusItemAppearance() {
        guard let button = statusItem?.button, let model else { return }
        let l10n = LocalizationStore.shared
        let style = model.menuBarDisplayStyle

        let width: CGFloat
        switch style {
        case .iconOnly: width = 26
        case .compactRates: width = 72
        case .dualPath: width = 132
        }
        statusItem?.length = width

        let itemHeight: CGFloat = 18
        let root = AnyView(
            MenuBarStatusItemView(style: style)
                .environmentObject(model)
                .environmentObject(l10n)
                .preferredColorScheme(model.appearanceMode.preferredColorScheme)
                .frame(width: width, height: itemHeight)
        )

        if let existing = statusHostingView {
            existing.rootView = root
            existing.frame = NSRect(x: 0, y: 0, width: width, height: itemHeight)
            existing.appearance = model.appearanceMode.nsAppearance
        } else {
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: width, height: itemHeight)
            host.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
            host.appearance = model.appearanceMode.nsAppearance
            button.addSubview(host)
            statusHostingView = host
        }

        // Keep a bit of left padding so the custom view sits in the button.
        statusHostingView?.frame.origin = CGPoint(x: 2, y: (button.bounds.height - itemHeight) / 2)

        let down = ByteFormat.rateMBps(bytesPerSecond: model.rateDownBps)
        let up = ByteFormat.rateMBps(bytesPerSecond: model.rateUpBps)
        let dPct = Int((model.directShare * 100).rounded())
        let pPct = Int((model.proxyShare * 100).rounded())
        button.toolTip = """
        \(AppBrand.displayName)
        \(l10n.t("status.path.total")) ↓ \(down)  ↑ \(up)
        \(l10n.t("status.path.direct")) ↓ \(ByteFormat.rateMBps(bytesPerSecond: model.directDownBps))  ↑ \(ByteFormat.rateMBps(bytesPerSecond: model.directUpBps))  (\(dPct)%)
        \(l10n.t("status.path.proxy")) ↓ \(ByteFormat.rateMBps(bytesPerSecond: model.proxyDownBps))  ↑ \(ByteFormat.rateMBps(bytesPerSecond: model.proxyUpBps))  (\(pPct)%)
        \(l10n.t("menu.menuStyle")): \(l10n.t(style.localizationKey))
        """
    }

    // MARK: - Click handling

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        guard let popover, let button = statusItem?.button else {
            if let model {
                install(model: model)
            }
            return
        }
        if popover.isShown {
            closePopover()
        } else {
            openPopover(relativeTo: button)
        }
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        if let model, let host = hostingController {
            host.rootView = AnyView(
                MenuBarPopoverView()
                    .environmentObject(model)
                    .environmentObject(LocalizationStore.shared)
            )
            applyPopoverContentSize(appCount: currentMenuAppCount(in: model))
        }
        refreshPopoverAppearance()

        // Anchor in screen space under the clicked status item. Direct
        // `show(relativeTo:of:)` against NSStatusBarButton often lands on the
        // primary display when the icon was clicked on another monitor.
        if let anchorView = preparePositioningAnchor(for: button) {
            popover?.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        // Pin the popover window as key *before* app activation, otherwise
        // activation can promote the dashboard on another display and drag
        // placement / focus with it.
        if let popoverWindow = popover?.contentViewController?.view.window {
            popoverWindow.makeKeyAndOrderFront(nil)
        }
        button.isHighlighted = true
        NSApp.activate(ignoringOtherApps: true)
        startEventMonitor()
    }

    /// Places a transparent 1pt-tall window under the status button on the
    /// same screen, and returns its content view for popover attachment.
    private func preparePositioningAnchor(for button: NSStatusBarButton) -> NSView? {
        guard let buttonWindow = button.window else { return nil }

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonInScreen = buttonWindow.convertToScreen(buttonInWindow)
        guard buttonInScreen.width > 0, buttonInScreen.height > 0 else { return nil }

        let anchor = positioningWindow ?? makePositioningWindow()
        positioningWindow = anchor

        let width = max(buttonInScreen.width, 2)
        let height: CGFloat = 1
        let frame = NSRect(
            x: buttonInScreen.midX - width / 2,
            y: buttonInScreen.minY,
            width: width,
            height: height
        )
        anchor.setFrame(frame, display: true)
        // Stay on the clicked display's Space without stealing focus yet.
        anchor.orderFrontRegardless()
        return anchor.contentView
    }

    private func makePositioningWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
    }

    func closePopover() {
        popover?.performClose(nil)
        positioningWindow?.orderOut(nil)
        statusItem?.button?.isHighlighted = false
        stopEventMonitor()
    }

    private func showContextMenu() {
        let l10n = LocalizationStore.shared
        let menu = NSMenu()
        menu.addItem(withTitle: l10n.t("menu.openDashboard"), action: #selector(ctxOpenDashboard), keyEquivalent: "")
        menu.addItem(withTitle: l10n.t("settings.title"), action: #selector(ctxOpenSettings), keyEquivalent: ",")
        menu.addItem(withTitle: l10n.t("menu.menuStyle"), action: #selector(ctxCycleStyle), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: l10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items {
            item.target = self
        }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear menu so left-click goes back to popover.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    @objc private func ctxOpenDashboard() {
        model?.openDashboard()
    }

    @objc private func ctxOpenSettings() {
        model?.openSettings()
    }

    @objc private func ctxCycleStyle() {
        model?.cycleMenuBarDisplayStyle()
        refreshStatusItemAppearance()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func stopEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        positioningWindow?.orderOut(nil)
        statusItem?.button?.isHighlighted = false
        stopEventMonitor()
    }
}

// MARK: - Menu bar status item content (iStat-style mini)

struct MenuBarStatusItemView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme
    let style: AppModel.MenuBarDisplayStyle

    private var statusRouteDirect: Color {
        let scheme = model.appearanceMode.preferredColorScheme ?? colorScheme
        return EyesOnYouTheme.canvasRouteDirect(colorScheme: scheme)
    }

    private var statusRouteProxy: Color {
        let scheme = model.appearanceMode.preferredColorScheme ?? colorScheme
        return EyesOnYouTheme.canvasRouteProxy(colorScheme: scheme)
    }

    var body: some View {
        let _ = model.themeRevision
        Group {
            switch style {
            case .iconOnly:
                AppBrand.logo
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .compactRates:
                VStack(alignment: .trailing, spacing: -1) {
                    Text("↓\(shortRate(model.rateDownBps))")
                    Text("↑\(shortRate(model.rateUpBps))")
                }
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            case .dualPath:
                HStack(spacing: 6) {
                    PathDualSparkline(
                        direct: model.sparklineDirect,
                        proxy: model.sparklineProxy,
                        lineWidth: 0.7,
                        fillOpacity: 0.1
                    )
                    .frame(width: 22, height: 10)
                    HStack(spacing: 4) {
                        VStack(alignment: .leading, spacing: -1) {
                            Text(l10n.t("status.path.direct"))
                                .foregroundStyle(statusRouteDirect)
                            Text(l10n.t("status.path.proxy"))
                                .foregroundStyle(statusRouteProxy)
                        }
                        VStack(alignment: .trailing, spacing: -1) {
                            Text("↓\(shortRate(model.directDownBps))")
                            Text("↓\(shortRate(model.proxyDownBps))")
                        }
                        .frame(minWidth: 36, alignment: .trailing)
                    }
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 2)
        // Non-interactive so NSStatusBarButton receives the click.
        .allowsHitTesting(false)
    }

    private func shortRate(_ bps: Double) -> String {
        // Prefer shorter form for menu bar width.
        let s = ByteFormat.rateMBps(bytesPerSecond: bps)
        return s
            .replacingOccurrences(of: " MB/s", with: "M")
            .replacingOccurrences(of: " KB/s", with: "K")
            .replacingOccurrences(of: " B/s", with: "B")
    }
}
