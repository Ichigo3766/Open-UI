import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Share Sheet

private struct ToolShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ToolsListView

/// Workspace tab showing all Tools with search, create, clone, export, delete,
/// and "Import from Link" (URL import).
struct ToolsListView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var editingTool: ToolDetail? = nil
    @State private var deletingTool: WorkspaceToolItem? = nil
    @State private var errorMessage: String? = nil

    // Clone
    @State private var isCloning = false

    // Valves — use item-based sheet to avoid race condition with @State string
    @State private var valvesItem: ValvesSheetItem? = nil

    // Export single
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    // Export all
    @State private var isExportingAll = false

    // Import from URL
    @State private var showImportURLSheet = false
    @State private var importURL = ""
    @State private var isImportingURL = false
    @State private var importedTool: ToolDetail? = nil

    private var manager: ToolsManager? { dependencies.toolsManager }

    // MARK: - Filtered List

    private var filtered: [WorkspaceToolItem] {
        guard let manager else { return [] }
        if searchText.isEmpty { return manager.tools }
        let q = searchText.lowercased()
        return manager.tools.filter {
            $0.name.lowercased().contains(q) ||
            ($0.description ?? "").lowercased().contains(q) ||
            ($0.authorName ?? "").lowercased().contains(q)
        }
    }

    // MARK: - Body

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
    private func content(manager: ToolsManager) -> some View {
        VStack(spacing: 0) {
            searchBar

            if manager.isLoading && manager.tools.isEmpty {
                loadingView
            } else if filtered.isEmpty {
                emptyView(hasFilter: !searchText.isEmpty, manager: manager)
            } else {
                toolList(manager: manager)
            }
        }
        .background(theme.background)
        .task {
            await manager.fetchAll()
            await manager.fetchAllUsers()
        }
        // Create sheet
        .sheet(isPresented: $showCreateSheet) {
            ToolEditorView(
                existingTool: nil,
                onSave: { _ in Task { await manager.fetchAll() } }
            )
        }
        // Edit sheet
        .sheet(item: $editingTool) { detail in
            ToolEditorView(
                existingTool: detail,
                onSave: { _ in Task { await manager.fetchAll() } }
            )
        }
        // Import from URL sheet (shown as sheet so user can cancel)
        .sheet(item: $importedTool) { detail in
            ToolEditorView(
                existingTool: nil,
                prefillDetail: detail,
                onSave: { _ in Task { await manager.fetchAll() } }
            )
        }
        // Share sheet
        .sheet(isPresented: $showShareSheet) {
            ToolShareSheet(items: shareItems)
        }
        // Valves sheet (from context menu long-press → Edit Valves)
        // Uses item-based sheet to guarantee the toolId is atomically set before the sheet appears
        .sheet(item: $valvesItem) { item in
            ValvesSheet(toolId: item.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Import from URL alert
        .alert("Import from URL", isPresented: $showImportURLSheet) {
            TextField("https://…/tool.py or tool URL", text: $importURL)
                .autocorrectionDisabled()
                .autocapitalization(.none)
            if isImportingURL {
                // Can't show a spinner inside alert; just disable
            }
            Button("Import") {
                let url = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return }
                Task { await importFromURL(url: url, manager: manager) }
            }
            .disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                importURL = ""
            }
        } message: {
            Text("Enter a URL to a Python tool file hosted online.")
        }
        // Delete confirmation
        .confirmationDialog(
            "Delete \"\(deletingTool?.name ?? "")\"?",
            isPresented: .init(
                get: { deletingTool != nil },
                set: { if !$0 { deletingTool = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let tool = deletingTool {
                    deletingTool = nil
                    Task { await deleteTool(tool, manager: manager) }
                }
            }
            Button("Cancel", role: .cancel) { deletingTool = nil }
        } message: {
            Text("This action cannot be undone.")
        }
        // Error alert
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Import from URL
                Button {
                    Haptics.play(.light)
                    importURL = ""
                    showImportURLSheet = true
                } label: {
                    Image(systemName: "link.badge.plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("Import Tool from URL")

                // Export All
                Button {
                    Haptics.play(.light)
                    Task { await exportAll(manager: manager) }
                } label: {
                    if isExportingAll {
                        ProgressView().controlSize(.mini).tint(theme.brandPrimary)
                    } else {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }
                .disabled(isExportingAll || manager.tools.isEmpty)
                .accessibilityLabel("Export All Tools")

                // New Tool
                Button {
                    Haptics.play(.light)
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("New Tool")
            }
        }
        .onChange(of: manager.error) { _, err in
            if let err { errorMessage = err }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
            TextField("Search Tools", text: $searchText)
                .scaledFont(size: 15)
                .foregroundStyle(theme.textPrimary)
                .autocorrectionDisabled()
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

    // MARK: - Tool List

    @ViewBuilder
    private func toolList(manager: ToolsManager) -> some View {
        List {
            ForEach(filtered) { tool in
                toolRow(tool, manager: manager)
                    .listRowBackground(theme.background)
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
            }
        }
        .listStyle(.plain)
        .refreshable { await manager.fetchAll() }
    }

    // MARK: - Tool Row

    @ViewBuilder
    private func toolRow(_ tool: WorkspaceToolItem, manager: ToolsManager) -> some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "wrench.and.screwdriver")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }

            // Name + metadata
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(tool.name)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    // Version badge
                    if let version = tool.version, !version.isEmpty {
                        Text("v\(version)")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.brandPrimary.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                } else if let author = tool.authorName, !author.isEmpty {
                    Text("by \(author)")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await openEditor(for: tool, manager: manager) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingTool = tool
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Haptics.play(.light)
                Task { await cloneTool(tool, manager: manager) }
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            .tint(theme.brandPrimary)
        }
        .contextMenu {
            Button {
                Task { await openEditor(for: tool, manager: manager) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                Haptics.play(.light)
                valvesItem = ValvesSheetItem(id: tool.id)
            } label: {
                Label("Edit Valves", systemImage: "slider.horizontal.3")
            }
            Divider()
            Button {
                Haptics.play(.light)
                Task { await cloneTool(tool, manager: manager) }
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            Button {
                Haptics.play(.light)
                Task { await exportSingleTool(tool, manager: manager) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                deletingTool = tool
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(theme.brandPrimary)
            Text("Loading tools…")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Empty View

    @ViewBuilder
    private func emptyView(hasFilter: Bool, manager: ToolsManager) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: hasFilter ? "magnifyingglass" : "wrench.and.screwdriver")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text(hasFilter ? "No Matching Tools" : "No Tools Yet")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text(hasFilter
                 ? "Try a different search term."
                 : "Create a tool or import one from a URL to extend AI capabilities.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            if !hasFilter {
                HStack(spacing: Spacing.md) {
                    Button {
                        Haptics.play(.light)
                        showCreateSheet = true
                    } label: {
                        Label("New Tool", systemImage: "plus")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .background(theme.brandPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.play(.light)
                        importURL = ""
                        showImportURLSheet = true
                    } label: {
                        Label("Import URL", systemImage: "link.badge.plus")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.sm)
                            .background(theme.brandPrimary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    // MARK: - Unavailable View

    private var unavailableView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text("Not Available")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("Connect to a server to manage tools.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func openEditor(for tool: WorkspaceToolItem, manager: ToolsManager) async {
        do {
            let detail = try await manager.getDetail(id: tool.id)
            editingTool = detail
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTool(_ tool: WorkspaceToolItem, manager: ToolsManager) async {
        do {
            try await manager.deleteTool(id: tool.id)
            Haptics.play(.light)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cloneTool(_ tool: WorkspaceToolItem, manager: ToolsManager) async {
        isCloning = true
        do {
            try await manager.cloneTool(id: tool.id)
            Haptics.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCloning = false
    }

    // MARK: - Export Single

    private func exportSingleTool(_ tool: WorkspaceToolItem, manager: ToolsManager) async {
        do {
            let detail = try await manager.getDetail(id: tool.id)
            let payload = detail.toCreatePayload()
            let data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(tool.id).json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export All

    private func exportAll(manager: ToolsManager) async {
        isExportingAll = true
        do {
            let data = try await manager.exportAll()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tools-export.json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isExportingAll = false
    }

    // MARK: - Import from URL

    private func importFromURL(url: String, manager: ToolsManager) async {
        isImportingURL = true
        do {
            if let detail = try await manager.loadFromURL(url: url) {
                importURL = ""
                importedTool = detail
                Haptics.notify(.success)
            } else {
                errorMessage = "Could not parse tool from URL."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isImportingURL = false
    }
}
