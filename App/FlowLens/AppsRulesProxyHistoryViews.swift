import SwiftUI
import FlowLensCore
import FlowLensRuleEngine
import FlowLensProxyCore

// MARK: - Apps

struct AppsTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.t("apps.title"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                Spacer()
                Text(l10n.overviewPeriodTitle(model.overviewPeriod))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowLensTheme.accentBlue)
            }
            Text(l10n.t("apps.subtitle"))
                .font(.system(size: 12))
                .foregroundStyle(FlowLensTheme.textSecondary)

            HStack {
                Text(l10n.t("apps.colAppSite")).frame(maxWidth: .infinity, alignment: .leading)
                Text(l10n.t("apps.colDown")).frame(width: 90, alignment: .trailing)
                Text(l10n.t("apps.colUp")).frame(width: 90, alignment: .trailing)
                Text(l10n.t("apps.colRoute")).frame(width: 100)
                Text(l10n.t("apps.colUseProxy")).frame(width: 90)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(FlowLensTheme.textSecondary)
            .padding(.horizontal, 8)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.topApps) { app in
                        appRow(app)
                    }
                }
            }

            if !model.groups.isEmpty {
                Text(l10n.t("apps.groups"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                    .padding(.top, 8)
                ForEach(model.groups) { group in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(FlowLensTheme.accentBlue)
                        Text(group.name)
                        Text(l10n.t("apps.appsCount", group.memberKeys.count))
                            .foregroundStyle(FlowLensTheme.textSecondary)
                        Spacer()
                        RouteBadge(label: group.defaultRoute.chipLabel)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                    .padding(10)
                    .background { LiquidGlassBackground(style: .inset, cornerRadius: 10) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(l10n.revision)
    }

    @ViewBuilder
    private func appRow(_ app: AppTrafficSnapshot) -> some View {
        if app.isBrowser && !app.sites.isEmpty {
            DisclosureGroup {
                VStack(spacing: 4) {
                    ForEach(app.sites) { site in
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11))
                                    .foregroundStyle(FlowLensTheme.accentBlue)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(site.hostname)
                                        .foregroundStyle(FlowLensTheme.textPrimary)
                                    Text(l10n.t("apps.siteHint"))
                                        .font(.system(size: 9))
                                        .foregroundStyle(FlowLensTheme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(ByteFormat.string(for: site.totals.bytesDown))
                                .frame(width: 90, alignment: .trailing)
                            Text(ByteFormat.string(for: site.totals.bytesUp))
                                .frame(width: 90, alignment: .trailing)
                            Text("—")
                                .frame(width: 100)
                                .foregroundStyle(FlowLensTheme.textSecondary)
                            Text("—")
                                .frame(width: 90)
                                .foregroundStyle(FlowLensTheme.textSecondary)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(FlowLensTheme.textPrimary)
                        .padding(.vertical, 4)
                        .padding(.leading, 12)
                    }
                }
                .padding(.bottom, 4)
            } label: {
                appSummaryRow(app, subtitle: l10n.t("apps.websitesCount", app.sites.count))
            }
            .padding(10)
            .background { LiquidGlassBackground(style: .inset, cornerRadius: 10) }
            .tint(FlowLensTheme.textSecondary)
        } else {
            appSummaryRow(app, subtitle: app.app.signingIdentifier)
                .padding(10)
                .background { LiquidGlassBackground(style: .inset, cornerRadius: 10) }
        }
    }

    private func appSummaryRow(_ app: AppTrafficSnapshot, subtitle: String) -> some View {
        HStack {
            HStack(spacing: 8) {
                FavoriteButton(app: app.app, size: 12)
                AppIconView(app: app.app, displayName: app.displayName, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.displayName)
                            .foregroundStyle(FlowLensTheme.textPrimary)
                        if model.isFavorite(app.app) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(FlowLensTheme.gold)
                        }
                        if app.isBrowser {
                            Text(l10n.t("apps.browser"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(FlowLensTheme.accentBlue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(FlowLensTheme.accentBlue.opacity(0.15)))
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ByteFormat.string(for: app.totals.bytesDown))
                .frame(width: 90, alignment: .trailing)
            Text(ByteFormat.string(for: app.totals.bytesUp))
                .frame(width: 90, alignment: .trailing)
            RouteBadge(label: app.route.chipLabel)
                .frame(width: 100)
            Toggle("", isOn: Binding(
                get: { ProxyToggleLogic.isProxyEnabled(app.route) },
                set: { _ in model.toggleAppProxy(app) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(width: 90)
        }
        .font(.system(size: 12))
        .foregroundStyle(FlowLensTheme.textPrimary)
    }
}

// MARK: - Rules

struct RulesTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.t("rules.title"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                Spacer()
                Text(String(format: l10n.t("rules.meta"), model.rules.count, model.policyStore.currentGeneration))
                    .font(.system(size: 11))
                    .foregroundStyle(FlowLensTheme.textSecondary)
            }

            if model.rules.isEmpty {
                Text(l10n.t("rules.empty"))
                    .foregroundStyle(FlowLensTheme.textSecondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.rules) { rule in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(rule.note ?? rule.id.uuidString.prefix(8).description)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(FlowLensTheme.textPrimary)
                                    Spacer()
                                    Text("P\(rule.priority)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(FlowLensTheme.textSecondary)
                                }
                                HStack(spacing: 8) {
                                    labelChip("FW", rule.firewall == .block ? l10n.t("route.blocked") : rule.firewall == .allow ? l10n.t("overview.allowed") : l10n.t("route.inherit"),
                                              color: rule.firewall == .block ? FlowLensTheme.accentRed : FlowLensTheme.accentGreen)
                                    labelChip(l10n.t("overview.colRoute"), l10n.routeChip(rule.route.chipLabel), color: FlowLensTheme.routeColor(rule.route.chipLabel))
                                    Text(destinationLabel(rule))
                                        .font(.system(size: 11))
                                        .foregroundStyle(FlowLensTheme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(12)
                            .background { LiquidGlassBackground(style: .inset, cornerRadius: 10) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(l10n.revision)
    }

    private func labelChip(_ k: String, _ v: String, color: Color) -> some View {
        Text("\(k): \(v)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func destinationLabel(_ rule: NetworkPolicyRule) -> String {
        switch rule.destination {
        case .any: return l10n.t("rules.anyDestination")
        case .hostnameExact(let h): return h
        case .hostnameSuffix(let s): return "*.\(s)"
        case .ip(let a): return a
        case .cidr(let n, let p): return "\(n)/\(p)"
        }
    }
}

// MARK: - Proxy

struct ProxyTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.t("proxy.title"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textPrimary)

            HStack {
                Text(l10n.t("proxy.selective"))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.proxyEnabled },
                    set: { model.setProxyEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(14)
            .background { LiquidGlassBackground(style: .card, cornerRadius: 12) }

            Text(l10n.t("proxy.profiles"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textPrimary)

            ForEach(model.proxyProfiles) { profile in
                HStack {
                    Image(systemName: profile.kind == .socks5 ? "network" : "link")
                        .foregroundStyle(FlowLensTheme.accentPurple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .foregroundStyle(FlowLensTheme.textPrimary)
                        Text("\(profile.kind.rawValue) · \(profile.host):\(profile.port)")
                            .font(.system(size: 11))
                            .foregroundStyle(FlowLensTheme.textSecondary)
                    }
                    Spacer()
                    Text(profile.enabled ? l10n.t("proxy.enabled") : l10n.t("proxy.disabled"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(profile.enabled ? FlowLensTheme.accentGreen : FlowLensTheme.textSecondary)
                }
                .padding(12)
                .background { LiquidGlassBackground(style: .inset, cornerRadius: 10) }
            }

            Text(l10n.t("proxy.failOpen"))
                .font(.system(size: 11))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(l10n.revision)
    }
}

// MARK: - History

struct HistoryTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.t("history.title"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                Spacer()
                Text(l10n.t("time.global") + " · " + l10n.overviewPeriodTitle(model.overviewPeriod))
                    .font(.system(size: 11))
                    .foregroundStyle(FlowLensTheme.textSecondary)
            }

            HStack {
                Text(l10n.t("history.colApp")).frame(maxWidth: .infinity, alignment: .leading)
                Text(l10n.t("history.colDown")).frame(width: 100, alignment: .trailing)
                Text(l10n.t("history.colUp")).frame(width: 100, alignment: .trailing)
                Text(l10n.t("history.colTotal")).frame(width: 100, alignment: .trailing)
                Text(l10n.t("history.colFlows")).frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(FlowLensTheme.textSecondary)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.historyRows) { row in
                        HStack {
                            HStack(spacing: 8) {
                                AppIconView(app: row.app, displayName: row.displayName, size: 20)
                                Text(row.displayName)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(ByteFormat.string(for: row.totals.bytesDown))
                                .frame(width: 100, alignment: .trailing)
                            Text(ByteFormat.string(for: row.totals.bytesUp))
                                .frame(width: 100, alignment: .trailing)
                            Text(ByteFormat.string(for: row.totals.totalBytes))
                                .frame(width: 100, alignment: .trailing)
                            Text("\(row.totals.flowsOpened)")
                                .frame(width: 70, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(FlowLensTheme.textPrimary)
                        .padding(10)
                        .background { LiquidGlassBackground(style: .inset, cornerRadius: 10) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(l10n.revision)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore

    var body: some View {
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
        .frame(width: 480, height: 420)
        .id(l10n.revision)
    }

    private var displayNameForResolved: String {
        switch l10n.resolvedCode {
        case "zh-Hans": return l10n.t("lang.chinese")
        default: return l10n.t("lang.english")
        }
    }
}
