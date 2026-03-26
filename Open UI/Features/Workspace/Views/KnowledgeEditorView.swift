import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Folder Picker (UIDocumentPicker wrapper)

/// Wraps UIDocumentPickerViewController to reliably present a folder picker on iOS.
/// SwiftUI's `.fileImporter` with `.folder` UTType is unreliable on iOS 16+.
private struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

// MARK: - Knowledge Editor View

/// Create or edit a knowledge base (including file management).
struct KnowledgeEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let existing: KnowledgeDetail?
    let onSave: (KnowledgeDetail) -> Void

    // MARK: Form state
    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var isPrivate: Bool = true
    @State private var localAccessGrants: [AccessGrant] = []

    // MARK: Access picker state
    @State private var showUserPicker: Bool = false
    @State private var isUpdatingAccess: Bool = false
    @State private var accessUpdateError: String?

    // MARK: File management state
    @State private var files: [KnowledgeFileEntry] = []
    @State private var isLoadingFiles: Bool = false
    @State private var isUploadingFile: Bool = false
    @State private var uploadProgress: Double = 0
    @State private var showFilePicker: Bool = false
    @State private var showFolderPicker: Bool = false
    @State private var uploadStatusMessage: String = ""
    @State private var removingFileId: String?
    @State private var pendingRemoveFile: KnowledgeFileEntry?

    // MARK: Multi-select state
    @State private var isSelecting: Bool = false
    @State private var selectedFileIds: Set<String> = []
    @State private var showBulkDeleteConfirm: Bool = false
    @State private var isDeletingSelected: Bool = false

    // MARK: File preview state
    @State private var previewFile: KnowledgeFileEntry?

    // MARK: Add content sheet state
    @State private var showWebPageSheet: Bool = false
    @State private var showTextContentSheet: Bool = false
    @State private var webPageURL: String = ""
    @State private var textContentTitle: String = ""
    @State private var textContentBody: String = ""

    // MARK: UI state
    @State private var isSaving: Bool = false
    @State private var validationError: String?
    @State private var showDiscardConfirm: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    // MARK: Transcription setting
    @AppStorage("audioFileTranscriptionMode") private var audioFileTranscriptionMode: String = "server"

    private enum Field { case name, description }

    private var isEditMode: Bool { existing != nil }
    private var manager: KnowledgeManager? { dependencies.knowledgeManager }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }

    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    /// Users who currently have access, resolved from allUsers for display names.
    private var accessedUsers: [ChannelMember] {
        let ids = Set(localAccessGrants.compactMap { $0.userId })
        return allUsers.filter { ids.contains($0.id) }
    }

    private var hasChanges: Bool {
        guard let existing else { return !name.isEmpty || !descriptionText.isEmpty }
        let grantIds = Set(localAccessGrants.compactMap { $0.userId })
        let existingIds = Set(existing.accessGrants.compactMap { $0.userId })
        return name != existing.name
            || descriptionText != existing.description
            || grantIds != existingIds
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    basicInfoSection
                    settingsSection
                    if isEditMode {
                        filesSection
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker(
                    onPick: { url in
                        showFolderPicker = false
                        Task { await uploadFolder(from: url) }
                    },
                    onCancel: { showFolderPicker = false }
                )
                .ignoresSafeArea()
            }
            .sheet(item: $previewFile) { file in
                KnowledgeFilePreviewSheet(
                    file: file,
                    apiClient: dependencies.apiClient
                )
            }
            .navigationTitle(isEditMode ? "Edit Knowledge Base" : "New Knowledge Base")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: allowedFileTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showUserPicker) {
                WorkspaceAddAccessSheet(
                    existingUserIds: Set(localAccessGrants.compactMap { $0.userId }),
                    allUsers: allUsers,
                    isLoading: isUpdatingAccess,
                    serverBaseURL: serverBaseURL,
                    authToken: authToken,
                    onAdd: { selectedIds in
                        showUserPicker = false
                        Task { await addUsers(selectedIds) }
                    },
                    onCancel: { showUserPicker = false }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            // Centered delete confirmation for single file (using .alert for centered placement)
            .alert(
                "Remove \"\(pendingRemoveFile?.name ?? "")\"?",
                isPresented: .init(
                    get: { pendingRemoveFile != nil },
                    set: { if !$0 { pendingRemoveFile = nil } }
                )
            ) {
                Button("Remove", role: .destructive) {
                    if let file = pendingRemoveFile {
                        pendingRemoveFile = nil
                        Task { await removeFile(file) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingRemoveFile = nil }
            } message: {
                Text("This file will be removed from the knowledge base.")
            }
            // Centered bulk delete confirmation
            .alert(
                "Remove \(selectedFileIds.count) File\(selectedFileIds.count == 1 ? "" : "s")?",
                isPresented: $showBulkDeleteConfirm
            ) {
                Button("Remove All", role: .destructive) {
                    Task { await removeBulkSelected() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These \(selectedFileIds.count) file\(selectedFileIds.count == 1 ? "" : "s") will be removed from the knowledge base.")
            }
            .confirmationDialog(
                "Discard Changes?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your unsaved changes will be lost.")
            }
            .alert("Validation Error", isPresented: .init(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(validationError ?? "") }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("Access Error", isPresented: .init(
                get: { accessUpdateError != nil },
                set: { if !$0 { accessUpdateError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(accessUpdateError ?? "") }
        }
        .onAppear {
            populateFromExisting()
            Task { await manager?.fetchAllUsers() }
            if let id = existing?.id {
                Task { await fetchFiles(knowledgeId: id) }
            }
        }
    }

    // MARK: - Sections

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Basic Info")
            fieldCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 88, alignment: .leading)
                        TextField("e.g. Company Docs", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.top, 12)
                        TextField("Optional description…", text: $descriptionText, axis: .vertical)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .description)
                            .lineLimit(3, reservesSpace: false)
                            .padding(.horizontal, Spacing.md)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    // MARK: - Settings Section (Access Control)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                accessControlSection
            }
        }
    }

    // MARK: - Access Control Section

    @ViewBuilder
    private var accessControlSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: isPrivate ? "lock.fill" : "globe")
                    .scaledFont(size: 16)
                    .foregroundStyle(isPrivate ? theme.textSecondary : theme.brandPrimary)
                    .frame(width: 20)

                Text("Access")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textPrimary)

                Spacer()

                if isUpdatingAccess {
                    ProgressView().controlSize(.mini).tint(theme.brandPrimary)
                        .padding(.trailing, 4)
                }

                Picker("", selection: $isPrivate) {
                    Text("Private").tag(true)
                    Text("Public").tag(false)
                }
                .pickerStyle(.menu)
                .tint(theme.brandPrimary)
                .scaledFont(size: 15)
                .onChange(of: isPrivate) { _, newVal in
                    Task { await handleAccessModeChange(isPrivate: newVal) }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)

            Divider().background(theme.inputBorder.opacity(0.4))
            accessListSection
        }
    }

    @ViewBuilder
    private var accessListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Access List")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if localAccessGrants.isEmpty {
                Text("No access grants. Private to you.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 10)
            } else {
                ForEach(accessedUsers) { user in
                    accessUserRow(user)
                    Divider()
                        .background(theme.inputBorder.opacity(0.3))
                        .padding(.leading, Spacing.md + 42)
                }
            }

            Button {
                Haptics.play(.light)
                showUserPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.brandPrimary)
                    Text("Add Access")
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.brandPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Files Section

    @ViewBuilder
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header row with select/done button
            HStack {
                sectionHeader("Files")
                Spacer()
                if isLoadingFiles {
                    ProgressView().controlSize(.mini).tint(theme.brandPrimary)
                } else if !files.isEmpty {
                    if isSelecting {
                        // Show count + done
                        if !selectedFileIds.isEmpty {
                            Button {
                                Haptics.play(.light)
                                showBulkDeleteConfirm = true
                            } label: {
                                Text("Delete (\(selectedFileIds.count))")
                                    .scaledFont(size: 13, weight: .semibold)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(isDeletingSelected)
                        }
                        Button {
                            Haptics.play(.light)
                            isSelecting = false
                            selectedFileIds = []
                        } label: {
                            Text("Done")
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                        Button {
                            Haptics.play(.light)
                            isSelecting = true
                            selectedFileIds = []
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if files.isEmpty && !isUploadingFile && !isLoadingFiles {
                fieldCard {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "doc.badge.plus")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text("No files yet")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text("Upload documents to make them searchable by your AI models.")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                        uploadButton
                    }
                    .padding(Spacing.xl)
                    .frame(maxWidth: .infinity)
                }
            } else if isLoadingFiles && files.isEmpty {
                fieldCard {
                    HStack {
                        Spacer()
                        VStack(spacing: Spacing.sm) {
                            ProgressView().tint(theme.brandPrimary)
                            Text("Loading files…")
                                .scaledFont(size: 13)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(Spacing.xl)
                        Spacer()
                    }
                }
            } else {
                fieldCard {
                    VStack(spacing: 0) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                            fileRow(file)
                            if index < files.count - 1 {
                                Divider()
                                    .background(theme.inputBorder.opacity(0.3))
                                    .padding(.leading, Spacing.md + 36)
                            }
                        }
                        if isUploadingFile {
                            Divider().background(theme.inputBorder.opacity(0.3))
                            uploadProgressRow
                        }
                        if !isUploadingFile && !isSelecting {
                            Divider().background(theme.inputBorder.opacity(0.3))
                            uploadButton.padding(.vertical, Spacing.sm)
                        }
                    }
                }
            }

            Text("Supported: PDF, TXT, MD, DOCX, CSV, audio, and more.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
                .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func fileRow(_ file: KnowledgeFileEntry) -> some View {
        HStack(spacing: Spacing.sm) {
            // Selection checkbox or file icon
            if isSelecting {
                Button {
                    Haptics.play(.light)
                    if selectedFileIds.contains(file.id) {
                        selectedFileIds.remove(file.id)
                    } else {
                        selectedFileIds.insert(file.id)
                    }
                } label: {
                    Image(systemName: selectedFileIds.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        .scaledFont(size: 22)
                        .foregroundStyle(selectedFileIds.contains(file.id) ? theme.brandPrimary : theme.textTertiary)
                }
                .buttonStyle(.plain)
            } else {
                // Tappable icon — opens preview
                Button {
                    Haptics.play(.light)
                    previewFile = file
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.surfaceContainer)
                            .frame(width: 36, height: 36)
                        Image(systemName: fileIcon(for: file.filename ?? file.name))
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }

            // File info — tappable to preview
            Button {
                if !isSelecting {
                    Haptics.play(.light)
                    previewFile = file
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let size = file.formattedSize {
                        Text(size).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                    } else if let filename = file.filename, filename != file.name {
                        Text(filename).scaledFont(size: 12).foregroundStyle(theme.textTertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Delete button (only in non-selection mode)
            if !isSelecting {
                Button {
                    Haptics.play(.light)
                    pendingRemoveFile = file
                } label: {
                    if removingFileId == file.id {
                        ProgressView().controlSize(.small).tint(theme.textTertiary).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(size: 18)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(removingFileId != nil)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(
            isSelecting && selectedFileIds.contains(file.id)
                ? theme.brandPrimary.opacity(0.08)
                : Color.clear
        )
    }

    private var uploadProgressRow: some View {
        HStack(spacing: Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaceContainer).frame(width: 36, height: 36)
                ProgressView().controlSize(.small).tint(theme.brandPrimary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(uploadStatusMessage.isEmpty ? "Uploading…" : uploadStatusMessage)
                    .scaledFont(size: 14).foregroundStyle(theme.textSecondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.surfaceContainer).frame(height: 4)
                        Capsule().fill(theme.brandPrimary)
                            .frame(width: geo.size.width * uploadProgress, height: 4)
                            .animation(.easeInOut(duration: 0.3), value: uploadProgress)
                    }
                }
                .frame(height: 4)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    /// "+" menu with four content-source options.
    private var uploadButton: some View {
        Menu {
            Button {
                Haptics.play(.light)
                showFilePicker = true
            } label: {
                Label("Upload files", systemImage: "arrow.up.circle")
            }

            Button {
                Haptics.play(.light)
                showFolderPicker = true
            } label: {
                Label("Upload directory", systemImage: "folder.badge.plus")
            }

            Button {
                Haptics.play(.light)
                webPageURL = ""
                showWebPageSheet = true
            } label: {
                Label("Add webpage", systemImage: "globe")
            }

            Button {
                Haptics.play(.light)
                textContentTitle = ""
                textContentBody = ""
                showTextContentSheet = true
            } label: {
                Label("Add text content", systemImage: "text.alignleft")
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "plus.circle").scaledFont(size: 14).foregroundStyle(theme.brandPrimary)
                Text("Add Content").scaledFont(size: 15).foregroundStyle(theme.brandPrimary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(isUploadingFile)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .sheet(isPresented: $showWebPageSheet) { addWebPageSheet }
        .sheet(isPresented: $showTextContentSheet) { addTextContentSheet }
    }

    // MARK: - Add Webpage Sheet

    private var addWebPageSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Web Page URL")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 4)

                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "globe")
                            .scaledFont(size: 16)
                            .foregroundStyle(theme.textTertiary)
                        TextField("https://example.com/article", text: $webPageURL)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(Spacing.md)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
                    )
                }

                Text("The page will be scraped and its text content added to the knowledge base.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 4)

                Spacer()
            }
            .padding(Spacing.md)
            .background(theme.background)
            .navigationTitle("Add Webpage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showWebPageSheet = false }
                        .scaledFont(size: 16).foregroundStyle(theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isUploadingFile {
                        ProgressView().tint(theme.brandPrimary)
                    } else {
                        Button("Add") {
                            showWebPageSheet = false
                            Task { await addWebPage() }
                        }
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .disabled(webPageURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Add Text Content Sheet

    private var addTextContentSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Title")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 4)

                    TextField("e.g. Meeting Notes", text: $textContentTitle)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .autocorrectionDisabled()
                        .padding(Spacing.md)
                        .background(theme.surfaceContainer.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Content")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 4)

                    TextEditor(text: $textContentBody)
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textPrimary)
                        .frame(minHeight: 160)
                        .padding(Spacing.sm)
                        .background(theme.surfaceContainer.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                                .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
                        )
                }

                Spacer()
            }
            .padding(Spacing.md)
            .background(theme.background)
            .navigationTitle("Add Text Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showTextContentSheet = false }
                        .scaledFont(size: 16).foregroundStyle(theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isUploadingFile {
                        ProgressView().tint(theme.brandPrimary)
                    } else {
                        Button("Save") {
                            showTextContentSheet = false
                            Task { await addTextContent() }
                        }
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                        .disabled(
                            textContentTitle.trimmingCharacters(in: .whitespaces).isEmpty ||
                            textContentBody.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
                if hasChanges { showDiscardConfirm = true } else { dismiss() }
            }
            .scaledFont(size: 16).foregroundStyle(theme.textSecondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView().tint(theme.brandPrimary)
            } else {
                Button("Save") { save() }
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Access Control Actions

    private func handleAccessModeChange(isPrivate: Bool) async {
        guard let id = existing?.id, let manager else { return }
        let grantsToSend = localAccessGrants
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(knowledgeId: id, grants: grantsToSend, isPublic: !isPrivate)
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            self.isPrivate = !isPrivate
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func addUsers(_ userIds: [String]) async {
        guard let id = existing?.id, let manager else {
            for userId in userIds {
                if !localAccessGrants.contains(where: { $0.userId == userId }) {
                    localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
                }
            }
            Haptics.notify(.success)
            return
        }

        isUpdatingAccess = true
        var newGrants = localAccessGrants
        for userId in userIds {
            if !newGrants.contains(where: { $0.userId == userId }) {
                newGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
            }
        }
        do {
            let updated = try await manager.updateAccessGrants(knowledgeId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.notify(.success)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func toggleUserPermission(userId: String, currentlyWrite: Bool) async {
        guard let idx = localAccessGrants.firstIndex(where: { $0.userId == userId }) else { return }
        let existing = localAccessGrants[idx]
        let newGrant = AccessGrant(id: existing.id, userId: existing.userId, groupId: existing.groupId, read: true, write: !currentlyWrite)
        var newGrants = localAccessGrants
        newGrants[idx] = newGrant

        guard let id = self.existing?.id, let manager else {
            localAccessGrants = newGrants
            Haptics.play(.light)
            return
        }

        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(knowledgeId: id, grants: newGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func removeUser(_ userId: String) async {
        guard let id = existing?.id, let manager else {
            localAccessGrants.removeAll { $0.userId == userId }
            Haptics.play(.light)
            return
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            localAccessGrants.removeAll { $0.userId == userId }
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(knowledgeId: id, grants: localAccessGrants)
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            if let detail = try? await manager.getDetail(id: id) {
                localAccessGrants = detail.accessGrants
            }
            accessUpdateError = error.localizedDescription
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    // MARK: - User Row

    @ViewBuilder
    private func accessUserRow(_ user: ChannelMember) -> some View {
        HStack(spacing: Spacing.sm) {
            UserAvatar(
                size: 30,
                imageURL: user.resolveAvatarURL(serverBaseURL: serverBaseURL),
                name: user.displayName,
                authToken: authToken
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                if let role = user.role {
                    Text(role.capitalized)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()

            if let grant = localAccessGrants.first(where: { $0.userId == user.id }) {
                Button {
                    Task { await toggleUserPermission(userId: user.id, currentlyWrite: grant.write) }
                } label: {
                    Text(grant.write ? "WRITE" : "READ")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(grant.write ? theme.brandOnPrimary : theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(grant.write ? theme.brandPrimary : theme.surfaceContainerHighest)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(grant.write ? Color.clear : theme.inputBorder.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isUpdatingAccess)
            }

            Button {
                Task { await removeUser(user.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(isUpdatingAccess)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - File Actions

    private func fetchFiles(knowledgeId: String) async {
        guard let manager else { return }
        isLoadingFiles = true
        do {
            files = try await manager.getFiles(knowledgeId: knowledgeId)
        } catch {
            // Non-critical — show empty state
        }
        isLoadingFiles = false
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { await uploadFilesBatch(from: urls) }
        case .failure(let error):
            errorMessage = "Could not open file: \(error.localizedDescription)"
        }
    }

    // MARK: - Audio Detection

    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "ogg", "flac", "aac", "wma", "opus", "webm", "caf", "aiff", "aif"
    ]

    private func isAudioFile(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return Self.audioExtensions.contains(ext)
    }

    // MARK: - Upload Multiple Files (with audio transcription)

    private func uploadFilesBatch(from urls: [URL]) async {
        guard let id = existing?.id, let manager else { return }

        isUploadingFile = true
        uploadProgress = 0.02

        // Read all file data
        var fileTuples: [(data: Data, fileName: String)] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                fileTuples.append((data: data, fileName: url.lastPathComponent))
            } catch {}
        }

        guard !fileTuples.isEmpty else {
            errorMessage = "Could not read any of the selected files."
            isUploadingFile = false; uploadProgress = 0; uploadStatusMessage = ""
            return
        }

        await uploadFileTuples(fileTuples, knowledgeId: id, manager: manager)
    }

    /// Recursively collects all files inside a folder and uploads them.
    private func uploadFolder(from folderURL: URL) async {
        guard let id = existing?.id, let manager else { return }

        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }

        isUploadingFile = true
        uploadProgress = 0.02
        uploadStatusMessage = "Scanning folder…"

        var fileTuples: [(data: Data, fileName: String)] = []
        let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        let supportedExtensions: Set<String> = [
            "pdf", "txt", "md", "markdown", "docx", "doc",
            "csv", "json", "xml", "html", "htm", "xlsx", "xls",
            "pptx", "ppt", "rst", "yaml", "yml", "toml",
            "mp3", "wav", "m4a", "ogg", "flac", "aac", "wma", "opus", "webm", "caf", "aiff", "aif"
        ]

        // Collect all URLs into an array synchronously before entering async context,
        // since NSEnumerator.makeIterator() is unavailable from async contexts in Swift 6.
        let allURLs = enumerator?.allObjects.compactMap { $0 as? URL } ?? []
        for fileURL in allURLs {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            do {
                let data = try Data(contentsOf: fileURL)
                let relativePath = fileURL.path
                    .replacingOccurrences(of: folderURL.path + "/", with: "")
                    .replacingOccurrences(of: "/", with: "_")
                fileTuples.append((data: data, fileName: relativePath))
            } catch {}
        }

        guard !fileTuples.isEmpty else {
            errorMessage = "No supported files found in the selected folder."
            isUploadingFile = false; uploadProgress = 0; uploadStatusMessage = ""
            return
        }

        await uploadFileTuples(fileTuples, knowledgeId: id, manager: manager)
    }

    /// Core upload routine: handles audio transcription for on-device mode, then uploads.
    private func uploadFileTuples(
        _ fileTuples: [(data: Data, fileName: String)],
        knowledgeId: String,
        manager: KnowledgeManager
    ) async {
        let total = fileTuples.count
        uploadStatusMessage = "Preparing \(total) file\(total == 1 ? "" : "s")…"

        // Separate audio from non-audio
        let audioFiles = fileTuples.filter { isAudioFile($0.fileName) }
        let regularFiles = fileTuples.filter { !isAudioFile($0.fileName) }

        var finalFiles: [(data: Data, fileName: String)] = regularFiles

        // Handle audio files based on transcription mode
        if !audioFiles.isEmpty {
            if audioFileTranscriptionMode == "device" {
                // Transcribe each audio file on-device and convert to text
                let asrService = dependencies.asrService
                for (idx, audioFile) in audioFiles.enumerated() {
                    let fileNum = idx + 1
                    uploadStatusMessage = "Transcribing \(audioFile.fileName) on device (\(fileNum)/\(audioFiles.count))…"
                    uploadProgress = Double(fileNum - 1) / Double(total) * 0.4
                    do {
                        let transcript = try await asrService.transcribe(
                            audioData: audioFile.data,
                            fileName: audioFile.fileName
                        )
                        if !transcript.isEmpty {
                            let baseName = (audioFile.fileName as NSString).deletingPathExtension
                            let txtFileName = "\(baseName)_transcript.txt"
                            if let textData = transcript.data(using: String.Encoding.utf8) {
                                finalFiles.append((data: textData, fileName: txtFileName))
                            }
                        }
                    } catch {
                        // If transcription fails, fall back to direct upload
                        finalFiles.append(audioFile)
                    }
                }
            } else {
                // Server-side transcription: upload audio directly
                finalFiles.append(contentsOf: audioFiles)
            }
        }

        guard !finalFiles.isEmpty else {
            errorMessage = "No files could be prepared for upload."
            isUploadingFile = false; uploadProgress = 0; uploadStatusMessage = ""
            return
        }

        let uploadTotal = finalFiles.count
        uploadStatusMessage = "Uploading \(uploadTotal) file\(uploadTotal == 1 ? "" : "s")…"
        uploadProgress = 0.1

        do {
            try await manager.uploadAndAddFilesBatch(
                files: finalFiles,
                knowledgeId: knowledgeId,
                onProgress: { [self] p in
                    uploadProgress = 0.1 + p * 0.85
                    let completed = Int(p * Double(uploadTotal))
                    if completed < uploadTotal {
                        uploadStatusMessage = "Uploading \(completed + 1) of \(uploadTotal) file\(uploadTotal == 1 ? "" : "s")…"
                    } else {
                        uploadStatusMessage = "Processing on server…"
                    }
                }
            )
            uploadProgress = 1.0
            uploadStatusMessage = "Done!"
            await fetchFiles(knowledgeId: knowledgeId)
            Haptics.notify(.success)
        } catch {
            errorMessage = "Failed to upload: \(error.localizedDescription)"
            Haptics.notify(.error)
        }

        isUploadingFile = false
        uploadProgress = 0
        uploadStatusMessage = ""
    }

    private func removeFile(_ file: KnowledgeFileEntry) async {
        guard let id = existing?.id, let manager else { return }
        removingFileId = file.id
        do {
            _ = try await manager.removeFile(fileId: file.id, from: id)
            withAnimation(.easeInOut(duration: 0.2)) {
                files.removeAll { $0.id == file.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        removingFileId = nil
        Haptics.play(.light)
    }

    /// Removes all selected files in parallel.
    private func removeBulkSelected() async {
        guard let id = existing?.id, let manager else { return }
        let idsToRemove = selectedFileIds
        isDeletingSelected = true
        isSelecting = false
        selectedFileIds = []

        await withTaskGroup(of: Void.self) { group in
            for fileId in idsToRemove {
                group.addTask {
                    _ = try? await manager.removeFile(fileId: fileId, from: id)
                }
            }
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            files.removeAll { idsToRemove.contains($0.id) }
        }
        isDeletingSelected = false
        Haptics.notify(.success)
    }

    private func addWebPage() async {
        guard let id = existing?.id, let manager else { return }
        let url = webPageURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }

        isUploadingFile = true
        uploadProgress = 0.2
        uploadStatusMessage = "Scraping webpage…"
        do {
            _ = try await manager.addWebPage(url: url, knowledgeId: id)
            uploadProgress = 1.0
            await fetchFiles(knowledgeId: id)
            Haptics.notify(.success)
        } catch {
            errorMessage = "Failed to add webpage: \(error.localizedDescription)"
            Haptics.notify(.error)
        }
        isUploadingFile = false
        uploadProgress = 0
        uploadStatusMessage = ""
    }

    private func addTextContent() async {
        guard let id = existing?.id, let manager else { return }
        let title = textContentTitle.trimmingCharacters(in: .whitespaces)
        let body = textContentBody.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !body.isEmpty else { return }

        isUploadingFile = true
        uploadProgress = 0.2
        uploadStatusMessage = "Uploading text content…"
        do {
            _ = try await manager.addTextContent(text: body, title: title, knowledgeId: id)
            uploadProgress = 1.0
            await fetchFiles(knowledgeId: id)
            Haptics.notify(.success)
        } catch {
            errorMessage = "Failed to add text content: \(error.localizedDescription)"
            Haptics.notify(.error)
        }
        isUploadingFile = false
        uploadProgress = 0
        uploadStatusMessage = ""
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private func fieldCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(theme.surfaceContainer.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
            )
    }

    private var allowedFileTypes: [UTType] {
        [.pdf, .plainText, .commaSeparatedText,
         UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
         UTType("net.daringfireball.markdown") ?? .plainText,
         .json, .xml, .html, .data,
         .audio, .mp3, UTType("public.aifc-audio") ?? .audio,
         UTType("com.apple.m4a-audio") ?? .audio,
         UTType("public.ogg-vorbis-audio") ?? .audio]
    }

    private func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md", "markdown": return "doc.plaintext"
        case "csv": return "tablecells"
        case "json": return "curlybraces"
        case "xml", "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "docx", "doc": return "doc.text"
        case "xlsx", "xls": return "tablecells"
        case "pptx", "ppt": return "rectangle.on.rectangle"
        case "mp3", "wav", "m4a", "ogg", "flac", "aac", "wma", "opus", "webm", "caf", "aiff", "aif":
            return "waveform"
        default: return "doc"
        }
    }

    private func populateFromExisting() {
        guard let existing else { return }
        name = existing.name
        descriptionText = existing.description
        // Strip the wildcard entry from the local list — it's represented by isPrivate = false
        let hasWildcard = existing.accessGrants.contains { $0.userId == "*" }
        localAccessGrants = existing.accessGrants.filter { $0.userId != "*" }
        isPrivate = !hasWildcard
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the knowledge base."
            return
        }
        isSaving = true
        Haptics.play(.medium)
        let grants = localAccessGrants
        let detail = KnowledgeDetail(
            id: existing?.id ?? UUID().uuidString,
            name: trimmedName,
            description: descriptionText.trimmingCharacters(in: .whitespaces),
            accessGrants: grants,
            files: files,
            userId: existing?.userId ?? "",
            createdAt: existing?.createdAt,
            updatedAt: Date()
        )
        onSave(detail)
        isSaving = false
        dismiss()
    }
}

// MARK: - File Preview Sheet

/// Fetches and displays the extracted text content of a knowledge base file.
struct KnowledgeFilePreviewSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let file: KnowledgeFileEntry
    let apiClient: APIClient?

    @State private var content: String = ""
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: Spacing.md) {
                        ProgressView().tint(theme.brandPrimary)
                        Text("Loading content…")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
                } else if let error = errorMessage {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text("Could not load content")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text(error)
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
                } else if content.isEmpty {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "doc.text")
                            .scaledFont(size: 32)
                            .foregroundStyle(theme.textTertiary)
                        Text("No content available")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text("The server has not extracted any text from this file yet.")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
                } else {
                    ScrollView {
                        Text(content)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.md)
                    }
                    .background(theme.background)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .scaledFont(size: 16, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await loadContent() }
    }

    private func loadContent() async {
        isLoading = true
        do {
            let json = try await apiClient?.getFileInfo(id: file.id) ?? [:]
            // Server returns content in data.content.text or data.content
            if let data = json["data"] as? [String: Any] {
                if let contentBlock = data["content"] as? [String: Any] {
                    content = contentBlock["text"] as? String ?? ""
                } else if let contentStr = data["content"] as? String {
                    content = contentStr
                }
            }
            // Fallback: try the dedicated data/content endpoint
            if content.isEmpty {
                let (rawData, _) = try await apiClient?.getFileContent(id: file.id) ?? (Data(), "")
                if let text = String(data: rawData, encoding: .utf8), !text.isEmpty {
                    content = text
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
