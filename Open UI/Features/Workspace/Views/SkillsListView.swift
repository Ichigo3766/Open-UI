import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Share Sheet (UIActivityViewController wrapper)

private struct SkillShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Document Picker (UIDocumentPickerViewController wrapper)

private struct DocumentPicker: UIViewControllerRepresentable {
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

private struct ImportedSkillData: Identifiable {
    let id = UUID()
    var name: String
    var slug: String
    var description: String
    var content: String
}

// MARK: - SkillsListView

/// Workspace tab showing all Skills with search, create, toggle, delete, clone, export, and import.
struct SkillsListView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    /// Drives the "New Skill" create sheet — always opened with existingSkill: nil.
    @State private var showCreateSheet = false
    /// Drives the "Edit Skill" sheet — set to a fetched SkillDetail when a row is tapped.
    @State private var editingSkill: SkillDetail? = nil
    @State private var deletingSkill: SkillItem? = nil
    @State private var errorMessage: String? = nil

    // Clone
    @State private var isCloning = false

    // Export single
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false

    // Export all
    @State private var isExportingAll = false

    // Import
    @State private var showImportPicker = false
    @State private var importedSkill: ImportedSkillData? = nil
    @State private var showImportEditor = false
    @State private var showBatchImportConfirm = false
    @State private var batchImportSkills: [ImportedSkillData] = []
    @State private var isBatchImporting = false

    private var manager: SkillsManager? { dependencies.skillsManager }

    // MARK: - Filtered List

    private var filtered: [SkillItem] {
        guard let manager else { return [] }
        if searchText.isEmpty { return manager.skills }
        let q = searchText.lowercased()
        return manager.skills.filter {
            $0.name.lowercased().contains(q) ||
            ($0.description ?? "").lowercased().contains(q)
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
    private func content(manager: SkillsManager) -> some View {
        VStack(spacing: 0) {
            searchBar

            if manager.isLoading && manager.skills.isEmpty {
                loadingView
            } else if filtered.isEmpty {
                emptyView(hasFilter: !searchText.isEmpty, manager: manager)
            } else {
                skillList(manager: manager)
            }
        }
        .background(theme.background)
        .task {
            await manager.fetchAll()
            await manager.fetchAllUsers()
        }
        // Create sheet — always "new skill"
        .sheet(isPresented: $showCreateSheet) {
            SkillEditorView(
                existingSkill: nil,
                onSave: { _ in Task { await manager.fetchAll() } }
            )
        }
        // Edit sheet — opened with fetched SkillDetail
        .sheet(item: $editingSkill) { detail in
            SkillEditorView(
                existingSkill: detail,
                onSave: { _ in Task { await manager.fetchAll() } }
            )
        }
        // Import prefill editor (single skill)
        .sheet(isPresented: $showImportEditor) {
            if let imp = importedSkill {
                SkillEditorView(
                    prefillName: imp.name,
                    prefillSlug: imp.slug,
                    prefillDescription: imp.description,
                    prefillContent: imp.content,
                    onSave: { _ in Task { await manager.fetchAll() } }
                )
            }
        }
        // Share sheet (export)
        .sheet(isPresented: $showShareSheet) {
            SkillShareSheet(items: shareItems)
        }
        // Document picker for import
        .sheet(isPresented: $showImportPicker) {
            DocumentPicker(types: [.plainText, .json]) { url in
                handleImportedFile(url: url, manager: manager)
            }
        }
        // Delete confirmation
        .confirmationDialog(
            "Delete \"\(deletingSkill?.name ?? "")\"?",
            isPresented: .init(
                get: { deletingSkill != nil },
                set: { if !$0 { deletingSkill = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let skill = deletingSkill {
                    deletingSkill = nil
                    Task { await deleteSkill(skill, manager: manager) }
                }
            }
            Button("Cancel", role: .cancel) { deletingSkill = nil }
        } message: {
            Text("This action cannot be undone.")
        }
        // Batch import confirmation
        .confirmationDialog(
            "Import \(batchImportSkills.count) Skills?",
            isPresented: $showBatchImportConfirm,
            titleVisibility: .visible
        ) {
            Button("Import All") {
                Task { await batchImport(skills: batchImportSkills, manager: manager) }
            }
            Button("Cancel", role: .cancel) { batchImportSkills = [] }
        } message: {
            Text("This will create \(batchImportSkills.count) new skills on the server.")
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
                // Import button
                Button {
                    Haptics.play(.light)
                    showImportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("Import Skill")

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
                .disabled(isExportingAll || manager.skills.isEmpty)
                .accessibilityLabel("Export All Skills")

                // New Skill button
                Button {
                    Haptics.play(.light)
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("New Skill")
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
            TextField("Search Skills", text: $searchText)
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

    // MARK: - Skill List

    @ViewBuilder
    private func skillList(manager: SkillsManager) -> some View {
        List {
            ForEach(filtered) { skill in
                skillRow(skill, manager: manager)
                    .listRowBackground(theme.background)
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
            }
        }
        .listStyle(.plain)
        .refreshable { await manager.fetchAll() }
    }

    // MARK: - Skill Row

    @ViewBuilder
    private func skillRow(_ skill: SkillItem, manager: SkillsManager) -> some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "brain")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }

            // Name + description
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(skill.name)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if !skill.isActive {
                        Text("INACTIVE")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.surfaceContainer)
                            .clipShape(Capsule())
                    }
                }
                if let desc = skill.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Active toggle
            Button {
                Haptics.play(.light)
                Task { await toggleActive(id: skill.id, manager: manager) }
            } label: {
                Image(systemName: skill.isActive ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 20)
                    .foregroundStyle(skill.isActive ? theme.brandPrimary : theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await openEditor(for: skill, manager: manager) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingSkill = skill
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Haptics.play(.light)
                Task { await toggleActive(id: skill.id, manager: manager) }
            } label: {
                Label(
                    skill.isActive ? "Deactivate" : "Activate",
                    systemImage: skill.isActive ? "pause.circle" : "play.circle"
                )
            }
            .tint(skill.isActive ? .orange : theme.brandPrimary)
        }
        .contextMenu {
            Button {
                Task { await openEditor(for: skill, manager: manager) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                Haptics.play(.light)
                Task { await toggleActive(id: skill.id, manager: manager) }
            } label: {
                Label(
                    skill.isActive ? "Deactivate" : "Activate",
                    systemImage: skill.isActive ? "pause.circle" : "play.circle"
                )
            }
            Divider()
            Button {
                Haptics.play(.light)
                Task { await cloneSkill(skill, manager: manager) }
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            Button {
                Haptics.play(.light)
                Task { await exportSingleSkill(skill, manager: manager) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                deletingSkill = skill
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
            Text("Loading skills…")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Empty View

    @ViewBuilder
    private func emptyView(hasFilter: Bool, manager: SkillsManager) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: hasFilter ? "magnifyingglass" : "brain")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text(hasFilter ? "No Matching Skills" : "No Skills Yet")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text(hasFilter
                 ? "Try a different search term."
                 : "Create a skill to define reusable instruction sets for AI.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            if !hasFilter {
                Button {
                    Haptics.play(.light)
                    showCreateSheet = true
                } label: {
                    Label("New Skill", systemImage: "plus")
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
            Text("Connect to a server to manage skills.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Actions

    /// Fetches the full SkillDetail (including content) and opens the edit sheet.
    private func openEditor(for skill: SkillItem, manager: SkillsManager) async {
        do {
            let detail = try await manager.getDetail(id: skill.id)
            editingSkill = detail
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleActive(id: String, manager: SkillsManager) async {
        do {
            try await manager.toggleSkill(id: id)
            Haptics.play(.light)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSkill(_ skill: SkillItem, manager: SkillsManager) async {
        do {
            try await manager.deleteSkill(id: skill.id)
            Haptics.play(.light)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Clone

    private func cloneSkill(_ skill: SkillItem, manager: SkillsManager) async {
        isCloning = true
        do {
            try await manager.cloneSkill(id: skill.id)
            Haptics.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
        isCloning = false
    }

    // MARK: - Export Single

    private func exportSingleSkill(_ skill: SkillItem, manager: SkillsManager) async {
        do {
            let detail = try await manager.getDetail(id: skill.id)
            let payload = detail.toCreatePayload()
            let data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(skill.id).json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export All

    private func exportAll(manager: SkillsManager) async {
        isExportingAll = true
        do {
            let data = try await manager.exportAll()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("skills-export.json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isExportingAll = false
    }

    // MARK: - Import

    private func handleImportedFile(url: URL, manager: SkillsManager) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read file."
            return
        }
        let filename = url.lastPathComponent.lowercased()

        if filename.hasSuffix(".md") {
            // Parse Markdown with optional YAML frontmatter
            if let parsed = parseMarkdownSkill(data: data, filename: url.deletingPathExtension().lastPathComponent) {
                importedSkill = parsed
                showImportEditor = true
            } else {
                errorMessage = "Could not parse skill from Markdown file."
            }
        } else {
            // JSON — single object or array
            if let jsonObj = try? JSONSerialization.jsonObject(with: data) {
                if let array = jsonObj as? [[String: Any]] {
                    let parsed = array.compactMap { parseJSONSkill($0) }
                    if parsed.isEmpty {
                        errorMessage = "No valid skills found in JSON array."
                    } else if parsed.count == 1 {
                        importedSkill = parsed[0]
                        showImportEditor = true
                    } else {
                        batchImportSkills = parsed
                        showBatchImportConfirm = true
                    }
                } else if let dict = jsonObj as? [String: Any] {
                    if let parsed = parseJSONSkill(dict) {
                        importedSkill = parsed
                        showImportEditor = true
                    } else {
                        errorMessage = "Could not parse skill from JSON file."
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
    /// name: My Skill
    /// description: Optional description
    /// ---
    /// ...markdown content...
    /// ```
    private func parseMarkdownSkill(data: Data, filename: String) -> ImportedSkillData? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var name = filename
        var description = ""
        var content = text

        // Check for YAML frontmatter
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
                    } else if line.hasPrefix("description:") {
                        description = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        let slug = generateSlug(from: name)
        return ImportedSkillData(name: name, slug: slug, description: description, content: content)
    }

    /// Parses a JSON object into ImportedSkillData.
    /// Accepts both the full server format and the create-payload format.
    private func parseJSONSkill(_ dict: [String: Any]) -> ImportedSkillData? {
        let name = dict["name"] as? String ?? ""
        let id = dict["id"] as? String ?? ""
        let description = dict["description"] as? String ?? ""
        let content = dict["content"] as? String ?? ""
        guard !name.isEmpty || !id.isEmpty else { return nil }
        let resolvedName = name.isEmpty ? id : name
        let slug = id.isEmpty ? generateSlug(from: resolvedName) : id
        return ImportedSkillData(name: resolvedName, slug: slug, description: description, content: content)
    }

    // MARK: - Batch Import

    private func batchImport(skills: [ImportedSkillData], manager: SkillsManager) async {
        isBatchImporting = true
        var failed = 0
        for imp in skills {
            do {
                let detail = SkillDetail(
                    name: imp.name,
                    slug: imp.slug,
                    description: imp.description,
                    content: imp.content,
                    isActive: true,
                    accessGrants: []
                )
                try await manager.createSkill(from: detail)
            } catch {
                failed += 1
            }
        }
        batchImportSkills = []
        isBatchImporting = false
        if failed > 0 {
            errorMessage = "\(failed) skill(s) failed to import."
        } else {
            Haptics.notify(.success)
        }
        await manager.fetchAll()
    }

    // MARK: - Helpers

    private func generateSlug(from name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
