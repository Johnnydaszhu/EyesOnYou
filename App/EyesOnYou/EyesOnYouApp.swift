import SwiftUI
import AppKit

@main
struct EyesOnYouApp: App {
    @StateObject private var appModel = AppModel()
    @ObservedObject private var l10n = LocalizationStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(AppBrand.displayName) {
            MainDashboardView()
                .environmentObject(appModel)
                .environmentObject(l10n)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(appModel.appearanceMode.preferredColorScheme)
                .background(WindowTitleBarHider())
                .onAppear {
                    // Ensure menu bar is bound to this model instance.
                    AppModel.applyAppearance(appModel.appearanceMode)
                    appDelegate.bind(model: appModel)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(l10n.t("settings.title")) {
                    appModel.openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandMenu(AppBrand.displayName) {
                Button(l10n.t("menu.openDashboard")) {
                    appModel.openDashboard()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Button(l10n.t("menuBar.togglePanel")) {
                    MenuBarController.shared.togglePopover()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

/// Hides the native title string so branding lives only in the content chrome.
private struct WindowTitleBarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.apply(to: nsView.window)
        }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var boundModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep app in Dock + menu bar. Status item is created as soon as model binds.
        NSApp.setActivationPolicy(.regular)
    }

    /// Called when SwiftUI has the real AppModel (StateObject).
    func bind(model: AppModel) {
        boundModel = model
        MenuBarController.shared.install(model: model)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            boundModel?.openDashboard()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive for menu-bar quick panel after closing the dashboard window.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush the buckets recorded since the last periodic write, so quitting does
        // not discard the final interval of real traffic.
        boundModel?.persistBeforeTermination()
    }

    /// Also persist when the machine is going down — `applicationWillTerminate` is not
    /// guaranteed during logout or restart.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        boundModel?.persistBeforeTermination()
        return .terminateNow
    }
}
