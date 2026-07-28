import AppKit
import SwiftUI
import EyesOnYouCore

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
        window.setContentSize(NSSize(width: 760, height: 640))
        window.minSize = NSSize(width: 640, height: 480)
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

    func refreshTitle() {
        window?.title = LocalizationStore.shared.t("settings.title")
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @State private var selectedPane: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPane) {
                ForEach(Pane.allCases) { pane in
                    Label(l10n.t(pane.titleKey), systemImage: pane.systemImage)
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(l10n.t("settings.title"))
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            selectedPaneView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: l10n.revision) { _ in
            SettingsWindowController.shared.refreshTitle()
        }
    }

    private enum Pane: CaseIterable, Hashable, Identifiable {
        case general
        case appearance
        case protection
        case ranking
        case updates
        case about

        var id: Self { self }

        var titleKey: String {
            switch self {
            case .general: return "settings.tab.general"
            case .appearance: return "settings.tab.appearance"
            case .protection: return "settings.tab.protection"
            case .ranking: return "settings.tab.ranking"
            case .updates: return "settings.tab.updates"
            case .about: return "settings.tab.about"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintbrush"
            case .protection: return "shield"
            case .ranking: return "list.number"
            case .updates: return "arrow.down.circle"
            case .about: return "info.circle"
            }
        }
    }

    @ViewBuilder
    private var selectedPaneView: some View {
        switch selectedPane ?? .general {
        case .general: generalPane
        case .appearance: appearancePane
        case .protection: protectionPane
        case .ranking: rankingPane
        case .updates: updatesPane
        case .about: aboutPane
        }
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
                Toggle(l10n.t("settings.launchAtLogin"), isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLoginEnabled($0) }
                ))
                Text(l10n.t("settings.launchAtLogin.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.launchAtLoginNeedsApproval {
                    Text(l10n.t("settings.launchAtLogin.approval"))
                        .font(.caption)
                        .foregroundStyle(EyesOnYouTheme.accentAmber)
                }
                if let error = model.launchAtLoginError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(EyesOnYouTheme.accentRed)
                        .textSelection(.enabled)
                }
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

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(ColorThemeTemplate.allCases) { template in
                        ThemeTemplateCard(
                            template: template,
                            isSelected: model.colorThemeTemplate == template
                        ) {
                            model.setColorThemeTemplate(template)
                        }
                    }
                }
                .padding(.vertical, 4)

                Text(l10n.t(model.colorThemeTemplate == .mono ? "theme.mono.hint" : "theme.template.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(l10n.t("theme.section"))
            }

            Section {
                if model.colorThemeTemplate == .mono {
                    ThemeColorRow(
                        title: l10n.t("theme.color.proxy"),
                        subtitle: l10n.t("theme.color.proxy.monoHint"),
                        color: Binding(
                            get: { model.themeAccents.proxy.color },
                            set: { model.updateThemeAccent(\.proxy, to: ThemeRGB(color: $0)) }
                        )
                    )
                } else {
                    ThemeColorRow(
                        title: l10n.t("theme.color.primary"),
                        subtitle: l10n.t("theme.color.primary.hint"),
                        color: Binding(
                            get: { model.themeAccents.accent.color },
                            set: { model.updatePrimaryAccent(ThemeRGB(color: $0)) }
                        )
                    )
                    ThemeColorRow(
                        title: l10n.t("theme.color.secondary"),
                        subtitle: l10n.t("theme.color.secondary.hint"),
                        color: Binding(
                            get: { model.themeAccents.secondary.color },
                            set: { model.updateThemeAccent(\.secondary, to: ThemeRGB(color: $0)) }
                        )
                    )
                    ThemeColorRow(
                        title: l10n.t("theme.color.tertiary"),
                        subtitle: l10n.t("theme.color.tertiary.hint"),
                        color: Binding(
                            get: { model.themeAccents.tertiary.color },
                            set: { model.updateThemeAccent(\.tertiary, to: ThemeRGB(color: $0)) }
                        )
                    )
                    ThemeColorRow(
                        title: l10n.t("theme.color.proxy"),
                        subtitle: l10n.t("theme.color.proxy.hint"),
                        color: Binding(
                            get: { model.themeAccents.proxy.color },
                            set: { model.updateThemeAccent(\.proxy, to: ThemeRGB(color: $0)) }
                        )
                    )
                    ThemeColorRow(
                        title: l10n.t("theme.color.danger"),
                        subtitle: l10n.t("theme.color.danger.hint"),
                        color: Binding(
                            get: { model.themeAccents.danger.color },
                            set: { model.updateThemeAccent(\.danger, to: ThemeRGB(color: $0)) }
                        )
                    )
                }

                HStack {
                    Spacer()
                    Button(l10n.t("theme.reset")) {
                        model.resetThemeAccentsToTemplate()
                    }
                }
            } header: {
                Text(l10n.t("theme.customize.section"))
            } footer: {
                Text(l10n.t("theme.customize.footer"))
                    .font(.caption)
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
                Toggle(l10n.t("settings.browserTabs"), isOn: $model.tracksBrowserTabs)
                Text(l10n.t("settings.browserTabs.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Trust can be revoked in System Settings without returning here.
                if model.tracksBrowserTabs, !model.isBrowserTabTrackingAuthorized {
                    Label(l10n.t("settings.browserTabs.permission"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                gigabyteField("settings.alerts.dailyTotal", bytes: Binding(
                    get: { model.alertThresholds.dailyTotalBytes },
                    set: { model.alertThresholds.dailyTotalBytes = $0 }
                ))
                gigabyteField("settings.alerts.dailyApp", bytes: Binding(
                    get: { model.alertThresholds.dailyAppBytes },
                    set: { model.alertThresholds.dailyAppBytes = $0 }
                ))
                gigabyteField("settings.alerts.cumulativeApp", bytes: Binding(
                    get: { model.alertThresholds.cumulativeAppBytes },
                    set: { model.alertThresholds.cumulativeAppBytes = $0 }
                ))
                megabyteField("settings.alerts.burst", bytes: Binding(
                    get: { model.alertThresholds.burstBytes },
                    set: { model.alertThresholds.burstBytes = $0 }
                ))
                Toggle(l10n.t("settings.alerts.newApp"), isOn: Binding(
                    get: { model.alertThresholds.notifyOnNewApp },
                    set: { model.alertThresholds.notifyOnNewApp = $0 }
                ))
                Text(l10n.t("settings.alerts.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.alertsEnabled, !model.alertCenter.notificationsAuthorized {
                    Label(l10n.t("settings.alerts.permission"), systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(l10n.t("settings.alerts.header"))
            }
            .disabled(!model.alertsEnabled)

            Section {
                Text(l10n.t("settings.protection.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Thresholds are stored in bytes but edited in GB — a text field keeps `0`
    /// (meaning "off") expressible, which a stepper would hide.
    private func gigabyteField(_ key: String, bytes: Binding<UInt64>) -> some View {
        unitField(key, bytes: bytes, unit: TrafficAlertThresholds.gigabyte)
    }

    private func megabyteField(_ key: String, bytes: Binding<UInt64>) -> some View {
        unitField(key, bytes: bytes, unit: TrafficAlertThresholds.megabyte)
    }

    private func unitField(_ key: String, bytes: Binding<UInt64>, unit: UInt64) -> some View {
        let text = Binding<String>(
            get: {
                let value = Double(bytes.wrappedValue) / Double(unit)
                return value == value.rounded()
                    ? String(Int(value))
                    : String(format: "%.1f", value)
            },
            set: { raw in
                let cleaned = raw.replacingOccurrences(of: ",", with: ".")
                guard let value = Double(cleaned), value >= 0 else { return }
                bytes.wrappedValue = UInt64(value * Double(unit))
            }
        )
        return HStack {
            Text(l10n.t(key))
            Spacer()
            TextField("", text: text)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
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
                HStack(alignment: .center, spacing: 14) {
                    AppBrand.logo
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppBrand.displayName)
                            .font(.title2.weight(.semibold))
                        Text(l10n.t("settings.about.tagline"))
                            .foregroundStyle(.secondary)
                        Text(l10n.t("update.version", model.appVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
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
        l10n.displayName(forCode: l10n.resolvedCode)
    }
}

// MARK: - Theme settings controls

private struct ThemeTemplateCard: View {
    let template: ColorThemeTemplate
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(template.previewSwatches.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(color)
                            .frame(width: 12, height: 12)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: template.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(l10n.t(template.localizationKey))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.08 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? EyesOnYouTheme.accentBlue.opacity(0.85) : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 1.4 : 0.8
                            )
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(l10n.t(template.localizationKey))
    }
}

private struct ThemeColorRow: View {
    let title: String
    let subtitle: String
    @Binding var color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 44)
        }
    }
}
