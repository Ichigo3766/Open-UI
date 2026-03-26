import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Share Sheet

private struct ModelShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Document Picker

private struct ModelDocumentPicker: UIViewControllerRepresentable {
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

// MARK: - ModelListView

/// Workspace tab showing all custom Models with search, create, toggle, delete, clone, export, and import.
struct ModelListView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var editingModel: ModelDetail? = nil
    @State private var deletingModel: ModelItem? = nil
    @State private var errorMessage: String? = nil

    // Export
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var isExportingAll = false

    // Import
    @State private var showImportPicker = false
    @State private var showBatchImportConfirm = false
    @State private var batchImportModels: [[String: Any]] = []
    @State private var isBatchImporting = false

    private var manager: ModelManager? { dependencies.modelManager }
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    // MARK: - Filtered List

    private var filtered: [ModelItem] {
        guard let manager else { return [] }
        if searchText.isEmpty { return manager.models }
        let q = searchText.lowercased()
        return manager.models.filter {
            $0.name.lowercased().contains(q) ||
            $0.id.lowercased().contains(q) ||
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
    private func content(manager: ModelManager) -> some View {
        VStack(spacing: 0) {
            searchBar

            if manager.isLoading && manager.models.isEmpty {
                loadingView
            } else if filtered.isEmpty {
                emptyView(hasFilter: !searchText.isEmpty, manager: manager)
            } else {
                modelList(manager: manager)
            }
        }
        .background(theme.background)
        .task {
            await manager.fetchAll()
            await manager.fetchAllUsers()
        }
        // Create sheet
        .sheet(isPresented: $showCreateSheet) {
            ModelEditorView(
                existingModel: nil,
                onSave: { _ in Task { await manager.fetchAll() } }
            )
        }
        // Edit sheet
        .sheet(item: $editingModel) { detail in
            ModelEditorView(
                existingModel: detail,
                onSave: { _ in Task { await manager.fetchAll() } }
            )
        }
        // Share sheet
        .sheet(isPresented: $showShareSheet) {
            ModelShareSheet(items: shareItems)
        }
        // Import picker
        .sheet(isPresented: $showImportPicker) {
            ModelDocumentPicker(types: [.json]) { url in
                handleImportedFile(url: url, manager: manager)
            }
        }
        // Delete confirmation
        .confirmationDialog(
            "Delete \"\(deletingModel?.name ?? "")\"?",
            isPresented: .init(
                get: { deletingModel != nil },
                set: { if !$0 { deletingModel = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let model = deletingModel {
                    deletingModel = nil
                    Task { await deleteModel(model, manager: manager) }
                }
            }
            Button("Cancel", role: .cancel) { deletingModel = nil }
        } message: {
            Text("This action cannot be undone.")
        }
        // Batch import confirmation
        .confirmationDialog(
            "Import \(batchImportModels.count) Models?",
            isPresented: $showBatchImportConfirm,
            titleVisibility: .visible
        ) {
            Button("Import All") {
                Task { await batchImport(models: batchImportModels, manager: manager) }
            }
            Button("Cancel", role: .cancel) { batchImportModels = [] }
        } message: {
            Text("This will create \(batchImportModels.count) new models on the server.")
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
                // Import
                Button {
                    Haptics.play(.light)
                    showImportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("Import Model")

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
                .disabled(isExportingAll || manager.models.isEmpty)
                .accessibilityLabel("Export All Models")

                // New Model
                Button {
                    Haptics.play(.light)
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }
                .accessibilityLabel("New Model")
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
            TextField("Search Models", text: $searchText)
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

    // MARK: - Model List

    @ViewBuilder
    private func modelList(manager: ModelManager) -> some View {
        List {
            ForEach(filtered) { model in
                modelRow(model, manager: manager)
                    .listRowBackground(theme.background)
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: 0, trailing: Spacing.md))
            }
        }
        .listStyle(.plain)
        .refreshable { await manager.fetchAll() }
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(_ model: ModelItem, manager: ModelManager) -> some View {
        HStack(spacing: 12) {
            // Avatar
            modelAvatar(model)
                .frame(width: 40, height: 40)

            // Name + subtitle
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(model.name)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if !model.isActive {
                        Text("INACTIVE")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.surfaceContainer)
                            .clipShape(Capsule())
                    }
                }
                Text("By \(manager.allUsers.first(where: { $0.id == model.userId })?.name ?? model.userId) • \(model.id)")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Active toggle
            Button {
                Haptics.play(.light)
                Task { await toggleActive(id: model.id, manager: manager) }
            } label: {
                Image(systemName: model.isActive ? "checkmark.circle.fill" : "circle")
                    .scaledFont(size: 20)
                    .foregroundStyle(model.isActive ? theme.brandPrimary : theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await openEditor(for: model, manager: manager) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingModel = model
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Haptics.play(.light)
                Task { await toggleActive(id: model.id, manager: manager) }
            } label: {
                Label(
                    model.isActive ? "Deactivate" : "Activate",
                    systemImage: model.isActive ? "pause.circle" : "play.circle"
                )
            }
            .tint(model.isActive ? .orange : theme.brandPrimary)
        }
        .contextMenu {
            Button {
                Task { await openEditor(for: model, manager: manager) }
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                Haptics.play(.light)
                Task { await toggleActive(id: model.id, manager: manager) }
            } label: {
                Label(
                    model.isActive ? "Deactivate" : "Activate",
                    systemImage: model.isActive ? "pause.circle" : "play.circle"
                )
            }
            Divider()
            Button {
                Haptics.play(.light)
                Task { await cloneModel(model, manager: manager) }
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            Button {
                Haptics.play(.light)
                Task { await exportSingleModel(model, manager: manager) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                deletingModel = model
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Model Avatar

    @ViewBuilder
    private func modelAvatar(_ model: ModelItem) -> some View {
        let urlString = model.profileImageURL ?? ""

        if urlString.hasPrefix("data:image/"), urlString.contains(";base64,") {
            // Base64 data URI — decode inline, no network request needed
            let base64Image: Image? = {
                guard let commaIdx = urlString.firstIndex(of: ",") else { return nil }
                let b64 = String(urlString[urlString.index(after: commaIdx)...])
                guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                      let uiImage = UIImage(data: data) else { return nil }
                return Image(uiImage: uiImage)
            }()
            if let base64Image {
                base64Image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                modelAvatarFallback
            }
        } else {
            let resolvedURL: URL? = {
                guard !urlString.isEmpty else { return nil }
                if urlString.hasPrefix("http") { return URL(string: urlString) }
                // Server-relative paths (including /static/favicon.png) — prepend base URL
                return URL(string: serverBaseURL + urlString)
            }()

            if let resolvedURL {
                AsyncImage(url: resolvedURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    default:
                        modelAvatarFallback
                    }
                }
            } else {
                modelAvatarFallback
            }
        }
    }

    private var modelAvatarFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.brandPrimary.opacity(0.12))
            Image(systemName: "sparkles")
                .scaledFont(size: 16, weight: .medium)
                .foregroundStyle(theme.brandPrimary)
        }
        .frame(width: 40, height: 40)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(theme.brandPrimary)
            Text("Loading models…")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Empty View

    @ViewBuilder
    private func emptyView(hasFilter: Bool, manager: ModelManager) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Image(systemName: hasFilter ? "magnifyingglass" : "sparkles")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text(hasFilter ? "No Matching Models" : "No Models Yet")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text(hasFilter
                 ? "Try a different search term."
                 : "Create a custom model to wrap any base model with your own system prompt, capabilities, and settings.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
            if !hasFilter {
                Button {
                    Haptics.play(.light)
                    showCreateSheet = true
                } label: {
                    Label("New Model", systemImage: "plus")
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
            Text("Connect to a server to manage models.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func openEditor(for model: ModelItem, manager: ModelManager) async {
        do {
            let detail = try await manager.getDetail(id: model.id)
            editingModel = detail
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleActive(id: String, manager: ModelManager) async {
        do {
            try await manager.toggle(id: id)
            Haptics.play(.light)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteModel(_ model: ModelItem, manager: ModelManager) async {
        do {
            try await manager.delete(id: model.id)
            Haptics.play(.light)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cloneModel(_ model: ModelItem, manager: ModelManager) async {
        do {
            try await manager.clone(id: model.id)
            Haptics.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export Single

    private func exportSingleModel(_ model: ModelItem, manager: ModelManager) async {
        do {
            let detail = try await manager.getDetail(id: model.id)
            let payload = detail.toCreatePayload()
            let data = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(model.id).json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export All

    private func exportAll(manager: ModelManager) async {
        isExportingAll = true
        do {
            let data = try await manager.exportAll()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("models-export.json")
            try data.write(to: tempURL)
            shareItems = [tempURL]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isExportingAll = false
    }

    // MARK: - Import

    private func handleImportedFile(url: URL, manager: ModelManager) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read file."
            return
        }
        guard let jsonObj = try? JSONSerialization.jsonObject(with: data) else {
            errorMessage = "File is not valid JSON."
            return
        }
        if let array = jsonObj as? [[String: Any]] {
            if array.isEmpty {
                errorMessage = "No models found in JSON array."
            } else {
                batchImportModels = array
                showBatchImportConfirm = true
            }
        } else if let dict = jsonObj as? [String: Any] {
            batchImportModels = [dict]
            showBatchImportConfirm = true
        } else {
            errorMessage = "Unrecognised JSON format."
        }
    }

    // MARK: - Batch Import

    private func batchImport(models: [[String: Any]], manager: ModelManager) async {
        isBatchImporting = true
        do {
            try await dependencies.apiClient?.importWorkspaceModels(models: models)
            await manager.fetchAll()
            Haptics.notify(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
        batchImportModels = []
        isBatchImporting = false
    }
}
