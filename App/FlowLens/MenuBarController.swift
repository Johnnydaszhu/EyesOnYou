import AppKit
import SwiftUI
import Combine
import FlowLensCore

/// Persistent menu-bar status item + click-to-toggle popover (menu extra).
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
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
        host.view.frame = NSRect(x: 0, y: 0, width: 340, height: 460)

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 340, height: 460)
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.appearance = model.appearanceMode.nsAppearance
            ?? NSApp.effectiveAppearance
        pop.contentViewController = host
        popover = pop
        hostingController = host
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
        case .dualPath: width = 118
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
        }
        refreshPopoverAppearance()
        popover?.contentSize = NSSize(width: 340, height: 460)
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.isHighlighted = true
        NSApp.activate(ignoringOtherApps: true)
        startEventMonitor()
    }

    func closePopover() {
        popover?.performClose(nil)
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
        return FlowLensTheme.canvasRouteDirect(colorScheme: scheme)
    }

    private var statusRouteProxy: Color {
        let scheme = model.appearanceMode.preferredColorScheme ?? colorScheme
        return FlowLensTheme.canvasRouteProxy(colorScheme: scheme)
    }

    var body: some View {
        let _ = model.themeRevision
        Group {
            switch style {
            case .iconOnly:
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .compactRates:
                VStack(alignment: .leading, spacing: -1) {
                    Text("↓\(shortRate(model.rateDownBps))")
                    Text("↑\(shortRate(model.rateUpBps))")
                }
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            case .dualPath:
                HStack(spacing: 3) {
                    PathDualSparkline(
                        direct: model.sparklineDirect,
                        proxy: model.sparklineProxy,
                        lineWidth: 0.7,
                        fillOpacity: 0.1
                    )
                    .frame(width: 22, height: 10)
                    VStack(alignment: .leading, spacing: -1) {
                        HStack(spacing: 2) {
                            Text(l10n.t("status.path.direct"))
                                .foregroundStyle(statusRouteDirect)
                            Text("↓\(shortRate(model.directDownBps))")
                        }
                        HStack(spacing: 2) {
                            Text(l10n.t("status.path.proxy"))
                                .foregroundStyle(statusRouteProxy)
                            Text("↓\(shortRate(model.proxyDownBps))")
                        }
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
