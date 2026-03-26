import SwiftUI

// MARK: - Knowledge List View

struct KnowledgeListView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var showEditor = false
    @State private var editingKnowledge: KnowledgeDetail?
    @State private var deletingKnowledge: KnowledgeItem?
    @State private var resettingKnowledge: KnowledgeItem?
    @State private var errorMessage: String?

    private var manager: KnowledgeManager? { dependencies.knowledgeManager }

    private var filteredKnowledge: [KnowledgeItem] {
        guard let manager else { return [] }
        guard !searchText.isEmpty else { return manager.knowledgeBases }
        let q = searchText.lowercased()
        return manager.knowledgeBases.filter {
            $0.name.lowercased().contains(q) ||
            ($0.description?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        Group {
            if let manager {
                content(manager: manager)
            } else {
                unavailableView
            }
        }
    }

    @ViewBuilder
    private func content(manager: KnowledgeManager) -> some View {
        VStack(spacing: 0) {
            searchBar

            if manager.isLoading && manager.knowledgeBases.isEmpty {
                loadingView
            } else if filteredKnowledge.isEmpty {
                emptyView(hasFilter: !searchText.isEmpty)
            } else {
                knowledgeList(manager: manager)
            }
        }
        .task { await manager.fetchAll() }
        .sheet(isPresented: $showEditor) {
            KnowledgeEditorView(
                existing: nil,
                onSave: { detail in
                    Task {
                        do { try await manager.createKnowledge(from: detail) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            )
        }
        .sheet(item: $editingKnowledge) { detail in
            KnowledgeEditorView(
                existing: detail,
                onSave: { updated in
                    Task {
                        do { try await manager.updateKnowledge(updated) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            )
        }
        .confirmationDialog(
            "Delete \"\(deletingKnowledge?.name ?? "")\"?",
            isPresented: .init(
                get: { deletingKnowledge != nil },
                set: { if !$0 { deletingKnowledge = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let k = deletingKnowledge {
                    deletingKnowledge = nil
                    Task {
                        do { try await manager.deleteKnowledge(id: k.id) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) { deletingKnowledge = nil }
        } message: {
            Text("All files in this knowledge base will be removed. This action cannot be undone.")
        }
        .confirmationDialog(
            "Reset \"\(resettingKnowledge?.name ?? "")\"?",
            isPresented: .init(
                get: { resettingKnowledge != nil },
                set: { if !$0 { resettingKnowledge = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                if let k = resettingKnowledge {
                    resettingKnowledge = nil
                    Task {
                        do { try await manager.resetKnowledge(id: k.id) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) { resettingKnowledge = nil }
        } message: {
            Text("All files will be removed from this knowledge base, but the knowledge base itself will remain.")
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.play(.light)
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("New Knowledge Base")
            }
        }
        .onChange(of: manager.error) { _, err in
            if let err { errorMessage = err }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
            TextField("Search knowledge bases…", text: $searchText)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Knowledge List

    @ViewBuilder
    private func knowledgeList(manager: KnowledgeManager) -> some View {
        List {
            ForEach(filteredKnowledge) { kb in
                knowledgeRow(kb, manager: manager)
                    .listRowBackground(theme.background)
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
            }
        }
        .listStyle(.plain)
        .refreshable { await manager.fetchAll() }
    }

    @ViewBuilder
    private func knowledgeRow(_ kb: KnowledgeItem, manager: KnowledgeManager) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "books.vertical")
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.brandPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(kb.name)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let desc = kb.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                    Text(fileCountText(kb.fileCount ?? 0))
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                do {
                    let detail = try await manager.getDetail(id: kb.id)
                    editingKnowledge = detail
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingKnowledge = kb
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                resettingKnowledge = kb
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                Task {
                    do {
                        let detail = try await manager.getDetail(id: kb.id)
                        editingKnowledge = detail
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                resettingKnowledge = kb
            } label: {
                Label("Reset Files", systemImage: "arrow.counterclockwise")
            }
            Divider()
            Button(role: .destructive) {
                deletingKnowledge = kb
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func fileCountText(_ count: Int) -> String {
        switch count {
        case 0: return "No files"
        case 1: return "1 file"
        default: return "\(count) files"
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ProgressView().controlSize(.large).tint(theme.brandPrimary)
            Text("Loading knowledge bases…").scaledFont(size: 15).foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func emptyView(hasFilter: Bool) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: hasFilter ? "magnifyingglass" : "books.vertical")
                .scaledFont(size: 44).foregroundStyle(theme.textTertiary)
            Text(hasFilter ? "No matching knowledge bases" : "No Knowledge Bases Yet")
                .scaledFont(size: 18, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text(hasFilter
                ? "Try a different search term."
                : "Create a knowledge base to give your AI access to documents and files."
            )
            .scaledFont(size: 14).foregroundStyle(theme.textSecondary)
            .multilineTextAlignment(.center).padding(.horizontal, Spacing.xl)
            if !hasFilter {
                Button {
                    Haptics.play(.light)
                    showEditor = true
                } label: {
                    Label("New Knowledge Base", systemImage: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm)
                        .background(theme.brandPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var unavailableView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle").scaledFont(size: 44).foregroundStyle(theme.textTertiary)
            Text("Not Available").scaledFont(size: 18, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text("Connect to a server to manage knowledge bases.")
                .scaledFont(size: 14).foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }
}
