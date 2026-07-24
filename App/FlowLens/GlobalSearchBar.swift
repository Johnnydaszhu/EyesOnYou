import SwiftUI
import FlowLensCore

/// Header search field + dropdown results (apps, sites, rules, groups).
struct GlobalSearchBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var l10n: LocalizationStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .font(.system(size: 13, weight: .medium))
                TextField(l10n.t("search.placeholder"), text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowLensTheme.textPrimary)
                    .focused($focused)
                    .onSubmit {
                        if let first = model.searchResults.first {
                            model.selectSearchHit(first)
                        }
                    }
                    .onChange(of: focused) { isFocused in
                        model.isSearchPresented = isFocused || !model.searchQuery.isEmpty
                    }
                    .onChange(of: model.searchQuery) { _ in
                        model.isSearchPresented = focused || !model.searchQuery.isEmpty
                    }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.clearSearch()
                        focused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(FlowLensTheme.textSecondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(focused ? 0.08 : 0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: focused
                                        ? [FlowLensTheme.accentBlue.opacity(0.7), Color.white.opacity(0.15)]
                                        : [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    )
            }

            if model.isSearchPresented && (!model.searchQuery.isEmpty || !model.searchResults.isEmpty) {
                searchDropdown
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
        .zIndex(50)
        .id(l10n.revision)
    }

    private var searchDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.searchResults.isEmpty {
                Text(l10n.t("search.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(FlowLensTheme.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.searchResults) { hit in
                            Button {
                                model.selectSearchHit(hit)
                                focused = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: icon(for: hit.kind))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(color(for: hit.kind))
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(FlowLensTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(hit.subtitle)
                                            .font(.system(size: 10))
                                            .foregroundStyle(FlowLensTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Text(kindLabel(hit.kind))
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(color(for: hit.kind))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(color(for: hit.kind).opacity(0.15)))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color.white.opacity(0.05))
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .background {
            LiquidGlassBackground(style: .popover, cornerRadius: 12)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        }
        .padding(.top, 4)
    }

    private func icon(for kind: AppModel.SearchHitKind) -> String {
        switch kind {
        case .app: return "app.fill"
        case .site: return "globe"
        case .rule: return "list.bullet.rectangle"
        case .group: return "folder.fill"
        }
    }

    private func color(for kind: AppModel.SearchHitKind) -> Color {
        switch kind {
        case .app: return FlowLensTheme.accentBlue
        case .site: return FlowLensTheme.accentPurple
        case .rule: return FlowLensTheme.accentAmber
        case .group: return FlowLensTheme.gold
        }
    }

    private func kindLabel(_ kind: AppModel.SearchHitKind) -> String {
        switch kind {
        case .app: return l10n.t("search.kind.app")
        case .site: return l10n.t("search.kind.site")
        case .rule: return l10n.t("search.kind.rule")
        case .group: return l10n.t("search.kind.group")
        }
    }
}

/// Star control for favoriting an app.
struct FavoriteButton: View {
    let app: AppIdentityKey
    var size: CGFloat = 12
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let on = model.isFavorite(app)
        Button {
            model.toggleFavorite(app)
        } label: {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(on ? FlowLensTheme.gold : FlowLensTheme.textSecondary.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help(on ? "Unfavorite" : "Favorite")
    }
}
