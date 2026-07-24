import AppKit
import SwiftUI

/// Owns a dedicated Settings window. More reliable than SwiftUI `Settings` + `showSettingsWindow:`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?

    func show(model: AppModel) {
        MenuBarController.shared.closePopover()
        NSApp.activate(ignoringOtherApps: true)

        let root = AnyView(
            SettingsView()
                .environmentObject(model)
                .environmentObject(LocalizationStore.shared)
                .preferredColorScheme(model.appearanceMode.preferredColorScheme)
        )

        if let window, let hostingController {
            hostingController.rootView = root
            window.title = LocalizationStore.shared.t("settings.title")
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = LocalizationStore.shared.t("settings.title")
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 640, height: 560))
        window.minSize = NSSize(width: 520, height: 420)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.hostingController = hosting
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the window instance for fast reopen; content refreshes on next show.
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        TabView {
            generalPane
                .tabItem { Label(l10n.t("settings.tab.general"), systemImage: "gearshape") }

            appearancePane
                .tabItem { Label(l10n.t("settings.tab.appearance"), systemImage: "paintbrush") }

            protectionPane
                .tabItem { Label(l10n.t("settings.tab.protection"), systemImage: "shield") }

            rankingPane
                .tabItem { Label(l10n.t("settings.tab.ranking"), systemImage: "list.number") }

            updatesPane
                .tabItem { Label(l10n.t("settings.tab.updates"), systemImage: "arrow.down.circle") }

            aboutPane
                .tabItem { Label(l10n.t("settings.tab.about"), systemImage: "info.circle") }
        }
        .frame(minWidth: 520, minHeight: 420)
        .padding(4)
        .id(l10n.revision)
    }

    // MARK: Panes

    private var generalPane: some View {
        Form {
            Section {
                Picker(l10n.t("lang.picker"), selection: Binding(
                    get: { l10n.preference },
                    set: { l10n.setPreference($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(l10n.t(lang.settingsLabelKey)).tag(lang)
                    }
                }
                Text(l10n.t("lang.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: l10n.t("lang.current"), displayNameForResolved))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text(l10n.t("lang.section"))
            }

            Section {
                Picker(l10n.t("menu.menuStyle"), selection: Binding(
                    get: { model.menuBarDisplayStyle },
                    set: {
                        model.menuBarDisplayStyle = $0
                        MenuBarController.shared.refreshStatusItemAppearance()
                    }
                )) {
                    ForEach(AppModel.MenuBarDisplayStyle.allCases) { style in
                        Text(l10n.t(style.localizationKey)).tag(style)
                    }
                }
                Text(l10n.t("menu.style.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(l10n.t("menu.style.section"))
            }

            Section {
                Text(l10n.t("settings.extensionNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(l10n.t("settings.general"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appearancePane: some View {
        Form {
            Section {
                Picker(l10n.t("appearance.picker"), selection: Binding(
                    get: { model.appearanceMode },
                    set: { model.setAppearanceMode($0) }
                )) {
                    ForEach(AppModel.AppearanceMode.allCases) { mode in
                        Label(l10n.t(mode.localizationKey), systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(l10n.t("appearance.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(l10n.t("appearance.section"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var protectionPane: some View {
        Form {
            Section {
                Toggle(l10n.t("settings.filterEnabled"), isOn: Binding(
                    get: { model.filterEnabled },
                    set: { model.setFilterEnabled($0) }
                ))
                Toggle(l10n.t("settings.proxyEnabled"), isOn: Binding(
                    get: { model.proxyEnabled },
                    set: { model.setProxyEnabled($0) }
                ))
                Toggle(l10n.t("settings.alertsEnabled"), isOn: $model.alertsEnabled)
            } header: {
                Text(l10n.t("settings.protection"))
            }

            Section {
                Text(l10n.t("settings.protection.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var rankingPane: some View {
        Form {
            Section {
                HStack {
                    Text(l10n.t("overview.colSpacing"))
                    Spacer()
                    Text("\(Int(model.rankingColumnSpacing)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { model.rankingColumnSpacing },
                        set: { model.rankingColumnSpacing = AppModel.clampRankingColumnSpacing($0) }
                    ),
                    in: AppModel.rankingColumnSpacingRange,
                    step: 1
                )
                Text(l10n.t("overview.colSpacing.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(l10n.t("overview.colSpacing.reset")) {
                    model.resetRankingColumnSpacing()
                }
            } header: {
                Text(l10n.t("overview.ranking"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var updatesPane: some View {
        Form {
            Section {
                HStack {
                    Text(l10n.t("update.version", model.appVersion))
                    Spacer()
                    if model.appUpdateAvailable, let remote = model.appUpdateVersion {
                        Text(l10n.t("update.available") + " · v\(remote)")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.checkForUpdates(manual: true)
                } label: {
                    if model.isCheckingForUpdates {
                        Text(l10n.t("update.checkNow") + "…")
                    } else {
                        Text(l10n.t("update.checkNow"))
                    }
                }
                .disabled(model.isCheckingForUpdates || model.isDownloadingUpdate)

                if model.appUpdateAvailable {
                    Button(l10n.t("update.action")) {
                        model.installOrOpenUpdate()
                    }
                    .disabled(model.isDownloadingUpdate)
                }

                Button(l10n.t("update.openReleases")) {
                    model.openReleasesPage()
                }

                if let key = model.updateCheckMessage {
                    Text(l10n.t("update.status.\(key)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(l10n.t("update.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(l10n.t("update.section"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var aboutPane: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("FlowLens")
                        .font(.title2.weight(.semibold))
                    Text(l10n.t("settings.about.tagline"))
                        .foregroundStyle(.secondary)
                    Text(l10n.t("update.version", model.appVersion))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 4)

                Button(l10n.t("menu.openDashboard")) {
                    model.openDashboard()
                }
                Button(l10n.t("update.openReleases")) {
                    model.openReleasesPage()
                }
            } header: {
                Text(l10n.t("settings.tab.about"))
            }

            Section {
                Text(l10n.t("settings.extensionNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(l10n.t("settings.about.data"))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var displayNameForResolved: String {
        switch l10n.resolvedCode {
        case "zh-Hans": return l10n.t("lang.chinese")
        default: return l10n.t("lang.english")
        }
    }
}
