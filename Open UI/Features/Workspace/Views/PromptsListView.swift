import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Share Sheet (UIActivityViewController wrapper)

private struct PromptShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Document Picker

private struct PromptDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Parsed Import Data

private struct ImportedPromptData: Identifiable {
    let id = UUID()
    var name: String
    var command: String
    var content: String
    var tags: [String]
}

// MARK: - Prompts List View

struct PromptsListView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var showEditor = false
    @State private var editingPrompt: PromptDetail?
    @State private var deletingPrompt: PromptItem?
    @State private var errorMessage: String?

    // Clone
    @State private var isCloning = false

    // Export single
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    // Export all
    @State private var isExportingAll = false

    // Import
    @State private var showImportPicker = false
    @State private var importedPrompt: ImportedPromptData? = nil
    @State private var showImportEditor = false
    @State private var showBatchImportConfirm = false
    @State private var batchImportPrompts: [ImportedPromptData] = []
    @State private var isBatchImporting = false

    private var manager: PromptManager? { dependencies.promptManager }

    private var filteredPrompts: [PromptItem] {
        guard let manager else { return [] }
        var list = manager.prompts
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.command.lowercased().contains(q)
            }
        }
        if let tag = selectedTag {
            list = list.filter { $0.tags.contains(tag) }
        }
        return list
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
    private func content(manager: PromptManager) -> some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar

            // Tag filter pills
            if !manager.allTags.isEmpty {
                tagFilterBar(tags: manager.allTags)
            }

            if manager.isLoading && manager.prompts.isEmpty {
                loadingView
            } else if filteredPrompts.isEmpty {
                emptyView(hasFilter: !searchText.isEmpty || selectedTag != nil)
            } else {
                promptList(manager: manager)
            }
        }
        .background(theme.background)
        .task {
            await manager.fetchPrompts()
            await manager.fetchTags()
        }
        // Create sheet
        .sheet(isPresented: $showEditor) {
            PromptEditorView(
                existing: nil,
                onSave: { detail, commit in
                    Task {
                        do {
                            try await manager.createPrompt(from: detail, commitMessage: commit ?? "")
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            )
        }
        // Edit sheet
        .sheet(item: $editingPrompt) { detail in
            PromptEditorView(
                existing: detail,
                onSave: { updated, commit in
                    Task {
                        do {
                            try await manager.updatePrompt(updated, commitMessage: commit ?? "")
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            )
        }
        // Import prefill editor (single prompt)
        .sheet(isPresented: $showImportEditor) {
            if let imp = importedPrompt {
                PromptEditorView(
                    existing: PromptDetail(
                        command: imp.command,
                        name: imp.name,
                        content: imp.content,
                        isActive: true,
                        tags: imp.tags
                    ),
                    onSave: { detail, commit in
                        Task {
                            // Always create (never update) for imported prompts
                            let newDetail = PromptDetail(
                                command: detail.command,
                                name: detail.name,
                                content: detail.content,
                                isActive: detail.isActive,
                                tags: detail.tags,
                                accessGrants: []
                            )
                            do {
                                try await manager.createPrompt(from: newDetail, commitMessage: commit ?? "Imported")
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                )
            }
        }
        // Share sheet (export)
        .sheet(isPresented: $showShareSheet) {
            PromptShareSheet(items: shareItems)
        }
        // Document picker for import
        .sheet(isPresented: $showImportPicker) {
            PromptDocumentPicker(types: [.plainText, .json]) { url in
                handleImportedFile(url: url, manager: manager)
            }
        }
        // Delete confirmation
        .confirmationDialog(
            "Delete \"\(deletingPrompt?.name ?? "")\"?",
            isPresented: .init(
                get: { deletingPrompt != nil },
                set: { if !$0 { deletingPrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let p = deletingPrompt {
                    deletingPrompt = nil
                    Task {
                        do { try await manager.deletePrompt(id: p.id) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) { deletingPrompt = nil }
        } message: {
            Text("This action cannot be undone.")
        }
        // Batch import confirmation
        .confirmationDialog(
            "Import \(batchImportPrompts.count) Prompts?",
            isPresented: $showBatchImportConfirm,
            titleVisibility: .visible
        ) {
            Button("Import All") {
                Task { await batchImport(prompts: batchImportPrompts, manager: manager) }
            }
            Button("Cancel", role: .cancel) { batchImportPrompts = [] }
        } message: {
            Text("This will create \(batchImportPrompts.count) new prompts on the server.")
        }
        // Error alert
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Import button
                Button {
                    Haptics.play(.light)
                    showImportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("Import Prompt")

                // Export All button
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
                .disabled(isExportingAll || manager.prompts.isEmpty)
                .accessibilityLabel("Export All Prompts")

                // New Prompt button
                Button {
                    Haptics.play(.light)
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("New Prompt")
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
            TextField("Search prompts…", text: $searchText)
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

    // MARK: - Tag Filter Bar

    @ViewBuilder
    private func tagFilterBar(tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                tagPill(label: "All", isSelected: selectedTag == nil) {
                    selectedTag = nil
                }
                ForEach(tags, id: \.self) { tag in
                    tagPill(label: tag, isSelected: selectedTag == tag) {
                        selectedTag = selectedTag == tag ? nil : tag
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)
        }
    }

    @ViewBuilder
    private func tagPill(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(isSelected ? .white : theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? theme.brandPrimary : theme.surfaceContainer)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Prompt List

    @ViewBuilder
    private func promptList(manager: PromptManager) -> some View {
        List {
            ForEach(filteredPrompts) { prompt in
                promptRow(prompt, manager: manager)
                    .listRowBackground(theme.background)
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
            }
        }
        .listStyle(.plain)
        .refreshable { await manager.fetchPrompts() }
    }

    @ViewBuilder
    private func promptRow(_ prompt: PromptItem, manager: PromptManager) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Spacing.xs) {
                    Text(prompt.name)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if !prompt.isActive {
                        Text("INACTIVE")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.surfaceContainer)
                            .clipShape(Capsule())
                    }
                }
                Text("/\(prompt.command)")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.brandPrimary)
                    .lineLimit(1)
                if !prompt.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(prompt.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .scaledFont(size: 11)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.surfaceContainer.opacity(0.8))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            Spacer()

            // Active toggle
            Button {
                Haptics.play(.light)
                Task {
                    do { try await manager.togglePrompt(id: prompt.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            } label: {
                Image(systemName: prompt.isActive ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 20)
                    .foregroundStyle(prompt.isActive ? theme.brandPrimary : theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                do {
                    let detail = try await manager.getPromptDetail(id: prompt.id)
                    editingPrompt = detail
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingPrompt = prompt
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Haptics.play(.light)
                Task {
                    do { try await manager.togglePrompt(id: prompt.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            } label: {
                Label(
                    prompt.isActive ? "Deactivate" : "Activate",
                    systemImage: prompt.isActive ? "pause.circle" : "play.circle"
                )
            }
            .tint(prompt.isActive ? .orange : theme.brandPrimary)
        }
        .contextMenu {
            Button {
                Task {
                    do {
                        let detail = try await manager.getPromptDetail(id: prompt.id)
                        editingPrompt = detail
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                Haptics.play(.light)
                Task {
                    do { try await manager.togglePrompt(id: prompt.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            } label: {
                Label(
                    prompt.isActive ? "Deactivate" : "Activate",
                    systemImage: prompt.isActive ? "pause.circle" : "play.circle"
                )
            }
            Divider()
            Button {
                Haptics.play(.light)
                Task { await clonePrompt(prompt, manager: manager) }
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            Button {
                Haptics.play(.light)
                Task { await exportSinglePrompt(prompt, manager: manager) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                deletingPrompt = prompt
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(theme.brandPrimary)
            Text("Loading prompts…")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    @ViewBuilder
    private func emptyView(hasFilter: Bool) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: hasFilter ? "magnifyingglass" : "text.bubble")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text(hasFilter ? "No matching prompts" : "No Prompts Yet")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text(hasFilter
                ? "Try a different search or tag filter."
                : "Create a prompt to quickly insert text snippets into your chats."
            )
            .scaledFont(size: 14)
            .foregroundStyle(theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xl)
            if !hasFilter {
                Button {
                    Haptics.play(.light)
                    showEditor = true
                } label: {
                    Label("New Prompt", systemImage: "plus")
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
            Image(systemName: "exclamationmark.triangle")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text("Not Available")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("Connect to a server to manage prompts.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Clone

    private func clonePrompt(_ prompt: PromptItem, manager: PromptManager) async {
        isCloning = true
        do {
            try await manager.clonePrompt(id: prompt.id)
            Haptics.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCloning = false
    }

    // MARK: - Export Single

    private func exportSinglePrompt(_ prompt: PromptItem, manager: PromptManager) async {
        do {
            let detail = try await manager.getPromptDetail(id: prompt.id)
            let payload = detail.toCreatePayload()
            let data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prompt.command).json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export All

    private func exportAll(manager: PromptManager) async {
        isExportingAll = true
        do {
            let data = try await manager.exportAll()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("prompts-export.json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isExportingAll = false
    }

    // MARK: - Import

    private func handleImportedFile(url: URL, manager: PromptManager) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read file."
            return
        }
        let filename = url.lastPathComponent.lowercased()

        if filename.hasSuffix(".md") {
            if let parsed = parseMarkdownPrompt(data: data, filename: url.deletingPathExtension().lastPathComponent) {
                importedPrompt = parsed
                showImportEditor = true
            } else {
                errorMessage = "Could not parse prompt from Markdown file."
            }
        } else {
            if let jsonObj = try? JSONSerialization.jsonObject(with: data) {
                if let array = jsonObj as? [[String: Any]] {
                    let parsed = array.compactMap { parseJSONPrompt($0) }
                    if parsed.isEmpty {
                        errorMessage = "No valid prompts found in JSON array."
                    } else if parsed.count == 1 {
                        importedPrompt = parsed[0]
                        showImportEditor = true
                    } else {
                        batchImportPrompts = parsed
                        showBatchImportConfirm = true
                    }
                } else if let dict = jsonObj as? [String: Any] {
                    if let parsed = parseJSONPrompt(dict) {
                        importedPrompt = parsed
                        showImportEditor = true
                    } else {
                        errorMessage = "Could not parse prompt from JSON file."
                    }
                } else {
                    errorMessage = "Unrecognised JSON format."
                }
            } else {
                errorMessage = "File is not valid JSON."
            }
        }
    }

    /// Parses a Markdown file with optional YAML frontmatter:
    /// ```
    /// ---
    /// name: My Prompt
    /// command: my-prompt
    /// tags: [tag1, tag2]
    /// ---
    /// ...prompt content...
    /// ```
    private func parseMarkdownPrompt(data: Data, filename: String) -> ImportedPromptData? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var name = filename
        var command = generateCommand(from: filename)
        var tags: [String] = []
        var content = text

        if text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            var closingIndex: Int? = nil
            for i in 1..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed == "..." {
                    closingIndex = i
                    break
                }
            }
            if let end = closingIndex {
                let frontmatterLines = Array(lines[1..<end])
                let bodyLines = Array(lines[(end + 1)...])
                content = bodyLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                for line in frontmatterLines {
                    if line.hasPrefix("name:") {
                        name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("command:") {
                        command = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "/", with: "")
                    } else if line.hasPrefix("tags:") {
                        let tagStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        // Support both "tags: [a, b]" and "tags: a, b"
                        let cleaned = tagStr.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        tags = cleaned.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                }
            }
        }

        return ImportedPromptData(name: name, command: command, content: content, tags: tags)
    }

    /// Parses a JSON object into ImportedPromptData.
    private func parseJSONPrompt(_ dict: [String: Any]) -> ImportedPromptData? {
        let name = dict["name"] as? String ?? ""
        let command = (dict["command"] as? String ?? "")
            .replacingOccurrences(of: "/", with: "")
        let content = dict["content"] as? String ?? ""
        let tags = dict["tags"] as? [String] ?? []
        guard !name.isEmpty || !command.isEmpty else { return nil }
        let resolvedName = name.isEmpty ? command : name
        let resolvedCommand = command.isEmpty ? generateCommand(from: resolvedName) : command
        return ImportedPromptData(name: resolvedName, command: resolvedCommand, content: content, tags: tags)
    }

    // MARK: - Batch Import

    private func batchImport(prompts: [ImportedPromptData], manager: PromptManager) async {
        isBatchImporting = true
        var failed = 0
        for imp in prompts {
            do {
                let detail = PromptDetail(
                    command: imp.command,
                    name: imp.name,
                    content: imp.content,
                    isActive: true,
                    tags: imp.tags,
                    accessGrants: []
                )
                try await manager.createPrompt(from: detail, commitMessage: "Imported")
            } catch {
                failed += 1
            }
        }
        batchImportPrompts = []
        isBatchImporting = false
        if failed > 0 {
            errorMessage = "\(failed) prompt(s) failed to import."
        } else {
            Haptics.notify(.success)
        }
        await manager.fetchPrompts()
    }

    // MARK: - Helpers

    private func generateCommand(from name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
