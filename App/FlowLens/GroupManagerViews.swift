import SwiftUI
import FlowLensCore
import FlowLensRuleEngine

/// Sheet for creating / editing / reordering / deleting app groups.
struct GroupManagerSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String = ""
    @State private var draftRoute: RouteAction = .inherit
    @State private var editingID: UUID? = nil
    @State private var editName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(FlowLensTheme.hairline)
            listBody
            Divider().overlay(FlowLensTheme.hairline)
            createBar
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 440)
        .background(FlowLensTheme.backgroundSecondary)
        .id(l10n.revision)
    }

    private var header: some View {
        HStack {
            Label(l10n.t("groups.manage"), systemImage: "folder.badge.gearshape")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textPrimary)
            Spacer()
            Button(l10n.t("groups.done")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(FlowLensTheme.brandGreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var listBody: some View {
        Group {
            if model.groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                    Text(l10n.t("groups.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.groups) { group in
                        groupRow(group)
                            .listRowBackground(Color.clear)
                    }
                    .onMove(perform: moveGroups)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupRow(_ group: AppGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowLensTheme.textSecondary)
                .padding(.trailing, 2)

            Image(systemName: "folder.fill")
                .foregroundStyle(FlowLensTheme.accentBlue)

                if editingID == group.id {
                TextField(l10n.t("groups.namePlaceholder"), text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit { commitRename(group.id) }
                Button(l10n.t("groups.save")) { commitRename(group.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FlowLensTheme.textPrimary)
                    Text(l10n.t("apps.appsCount", group.memberKeys.count))
                        .font(.system(size: 10))
                        .foregroundStyle(FlowLensTheme.textSecondary)
                }
            }

            Spacer(minLength: 8)

            Menu {
                routeMenuButtons(for: group)
            } label: {
                RouteBadge(label: group.defaultRoute.chipLabel)
                    .frame(width: 88)
            }
            .menuStyle(.borderlessButton)
            .help(l10n.t("groups.defaultRoute"))

            if editingID != group.id {
                Button {
                    editingID = group.id
                    editName = group.name
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlowLensTheme.textSecondary)
                .help(l10n.t("groups.rename"))
            }

            Button(role: .destructive) {
                model.deleteGroup(id: group.id)
                if editingID == group.id { editingID = nil }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlowLensTheme.accentRed)
            .help(l10n.t("groups.delete"))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func routeMenuButtons(for group: AppGroup) -> some View {
        Button(l10n.t("overview.routeDirect")) {
            model.updateGroupDefaults(id: group.id, defaultRoute: .direct)
        }
        Button(l10n.t("overview.routeSystemProxy")) {
            model.updateGroupDefaults(id: group.id, defaultRoute: .systemProxy)
        }
        Button(l10n.t("overview.routeCustomProxy")) {
            let profileID = model.proxyProfiles.first?.id ?? UUID()
            model.updateGroupDefaults(id: group.id, defaultRoute: .proxy(profileID: profileID))
        }
        Button(l10n.t("route.inherit")) {
            model.updateGroupDefaults(id: group.id, defaultRoute: .inherit)
        }
    }

    private var createBar: some View {
        HStack(spacing: 8) {
            TextField(l10n.t("groups.namePlaceholder"), text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createGroup() }

            Picker("", selection: $draftRoute) {
                Text(l10n.t("route.inherit")).tag(RouteAction.inherit)
                Text(l10n.t("overview.routeDirect")).tag(RouteAction.direct)
                Text(l10n.t("overview.routeSystemProxy")).tag(RouteAction.systemProxy)
            }
            .labelsHidden()
            .frame(width: 120)

            Button {
                createGroup()
            } label: {
                Label(l10n.t("groups.create"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(FlowLensTheme.brandGreen)
            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
    }

    private func createGroup() {
        let route: RouteAction = {
            if case .proxy = draftRoute {
                let profileID = model.proxyProfiles.first?.id ?? UUID()
                return .proxy(profileID: profileID)
            }
            return draftRoute
        }()
        if model.createGroup(name: draftName, defaultRoute: route) != nil {
            draftName = ""
            draftRoute = .inherit
        }
    }

    private func commitRename(_ id: UUID) {
        model.renameGroup(id: id, name: editName)
        editingID = nil
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        var ids = model.groups.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.reorderGroups(orderedIDs: ids)
    }
}
