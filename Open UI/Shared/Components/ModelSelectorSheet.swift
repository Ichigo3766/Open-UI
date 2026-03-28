import SwiftUI

// MARK: - Model Selector Sheet

/// A clean, native-feel bottom-sheet model picker.
///
/// Design philosophy: show as many models as possible at a glance.
/// Compact rows, no redundant badges, and a simple checkmark — like
/// Apple's own font or timezone pickers.
///
/// Performance for 50+ models:
/// - Parallel avatar prefetch (6 concurrent) fires on appear.
/// - Debounced search (120 ms) avoids work on every keystroke.
/// - `EquatableModelRow` skips unchanged rows during scroll.
/// - `LazyVStack` only instantiates visible rows.
struct ModelSelectorSheet: View {
    let models: [AIModel]
    let selectedModelId: String?
    let serverBaseURL: String
    let authToken: String?
    let isAdmin: Bool
    let pinnedModelIds: [String]
    let onEdit: ((AIModel) -> Void)?
    let onTogglePin: ((String) -> Void)?
    let onSelect: (AIModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var selectedTag: String? = nil
    @State private var selectedConnection: String? = nil
    @State private var filteredModels: [AIModel] = []
    @State private var filterTask: Task<Void, Never>? = nil
    @FocusState private var searchFocused: Bool

    // MARK: - Filter Data

    private var allTags: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in models {
            for tag in model.tags {
                let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, seen.insert(t).inserted { result.append(t) }
            }
        }
        return result.sorted()
    }

    private var allConnections: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in models {
            if let ct = model.connectionType?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ct.isEmpty, seen.insert(ct).inserted {
                result.append(ct)
            }
        }
        return result.sorted()
    }

    private var hasFilters: Bool { !allTags.isEmpty || !allConnections.isEmpty }

    private func applyFilters() {
        var result = models
        if let tag = selectedTag { result = result.filter { $0.tags.contains(tag) } }
        if let conn = selectedConnection { result = result.filter { $0.connectionType == conn } }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || $0.shortName.localizedCaseInsensitiveContains(q)
                || ($0.description?.localizedCaseInsensitiveContains(q) ?? false)
            }
        }
        filteredModels = result
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            applyFilters()
        }
    }

    private func prefetchAvatars() {
        // Prefetch all model avatar URLs in the background.
        // Each URL hits the server endpoint which returns the custom avatar or
        // the default favicon. Results are stored in ImageCacheService so
        // subsequent opens of the picker are instant with zero network requests.
        let urls = models.compactMap { $0.resolveAvatarURL(baseURL: serverBaseURL) }
        guard !urls.isEmpty else { return }
        Task(priority: .background) {
            await ImageCacheService.shared.prefetchWithAuth(urls: urls, authToken: authToken)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, hasFilters ? 0 : 8)
            if hasFilters {
                filterPillsRow
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            Divider()
                .background(theme.divider.opacity(0.6))
            modelList
        }
        .background(theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
        .presentationBackground(theme.background)
        .onAppear {
            filteredModels = models
            prefetchAvatars()
        }
        .onChange(of: searchText) { scheduleFilter() }
        .onChange(of: selectedTag) { applyFilters() }
        .onChange(of: selectedConnection) { applyFilters() }
        .onChange(of: models) { applyFilters(); prefetchAvatars() }
    }

    // MARK: - Sheet Header

    private var sheetHeader: some View {
        ZStack {
            // Drag handle
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(theme.textTertiary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .center)

            // Title + count
            HStack(spacing: 6) {
                Text("Models")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                if !models.isEmpty {
                    Text("\(filteredModels.count)")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(theme.surfaceContainer)
                        )
                        .animation(.none, value: filteredModels.count)
                }
            }
            .padding(.top, 8)

            // Done button
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.trailing, 20)
                    .padding(.top, 8)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)

            TextField("Search\u{2026}", text: $searchText)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .tint(theme.brandPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($searchFocused)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.12), value: searchText.isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceContainer)
        )
    }

    // MARK: - Filter Pills

    private var filterPillsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterPill(label: "All",
                           isSelected: selectedTag == nil && selectedConnection == nil,
                           systemIcon: nil) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTag = nil; selectedConnection = nil
                    }
                    Haptics.play(.light)
                }

                if !allConnections.isEmpty {
                    ForEach(allConnections, id: \.self) { conn in
                        filterPill(label: conn.capitalized,
                                   isSelected: selectedConnection == conn && selectedTag == nil,
                                   systemIcon: connectionIcon(conn)) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedConnection = (selectedConnection == conn) ? nil : conn
                                selectedTag = nil
                            }
                            Haptics.play(.light)
                        }
                    }
                }

                if !allTags.isEmpty {
                    ForEach(allTags, id: \.self) { tag in
                        filterPill(label: tag,
                                   isSelected: selectedTag == tag && selectedConnection == nil,
                                   systemIcon: "number") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTag = (selectedTag == tag) ? nil : tag
                                selectedConnection = nil
                            }
                            Haptics.play(.light)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func connectionIcon(_ conn: String) -> String {
        switch conn.lowercased() {
        case "external": return "link"
        case "internal": return "server.rack"
        default: return "cpu"
        }
    }

    private func filterPill(label: String, isSelected: Bool, systemIcon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = systemIcon {
                    Image(systemName: icon)
                        .scaledFont(size: 10, weight: .medium)
                }
                Text(label)
                    .scaledFont(size: 12, weight: isSelected ? .semibold : .regular)
            }
            .foregroundStyle(isSelected ? theme.brandPrimary : theme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected
                          ? theme.brandPrimary.opacity(0.12)
                          : theme.surfaceContainer)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? theme.brandPrimary.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section Computation

    /// The currently selected model (if it passes filters).
    private var currentModel: AIModel? {
        guard let id = selectedModelId else { return nil }
        return filteredModels.first { $0.id == id }
    }

    /// Pinned models that pass filters, excluding the currently selected model.
    private var pinnedModels: [AIModel] {
        let pinnedSet = Set(pinnedModelIds)
        return filteredModels.filter { pinnedSet.contains($0.id) && $0.id != selectedModelId }
    }

    /// All remaining models (not selected, not pinned) that pass filters.
    private var remainingModels: [AIModel] {
        let pinnedSet = Set(pinnedModelIds)
        return filteredModels.filter { $0.id != selectedModelId && !pinnedSet.contains($0.id) }
    }

    // MARK: - Model List

    @ViewBuilder
    private var modelList: some View {
        if models.isEmpty {
            loadingState
        } else if filteredModels.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // ── CURRENTLY SELECTED ──
                    if let current = currentModel {
                        sectionHeader("Currently Selected")
                        modelRow(current, isLast: pinnedModels.isEmpty && remainingModels.isEmpty)
                    }

                    // ── PINNED ──
                    if !pinnedModels.isEmpty {
                        sectionHeader("Pinned")
                        ForEach(Array(pinnedModels.enumerated()), id: \.element.id) { idx, model in
                            modelRow(model, isLast: idx == pinnedModels.count - 1 && remainingModels.isEmpty)
                        }
                    }

                    // ── ALL MODELS ──
                    if !remainingModels.isEmpty {
                        sectionHeader("All Models")
                        ForEach(Array(remainingModels.enumerated()), id: \.element.id) { idx, model in
                            modelRow(model, isLast: idx == remainingModels.count - 1)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    // MARK: - Model Row (with pin button)

    private func modelRow(_ model: AIModel, isLast: Bool) -> some View {
        let isPinned = pinnedModelIds.contains(model.id)
        let isSelected = model.id == selectedModelId

        return VStack(spacing: 0) {
            Button {
                Haptics.play(.light)
                onSelect(model)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    ModelAvatar(
                        size: 36,
                        imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                        label: model.shortName,
                        authToken: authToken
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        modelSubtitle(model)
                    }

                    Spacer(minLength: 0)

                    // Pin/unpin button
                    if let onTogglePin {
                        Button {
                            Haptics.play(.light)
                            onTogglePin(model.id)
                        } label: {
                            Image(systemName: isPinned ? "star.fill" : "star")
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(isPinned ? .yellow : theme.textTertiary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Admin edit button
                    if isAdmin, let onEdit {
                        Button {
                            Haptics.play(.light)
                            onEdit(model)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                                .frame(width: 32, height: 32)
                                .background(theme.surfaceContainer.opacity(0.7))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Checkmark for selected model
                    if isSelected {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(ModelRowButtonStyle())

            if !isLast {
                Divider()
                    .background(theme.divider.opacity(0.5))
                    .padding(.leading, 16 + 36 + 12)
            }
        }
    }

    @ViewBuilder
    private func modelSubtitle(_ model: AIModel) -> some View {
        let desc = model.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contextStr: String? = {
            guard let ctx = model.contextLength, ctx > 0 else { return nil }
            if ctx >= 1_000_000 { return "\(ctx / 1_000_000)M ctx" }
            if ctx >= 1_000 { return "\(ctx / 1_000)K ctx" }
            return "\(ctx) ctx"
        }()

        if !desc.isEmpty {
            Text(desc)
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        } else if let ctx = contextStr {
            Text(ctx)
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(theme.brandPrimary)
            Text("Loading models\u{2026}")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 28)
                .foregroundStyle(theme.textTertiary)
            Text(searchText.isEmpty ? "No models" : "No results for \u{201C}\(searchText)\u{201D}")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            if selectedTag != nil || selectedConnection != nil {
                Button {
                    withAnimation { selectedTag = nil; selectedConnection = nil }
                } label: {
                    Text("Clear filters")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.horizontal, 32)
    }
}

// MARK: - Equatable Model Row

/// Each row is `Equatable` so SwiftUI can skip re-rendering unchanged
/// rows during scroll — critical for smooth 50+ model lists.
private struct EquatableModelRow: View, Equatable {
    let model: AIModel
    let isSelected: Bool
    let isLast: Bool
    let serverBaseURL: String
    let authToken: String?
    let isAdmin: Bool
    let onEdit: (() -> Void)?
    let onTap: () -> Void

    static func == (lhs: EquatableModelRow, rhs: EquatableModelRow) -> Bool {
        lhs.model.id == rhs.model.id
            && lhs.model.name == rhs.model.name
            && lhs.isSelected == rhs.isSelected
            && lhs.isLast == rhs.isLast
            && lhs.serverBaseURL == rhs.serverBaseURL
            && lhs.isAdmin == rhs.isAdmin
    }

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            rowContent
                .contentShape(Rectangle())
        }
        .buttonStyle(ModelRowButtonStyle())

        if !isLast {
            Divider()
                .background(theme.divider.opacity(0.5))
                .padding(.leading, 16 + 36 + 12) // inset past avatar
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            // Avatar — 36pt, no glow ring
            ModelAvatar(
                size: 36,
                imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                label: model.shortName,
                authToken: authToken
            )

            // Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                subtitleView
            }

            Spacer(minLength: 0)

            // Admin edit button — gear icon, only visible to admins
            if isAdmin, let onEdit {
                Button {
                    Haptics.play(.light)
                    onEdit()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(theme.surfaceContainer.opacity(0.7))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Simple checkmark — minimal, Apple-style
            if isSelected {
                Image(systemName: "checkmark")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var subtitleView: some View {
        let desc = model.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let contextStr: String? = {
            guard let ctx = model.contextLength, ctx > 0 else { return nil }
            if ctx >= 1_000_000 { return "\(ctx / 1_000_000)M ctx" }
            if ctx >= 1_000 { return "\(ctx / 1_000)K ctx" }
            return "\(ctx) ctx"
        }()

        // Priority: description → context length → nothing
        if !desc.isEmpty {
            Text(desc)
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)
        } else if let ctx = contextStr {
            Text(ctx)
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
        }
        // else: no subtitle line — keeps row compact when there's nothing to say
    }
}

// MARK: - Row Button Style

private struct ModelRowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? theme.surfaceContainer.opacity(0.7)
                    : Color.clear
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
