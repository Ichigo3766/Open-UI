import SwiftUI
import UniformTypeIdentifiers
import os.log

// MARK: - WorkspaceKnowledgePickerSheet

/// A sheet that lists all knowledge base collections AND individual files,
/// letting the user pick one to attach to a model.
struct WorkspaceKnowledgePickerSheet: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    var selectedIds: Set<String>
    /// Called when user picks a collection.
    var onSelectCollection: (KnowledgeItem) -> Void
    /// Called when user picks an individual file.
    var onSelectFile: (KnowledgeItem) -> Void
    var onDismiss: () -> Void

    @State private var searchText = ""
    @State private var isLoadingCollections = false
    @State private var isLoadingFiles = false
    @State private var userFiles: [FileInfoResponse] = []
    @State private var selectedSegment: PickerSegment = .collections
    @State private var isUploadingFile = false
    @State private var uploadProgress: Double = 0
    @State private var uploadError: String? = nil
    @State private var showDocumentPicker = false

    private let logger = Logger(subsystem: "com.openui", category: "KnowledgePicker")

    enum PickerSegment: String, CaseIterable {
        case collections = "Collections"
        case files = "Files"
    }

    private var knowledgeBases: [KnowledgeItem] {
        dependencies.knowledgeManager?.knowledgeBases ?? []
    }

    private var filteredCollections: [KnowledgeItem] {
        let unselected = knowledgeBases.filter { !selectedIds.contains($0.id) }
        guard !searchText.isEmpty else { return unselected }
        return unselected.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || ($0.description ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredFiles: [FileInfoResponse] {
        let unselected = userFiles.filter { !selectedIds.contains($0.id) }
        guard !searchText.isEmpty else { return unselected }
        return unselected.filter {
            ($0.filename ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segment control
                Picker("", selection: $selectedSegment) {
                    ForEach(PickerSegment.allCases, id: \.self) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

                Divider()

                Group {
                    switch selectedSegment {
                    case .collections:
                        collectionsContent
                    case .files:
                        filesContent
                    }
                }
            }
            .background(theme.background)
            .navigationTitle("Add Knowledge")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: selectedSegment == .collections ? "Search collections…" : "Search files…")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDismiss() }
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                }
                if selectedSegment == .files {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showDocumentPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .scaledFont(size: 13, weight: .semibold)
                                Text("Upload")
                                    .scaledFont(size: 15)
                            }
                            .foregroundStyle(theme.brandPrimary)
                        }
                        .disabled(isUploadingFile)
                    }
                }
            }
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [.pdf, .plainText, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleFileImport(result) }
            }
            .alert("Upload Error", isPresented: .init(
                get: { uploadError != nil },
                set: { if !$0 { uploadError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(uploadError ?? "") }
        }
        .task {
            // Refresh collections if empty
            if (dependencies.knowledgeManager?.knowledgeBases ?? []).isEmpty {
                isLoadingCollections = true
                logger.info("[KnowledgePicker] Fetching knowledge collections...")
                await dependencies.knowledgeManager?.fetchAll()
                logger.info("[KnowledgePicker] Fetched \(dependencies.knowledgeManager?.knowledgeBases.count ?? 0) collections")
                isLoadingCollections = false
            }
            // Always fetch user files
            await fetchUserFiles()
        }
        .onChange(of: selectedSegment) { _, newSegment in
            logger.info("[KnowledgePicker] Switched to segment: \(newSegment.rawValue)")
        }
    }

    // MARK: - Collections Content

    @ViewBuilder
    private var collectionsContent: some View {
        if isLoadingCollections {
            ProgressView("Loading collections…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(theme.textSecondary)
        } else if filteredCollections.isEmpty {
            collectionsEmptyState
        } else {
            List(filteredCollections) { item in
                Button {
                    Haptics.play(.light)
                    logger.info("[KnowledgePicker] Selected collection: id='\(item.id)' name='\(item.name)'")
                    onSelectCollection(item)
                } label: {
                    collectionRow(item)
                }
                .buttonStyle(.plain)
                .listRowBackground(theme.surfaceContainer.opacity(0.4))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Files Content

    @ViewBuilder
    private var filesContent: some View {
        if isLoadingFiles {
            ProgressView("Loading files…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(theme.textSecondary)
        } else if isUploadingFile {
            VStack(spacing: 16) {
                ProgressView(value: uploadProgress)
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, 40)
                Text("Uploading file… \(Int(uploadProgress * 100))%")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredFiles.isEmpty {
            filesEmptyState
        } else {
            List(filteredFiles, id: \.id) { file in
                Button {
                    Haptics.play(.light)
                    let item = KnowledgeItem(
                        id: file.id,
                        name: file.filename ?? file.id,
                        description: nil,
                        type: .file,
                        fileCount: nil
                    )
                    logger.info("[KnowledgePicker] Selected file: id='\(file.id)' name='\(item.name)'")
                    onSelectFile(item)
                } label: {
                    fileRow(file)
                }
                .buttonStyle(.plain)
                .listRowBackground(theme.surfaceContainer.opacity(0.4))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Collection Row

    @ViewBuilder
    private func collectionRow(_ item: KnowledgeItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "cylinder.split.1x2")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.brandPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                if let desc = item.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                } else if let count = item.fileCount {
                    Text("\(count) file\(count == 1 ? "" : "s")")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            Image(systemName: "plus.circle")
                .scaledFont(size: 18)
                .foregroundStyle(theme.brandPrimary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - File Row

    @ViewBuilder
    private func fileRow(_ file: FileInfoResponse) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: fileIcon(for: file.filename ?? ""))
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.brandPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename ?? file.id)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let size = file.size, size > 0 {
                        Text(formatSize(size))
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            Spacer()

            Image(systemName: "plus.circle")
                .scaledFont(size: 18)
                .foregroundStyle(theme.brandPrimary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Empty States

    private var collectionsEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.textTertiary)
            if knowledgeBases.isEmpty {
                Text("No Knowledge Bases")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text("Add knowledge bases in the Knowledge workspace first.")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("All collections attached")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text("All available knowledge bases are already attached to this model.")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filesEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("No Files")
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("Upload a file using the button above, or all files are already attached.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fetch User Files

    private func fetchUserFiles() async {
        guard let api = dependencies.apiClient else { return }
        isLoadingFiles = true
        logger.info("[KnowledgePicker] Fetching user files...")
        do {
            let files = try await api.getUserFiles()
            userFiles = files
            logger.info("[KnowledgePicker] Fetched \(files.count) user files")
        } catch {
            logger.error("[KnowledgePicker] Failed to fetch user files: \(error.localizedDescription)")
        }
        isLoadingFiles = false
    }

    // MARK: - Handle File Import

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            logger.error("[KnowledgePicker] File import failed: \(error.localizedDescription)")
            uploadError = error.localizedDescription
            return
        case .success(let urls):
            guard let url = urls.first else { return }

            logger.info("[KnowledgePicker] File selected for upload: \(url.lastPathComponent)")

            // Security scoped access
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let fileName = url.lastPathComponent
                logger.info("[KnowledgePicker] Uploading file: '\(fileName)' size=\(data.count) bytes")

                isUploadingFile = true
                uploadProgress = 0.0

                guard let api = dependencies.apiClient else {
                    uploadError = "No API client available."
                    isUploadingFile = false
                    return
                }

                // Upload file (no knowledgeId — this is a standalone file)
                let fileId = try await api.uploadFile(data: data, fileName: fileName)
                uploadProgress = 1.0

                logger.info("[KnowledgePicker] File uploaded successfully: id='\(fileId)' name='\(fileName)'")

                // Refresh files list
                await fetchUserFiles()
                isUploadingFile = false

                // Auto-select the uploaded file
                let item = KnowledgeItem(
                    id: fileId,
                    name: fileName,
                    description: nil,
                    type: .file,
                    fileCount: nil
                )
                logger.info("[KnowledgePicker] Auto-selecting newly uploaded file: id='\(fileId)'")
                onSelectFile(item)

            } catch {
                isUploadingFile = false
                uploadError = "Upload failed: \(error.localizedDescription)"
                logger.error("[KnowledgePicker] Upload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md": return "doc.text"
        case "doc", "docx": return "doc.fill"
        case "xls", "xlsx", "csv": return "tablecells"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        case "mp3", "wav", "m4a": return "waveform"
        case "mp4", "mov", "avi": return "film"
        case "zip", "tar", "gz": return "archivebox"
        case "py", "js", "ts", "swift", "json": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
