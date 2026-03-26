import SwiftUI
import PhotosUI
import os.log

// MARK: - ModelEditorView

/// Sheet for creating or editing a custom Model.
/// Mirrors SkillEditorView/KnowledgeEditorView in structure and access-grant UI.
struct ModelEditorView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private let logger = Logger(subsystem: "com.openui", category: "ModelEditor")

    // MARK: - Input

    var existingModel: ModelDetail?
    var onSave: ((ModelDetail) -> Void)?

    // MARK: - Basic Info

    @State private var name = ""
    @State private var modelId = ""
    @State private var baseModelId = ""
    @State private var baseModelDisplayName = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var idManuallyEdited = false
    @State private var isAutoSettingId = false

    // MARK: - Profile Image

    @State private var profileImageURL: String? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var selectedImageData: Data? = nil
    @State private var isUploadingProfileImage = false

    // MARK: - System Prompt

    @State private var systemPrompt = ""
    @State private var isSystemPromptExpanded = false

    // MARK: - Active

    @State private var isActive = true
    @State private var initialIsActive = true
    @State private var isTogglingActive = false

    // MARK: - Capabilities

    @State private var capVision = true
    @State private var capFileUpload = true
    @State private var capFileContext = true
    @State private var capWebSearch = true
    @State private var capImageGeneration = true
    @State private var capCodeInterpreter = true
    @State private var capUsage = true
    @State private var capCitations = true
    @State private var capStatusUpdates = true
    @State private var capBuiltinTools = true

    // MARK: - Default Features

    @State private var defaultWebSearch = true
    @State private var defaultImageGen = false
    @State private var defaultCodeInterpreter = false

    // MARK: - Builtin Tools

    @State private var builtinTime = true
    @State private var builtinMemory = true
    @State private var builtinChats = true
    @State private var builtinNotes = true
    @State private var builtinKnowledge = true
    @State private var builtinChannels = true
    @State private var builtinWebSearch = true
    @State private var builtinImageGen = true
    @State private var builtinCodeInterpreter = true

    // MARK: - Knowledge

    @State private var knowledgeItems: [ModelKnowledgeEntry] = []
    @State private var showKnowledgePicker = false

    // MARK: - Suggestion Prompts

    @State private var suggestionPrompts: [SuggestionPrompt] = []
    @State private var useCustomPrompts: Bool = false

    // MARK: - TTS Voice

    @State private var ttsVoice = ""

    // MARK: - Base Model Picker

    @State private var availableModels: [AIModel] = []
    @State private var showBaseModelPicker = false
    @State private var isFetchingModels = false

    // MARK: - Advanced Params

    @State private var showAdvancedParams = false

    @State private var advStreamResponse: Bool? = nil
    @State private var advStreamDeltaChunkSize: Int? = nil
    @State private var advFunctionCalling: String? = nil
    @State private var advReasoningEffort: String? = nil
    @State private var advReasoningTagStart: String? = nil
    @State private var advReasoningTagEnd: String? = nil
    @State private var advSeed: Int? = nil
    @State private var advStopSequences: String? = nil
    @State private var advTemperature: Double? = nil
    @State private var advLogitBias: String? = nil
    @State private var advMaxTokens: Int? = nil
    @State private var advTopK: Int? = nil
    @State private var advTopP: Double? = nil
    @State private var advMinP: Double? = nil
    @State private var advFrequencyPenalty: Double? = nil
    @State private var advPresencePenalty: Double? = nil
    @State private var advMirostat: Int? = nil
    @State private var advMirostatEta: Double? = nil
    @State private var advMirostatTau: Double? = nil
    @State private var advRepeatLastN: Int? = nil
    @State private var advTfsZ: Double? = nil
    @State private var advRepeatPenalty: Double? = nil
    @State private var advUseMmap: Bool? = nil
    @State private var advUseMlock: Bool? = nil
    @State private var advThink: Bool? = nil
    @State private var advFormat: String? = nil
    @State private var advNumKeep: Int? = nil
    @State private var advNumCtx: Int? = nil
    @State private var advNumBatch: Int? = nil
    @State private var advNumThread: Int? = nil
    @State private var advNumGpu: Int? = nil
    @State private var advKeepAlive: String? = nil
    @State private var customParams: [(key: String, value: String)] = []

    // MARK: - Access Control

    @State private var isPrivate = true
    @State private var localAccessGrants: [AccessGrant] = []
    @State private var showUserPicker = false
    @State private var isUpdatingAccess = false
    @State private var accessUpdateError: String?

    // MARK: - UI State

    @State private var isSaving = false
    @State private var validationError: String? = nil
    @State private var showDiscardConfirm = false

    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case name, modelId, description, systemPrompt, ttsVoice, newSuggestion }

    // MARK: - Computed

    private var manager: ModelManager? { dependencies.modelManager }
    private var allUsers: [ChannelMember] { manager?.allUsers ?? [] }
    private var isEditing: Bool { existingModel != nil }
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var authToken: String? { dependencies.apiClient?.network.authToken }

    private var accessedUsers: [ChannelMember] {
        let ids = Set(localAccessGrants.compactMap { $0.userId })
        return allUsers.filter { ids.contains($0.id) }
    }

    private var hasChanges: Bool {
        guard let existing = existingModel else {
            return !name.isEmpty || !modelId.isEmpty || !systemPrompt.isEmpty
        }
        return name != existing.name
            || modelId != existing.id
            || systemPrompt != existing.systemPrompt
            || description != (existing.description ?? "")
    }

    // Resolved profile image URL for displaying in the editor.
    // Returns nil for data URIs (handled via selectedImageData / dataURIImage).
    private var resolvedProfileImageURL: URL? {
        let urlString = profileImageURL ?? ""
        if urlString.hasPrefix("data:image") { return nil }
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return URL(string: urlString)
        }
        // For an existing model use the model avatar endpoint
        if let id = existingModel?.id, !id.isEmpty {
            let normalizedBase = serverBaseURL.hasSuffix("/") ? String(serverBaseURL.dropLast()) : serverBaseURL
            var comps = URLComponents(string: "\(normalizedBase)/api/v1/models/model/profile/image")
            comps?.queryItems = [URLQueryItem(name: "id", value: id)]
            return comps?.url
        }
        // New model with no user-picked image → show server default favicon
        let normalizedBase = serverBaseURL.hasSuffix("/") ? String(serverBaseURL.dropLast()) : serverBaseURL
        if !normalizedBase.isEmpty {
            return URL(string: "\(normalizedBase)/static/favicon.png")
        }
        return nil
    }

    // UIImage decoded from an existing data URI profileImageURL (edit mode, no new photo picked)
    private var dataURIImage: UIImage? {
        guard let urlString = profileImageURL, urlString.hasPrefix("data:image") else { return nil }
        guard selectedImageData == nil else { return nil } // already showing via selectedImageData
        if let commaIdx = urlString.firstIndex(of: ",") {
            let base64 = String(urlString[urlString.index(after: commaIdx)...])
            if let data = Data(base64Encoded: base64) {
                return UIImage(data: data)
            }
        }
        return nil
    }

    // MARK: - Slugify helper

    /// Converts a display name into a URL-safe slug: "Abhi AI" → "abhi-ai"
    static func slugify(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    profileImageSection
                    basicInfoSection
                    systemPromptSection
                    // Advanced params extracted into a child struct to prevent stack overflow
                    ModelAdvancedParamsSection(
                        showAdvancedParams: $showAdvancedParams,
                        advStreamResponse: $advStreamResponse,
                        advStreamDeltaChunkSize: $advStreamDeltaChunkSize,
                        advFunctionCalling: $advFunctionCalling,
                        advReasoningEffort: $advReasoningEffort,
                        advReasoningTagStart: $advReasoningTagStart,
                        advReasoningTagEnd: $advReasoningTagEnd,
                        advSeed: $advSeed,
                        advStopSequences: $advStopSequences,
                        advTemperature: $advTemperature,
                        advLogitBias: $advLogitBias,
                        advMaxTokens: $advMaxTokens,
                        advTopK: $advTopK,
                        advTopP: $advTopP,
                        advMinP: $advMinP,
                        advFrequencyPenalty: $advFrequencyPenalty,
                        advPresencePenalty: $advPresencePenalty,
                        advMirostat: $advMirostat,
                        advMirostatEta: $advMirostatEta,
                        advMirostatTau: $advMirostatTau,
                        advRepeatLastN: $advRepeatLastN,
                        advTfsZ: $advTfsZ,
                        advRepeatPenalty: $advRepeatPenalty,
                        advUseMmap: $advUseMmap,
                        advUseMlock: $advUseMlock,
                        advThink: $advThink,
                        advFormat: $advFormat,
                        advNumKeep: $advNumKeep,
                        advNumCtx: $advNumCtx,
                        advNumBatch: $advNumBatch,
                        advNumThread: $advNumThread,
                        advNumGpu: $advNumGpu,
                        advKeepAlive: $advKeepAlive,
                        customParams: $customParams
                    )
                    suggestionPromptsSection
                    knowledgeSection
                    capabilitiesSection
                    defaultFeaturesSection
                    builtinToolsSection
                    ttsVoiceSection
                    settingsSection
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xl)
            }
            .background(theme.background)
            .navigationTitle(isEditing ? "Edit Model" : "New Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
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
            .sheet(isPresented: $isSystemPromptExpanded) {
                FullscreenContentEditor(
                    title: "System Prompt",
                    placeholder: "Write a system prompt…",
                    content: $systemPrompt
                )
            }
            .sheet(isPresented: $showBaseModelPicker) {
                BaseModelPickerSheet(
                    availableModels: availableModels,
                    selectedModelId: baseModelId,
                    serverBaseURL: serverBaseURL,
                    authToken: authToken,
                    onSelect: { model in
                        baseModelId = model.id
                        baseModelDisplayName = model.name
                        showBaseModelPicker = false
                        logger.info("[BaseModelPicker] Selected base model: id='\(model.id)' name='\(model.name)'")
                    },
                    onClear: {
                        baseModelId = ""
                        baseModelDisplayName = ""
                        showBaseModelPicker = false
                        logger.info("[BaseModelPicker] Cleared base model selection")
                    },
                    onDismiss: { showBaseModelPicker = false }
                )
                .environment(dependencies)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
            .alert("Access Error", isPresented: .init(
                get: { accessUpdateError != nil },
                set: { if !$0 { accessUpdateError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(accessUpdateError ?? "") }
        }
        .onAppear {
            populateIfEditing()
            Task {
                await manager?.fetchAllUsers()
                await fetchAvailableModels()
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await handlePhotoSelection(newItem) }
        }
    }

    // MARK: - Profile Image Section

    private var profileImageSection: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            HStack {
                Spacer()
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        // Priority: 1) newly picked photo, 2) existing data URI, 3) resolved URL, 4) fallback
                        if let imageData = selectedImageData, let uiImage = UIImage(data: imageData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if let uiImage = dataURIImage {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else if let avatarURL = resolvedProfileImageURL {
                            CachedAsyncImage(url: avatarURL, authToken: authToken) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.shimmerBase)
                                    .frame(width: 72, height: 72)
                                    .shimmer()
                            }
                        } else {
                            // Fallback avatar
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.brandPrimary.opacity(0.12))
                                    .frame(width: 72, height: 72)
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(theme.brandPrimary.opacity(0.25), lineWidth: 1)
                                    .frame(width: 72, height: 72)
                                if let initial = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                                    Text(String(initial).uppercased())
                                        .scaledFont(size: 28, weight: .semibold, design: .rounded)
                                        .foregroundStyle(theme.brandPrimary)
                                } else {
                                    Image(systemName: "brain")
                                        .scaledFont(size: 28, weight: .medium)
                                        .foregroundStyle(theme.brandPrimary)
                                }
                            }
                        }

                        // Edit badge overlay
                        ZStack {
                            Circle()
                                .fill(theme.brandPrimary)
                                .frame(width: 22, height: 22)
                            Image(systemName: "pencil")
                                .scaledFont(size: 11, weight: .bold)
                                .foregroundStyle(.white)
                        }
                        .offset(x: 4, y: 4)
                    }
                }
                .buttonStyle(.plain)
                .overlay(
                    Group {
                        if isUploadingProfileImage {
                            ProgressView()
                                .tint(.white)
                                .frame(width: 72, height: 72)
                                .background(Color.black.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                )
                Spacer()
            }
            Text("Tap to change profile image")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.top, Spacing.sm)
    }

    // MARK: - Basic Info Section

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Model Info")
            fieldCard {
                VStack(spacing: 0) {
                    // Name
                    HStack {
                        Text("Name")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. AWS Chatbot", text: $name)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .name)
                            .autocorrectionDisabled()
                            .onChange(of: name) { _, newValue in
                                // Auto-fill Model ID with slugified name unless user edited it manually
                                if !idManuallyEdited {
                                    isAutoSettingId = true
                                    modelId = Self.slugify(newValue)
                                    isAutoSettingId = false
                                }
                            }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Model ID
                    HStack {
                        Text("Model ID")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. aws-chatbot", text: $modelId)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .modelId)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .disabled(isEditing)
                            .onChange(of: modelId) { _, _ in
                                if !isAutoSettingId { idManuallyEdited = true }
                            }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Base Model — Picker button
                    Button {
                        Haptics.play(.light)
                        showBaseModelPicker = true
                        logger.info("[BaseModelPicker] Opening base model picker (available models: \(availableModels.count))")
                    } label: {
                        HStack {
                            Text("Base Model")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 90, alignment: .leading)
                            if isFetchingModels {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .padding(.leading, 4)
                            } else if baseModelId.isEmpty {
                                Text("Select a model…")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textTertiary)
                            } else {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(baseModelDisplayName.isEmpty ? baseModelId : baseModelDisplayName)
                                        .scaledFont(size: 15)
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    if !baseModelDisplayName.isEmpty && baseModelDisplayName != baseModelId {
                                        Text(baseModelId)
                                            .scaledFont(size: 11)
                                            .foregroundStyle(theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Description
                    HStack {
                        Text("Description")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("Optional description", text: $description)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .focused($focusedField, equals: .description)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)

                    Divider().background(theme.inputBorder.opacity(0.4))

                    // Tags
                    HStack {
                        Text("Tags")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("e.g. aws, chat (comma-separated)", text: $tags)
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textPrimary)
                            .autocorrectionDisabled()
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, Spacing.md)
                }
            }
        }
    }

    // MARK: - System Prompt Section

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("System Prompt")
                Spacer()
                Button {
                    Haptics.play(.light)
                    isSystemPromptExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(6)
                        .background(theme.surfaceContainer.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            fieldCard {
                TextEditor(text: $systemPrompt)
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                    .frame(minHeight: 120, maxHeight: 300)
                    .focused($focusedField, equals: .systemPrompt)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.sm)
            }
        }
    }

    // MARK: - Suggestion Prompts Section

    private var suggestionPromptsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header row: "PROMPTS" label + Default/Custom toggle button
            HStack {
                sectionHeader("Prompts")
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        useCustomPrompts.toggle()
                        if !useCustomPrompts { suggestionPrompts = [] }
                    }
                    Haptics.play(.light)
                } label: {
                    Text(useCustomPrompts ? "Custom" : "Default")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(useCustomPrompts ? theme.brandPrimary : theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(useCustomPrompts ? theme.brandPrimary.opacity(0.12) : theme.surfaceContainer)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Only show the card when Custom mode is active
            if useCustomPrompts {
                fieldCard {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestionPrompts.enumerated()), id: \.offset) { idx, _ in
                            VStack(spacing: 0) {
                                // Title field
                                HStack {
                                    Text("Title")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("Optional title", text: Binding(
                                        get: { suggestionPrompts[idx].title },
                                        set: { suggestionPrompts[idx].title = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                    Spacer()
                                    Button {
                                        suggestionPrompts.remove(at: idx)
                                        Haptics.play(.light)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .scaledFont(size: 16)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                                // Subtitle field
                                HStack {
                                    Text("Subtitle")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("Optional subtitle", text: Binding(
                                        get: { suggestionPrompts[idx].subtitle },
                                        set: { suggestionPrompts[idx].subtitle = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.bottom, 4)

                                // Prompt content field
                                HStack {
                                    Text("Prompt")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                        .frame(width: 56, alignment: .leading)
                                    TextField("Prompt text", text: Binding(
                                        get: { suggestionPrompts[idx].content },
                                        set: { suggestionPrompts[idx].content = $0 }
                                    ))
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.textPrimary)
                                    .autocorrectionDisabled()
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.bottom, 10)
                            }
                            Divider().background(theme.inputBorder.opacity(0.3))
                        }

                        // Add new prompt button
                        Button {
                            suggestionPrompts.append(SuggestionPrompt())
                            Haptics.play(.light)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .scaledFont(size: 13, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                                Text("Add Prompt")
                                    .scaledFont(size: 14)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - Knowledge Section

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Knowledge")
            Text("Attach knowledge collections or files to this model.")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)

            fieldCard {
                VStack(spacing: 0) {
                    ForEach(knowledgeItems) { entry in
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: entry.icon)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.brandPrimary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundStyle(theme.textPrimary)
                                Text(entry.type == .collection ? "Collection" : "File")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer()
                            Button {
                                logger.info("[Knowledge] Removing entry: id='\(entry.id)' name='\(entry.name)' type=\(entry.type.rawValue)")
                                knowledgeItems.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                        Divider().background(theme.inputBorder.opacity(0.3))
                    }

                    Button {
                        Haptics.play(.light)
                        showKnowledgePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .scaledFont(size: 13, weight: .medium)
                                .foregroundStyle(theme.brandPrimary)
                            Text("Add Knowledge")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.brandPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 10)
                }
            }
        }
        .sheet(isPresented: $showKnowledgePicker) {
            WorkspaceKnowledgePickerSheet(
                selectedIds: Set(knowledgeItems.map { $0.id }),
                onSelectCollection: { item in
                    if !knowledgeItems.contains(where: { $0.id == item.id }) {
                        let entry = ModelKnowledgeEntry(
                            id: item.id,
                            name: item.name,
                            description: item.description,
                            type: .collection
                        )
                        knowledgeItems.append(entry)
                        logger.info("[Knowledge] Added collection: id='\(item.id)' name='\(item.name)'")
                    }
                    showKnowledgePicker = false
                },
                onSelectFile: { item in
                    if !knowledgeItems.contains(where: { $0.id == item.id }) {
                        let entry = ModelKnowledgeEntry(
                            id: item.id,
                            name: item.name,
                            description: item.description,
                            type: .file
                        )
                        knowledgeItems.append(entry)
                        logger.info("[Knowledge] Added file: id='\(item.id)' name='\(item.name)'")
                    }
                    showKnowledgePicker = false
                },
                onDismiss: { showKnowledgePicker = false }
            )
            .environment(dependencies)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Capabilities Section

    private var capabilitiesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Capabilities")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("Vision", systemImage: "eye", value: $capVision)
                    capCheckbox("File Upload", systemImage: "doc.badge.plus", value: $capFileUpload)
                    capCheckbox("File Context", systemImage: "doc.text.magnifyingglass", value: $capFileContext)
                    capCheckbox("Web Search", systemImage: "magnifyingglass", value: $capWebSearch)
                    capCheckbox("Image Generation", systemImage: "photo.badge.plus", value: $capImageGeneration)
                    capCheckbox("Code Interpreter", systemImage: "chevron.left.forwardslash.chevron.right", value: $capCodeInterpreter)
                    capCheckbox("Usage", systemImage: "chart.bar", value: $capUsage)
                    capCheckbox("Citations", systemImage: "quote.bubble", value: $capCitations)
                    capCheckbox("Status Updates", systemImage: "info.circle", value: $capStatusUpdates)
                    capCheckbox("Builtin Tools", systemImage: "wrench.and.screwdriver", value: $capBuiltinTools)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Default Features Section

    private var defaultFeaturesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Default Features")
            fieldCard {
                HStack(spacing: 0) {
                    capCheckbox("Web Search", systemImage: "magnifyingglass", value: $defaultWebSearch)
                    capCheckbox("Image Generation", systemImage: "photo.badge.plus", value: $defaultImageGen)
                    capCheckbox("Code Interpreter", systemImage: "chevron.left.forwardslash.chevron.right", value: $defaultCodeInterpreter)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Builtin Tools Section

    private var builtinToolsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Builtin Tools")
            fieldCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 0) {
                    capCheckbox("Time & Calculation", systemImage: "clock", value: $builtinTime)
                    capCheckbox("Memory", systemImage: "brain", value: $builtinMemory)
                    capCheckbox("Chat History", systemImage: "bubble.left.and.bubble.right", value: $builtinChats)
                    capCheckbox("Notes", systemImage: "note.text", value: $builtinNotes)
                    capCheckbox("Knowledge Base", systemImage: "cylinder.split.1x2", value: $builtinKnowledge)
                    capCheckbox("Channels", systemImage: "antenna.radiowaves.left.and.right", value: $builtinChannels)
                    capCheckbox("Web Search", systemImage: "magnifyingglass", value: $builtinWebSearch)
                    capCheckbox("Image Generation", systemImage: "photo.badge.plus", value: $builtinImageGen)
                    capCheckbox("Code Interpreter", systemImage: "chevron.left.forwardslash.chevron.right", value: $builtinCodeInterpreter)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - TTS Voice Section

    private var ttsVoiceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("TTS Voice")
            fieldCard {
                HStack {
                    TextField("e.g. alloy, echo, shimmer", text: $ttsVoice)
                        .scaledFont(size: 15)
                        .foregroundStyle(theme.textPrimary)
                        .focused($focusedField, equals: .ttsVoice)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Settings Section (Active + Access Control)

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionHeader("Settings")
            fieldCard {
                VStack(spacing: 0) {
                    Toggle(isOn: $isActive) {
                        HStack(spacing: Spacing.sm) {
                            if isTogglingActive {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(theme.brandPrimary)
                                    .frame(width: 18, height: 18)
                            } else {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active")
                                    .scaledFont(size: 15)
                                    .foregroundStyle(theme.textPrimary)
                                Text("Inactive models won't appear in the model picker.")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                    .tint(theme.brandPrimary)
                    .disabled(isTogglingActive)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 12)
                    .onChange(of: isActive) { oldVal, newVal in
                        guard isEditing, newVal != initialIsActive else { return }
                        initialIsActive = newVal
                        Task { await persistActiveToggle(id: existingModel?.id) }
                    }

                    Divider().background(theme.inputBorder.opacity(0.4))
                    accessControlSection
                }
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(grant.write ? theme.brandPrimary : theme.surfaceContainerHighest)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(grant.write ? Color.clear : theme.inputBorder.opacity(0.5), lineWidth: 1)
                        )
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
                if hasChanges { showDiscardConfirm = true } else { dismiss() }
            }
            .scaledFont(size: 16)
            .foregroundStyle(theme.textSecondary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView().tint(theme.brandPrimary)
            } else {
                Button("Save") {
                    Task { await save() }
                }
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(theme.brandPrimary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || modelId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Capability Checkbox

    @ViewBuilder
    private func capCheckbox(_ label: String, systemImage: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
            Haptics.play(.light)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square")
                    .scaledFont(size: 16)
                    .foregroundStyle(value.wrappedValue ? theme.brandPrimary : theme.textTertiary)
                Text(label)
                    .scaledFont(size: 13)
                    .foregroundStyle(value.wrappedValue ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helper Views

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

    // MARK: - Populate

    private func populateIfEditing() {
        guard let model = existingModel else { return }
        logger.info("[Populate] Loading existing model: id='\(model.id)' name='\(model.name)'")
        name = model.name
        modelId = model.id
        baseModelId = model.baseModelId ?? ""
        baseModelDisplayName = "" // will be resolved from available models after fetch
        description = model.description ?? ""
        tags = model.tags.joined(separator: ", ")
        isActive = model.isActive
        initialIsActive = model.isActive
        systemPrompt = model.systemPrompt
        ttsVoice = model.ttsVoice
        suggestionPrompts = model.suggestionPrompts
        useCustomPrompts = !model.suggestionPrompts.isEmpty
        knowledgeItems = model.knowledgeItems
        profileImageURL = model.profileImageURL

        capVision = model.capVision; capFileUpload = model.capFileUpload
        capFileContext = model.capFileContext; capWebSearch = model.capWebSearch
        capImageGeneration = model.capImageGeneration; capCodeInterpreter = model.capCodeInterpreter
        capUsage = model.capUsage; capCitations = model.capCitations
        capStatusUpdates = model.capStatusUpdates; capBuiltinTools = model.capBuiltinTools

        defaultWebSearch = model.defaultFeatureWebSearch
        defaultImageGen = model.defaultFeatureImageGen
        defaultCodeInterpreter = model.defaultFeatureCodeInterpreter

        builtinTime = model.builtinTime; builtinMemory = model.builtinMemory
        builtinChats = model.builtinChats; builtinNotes = model.builtinNotes
        builtinKnowledge = model.builtinKnowledge; builtinChannels = model.builtinChannels
        builtinWebSearch = model.builtinWebSearch; builtinImageGen = model.builtinImageGen
        builtinCodeInterpreter = model.builtinCodeInterpreter

        advStreamResponse = model.advStreamResponse
        advStreamDeltaChunkSize = model.advStreamDeltaChunkSize
        advFunctionCalling = model.advFunctionCalling
        advReasoningEffort = model.advReasoningEffort
        advReasoningTagStart = model.advReasoningTagStart
        advReasoningTagEnd = model.advReasoningTagEnd
        advSeed = model.advSeed
        advStopSequences = model.advStopSequences?.joined(separator: ", ")
        advTemperature = model.advTemperature
        advLogitBias = model.advLogitBias
        advMaxTokens = model.advMaxTokens
        advTopK = model.advTopK
        advTopP = model.advTopP
        advMinP = model.advMinP
        advFrequencyPenalty = model.advFrequencyPenalty
        advPresencePenalty = model.advPresencePenalty
        advMirostat = model.advMirostat
        advMirostatEta = model.advMirostatEta
        advMirostatTau = model.advMirostatTau
        advRepeatLastN = model.advRepeatLastN
        advTfsZ = model.advTfsZ
        advRepeatPenalty = model.advRepeatPenalty
        advUseMmap = model.advUseMmap
        advUseMlock = model.advUseMlock
        advThink = model.advThink
        advFormat = model.advFormat
        advNumKeep = model.advNumKeep
        advNumCtx = model.advNumCtx
        advNumBatch = model.advNumBatch
        advNumThread = model.advNumThread
        advNumGpu = model.advNumGpu
        advKeepAlive = model.advKeepAlive
        customParams = model.customParams

        let hasWildcard = model.accessGrants.contains { $0.userId == "*" }
        localAccessGrants = model.accessGrants.filter { $0.userId != "*" }
        isPrivate = !hasWildcard
        idManuallyEdited = true

        logger.info("[Populate] Done. baseModelId='\(model.baseModelId ?? "none")' knowledgeItems=\(model.knowledgeItems.count) profileImageURL='\(model.profileImageURL ?? "none")'")
    }

    // MARK: - Fetch Available Models

    private func fetchAvailableModels() async {
        guard let api = dependencies.apiClient else { return }
        isFetchingModels = true
        logger.info("[BaseModelPicker] Fetching available models...")
        do {
            let models = try await api.getModels()
            availableModels = models
            logger.info("[BaseModelPicker] Fetched \(models.count) models")
            // Resolve display name for the current baseModelId
            if !baseModelId.isEmpty {
                if let match = models.first(where: { $0.id == baseModelId }) {
                    baseModelDisplayName = match.name
                    logger.info("[BaseModelPicker] Resolved base model display name: '\(match.name)' for id='\(baseModelId)'")
                }
            }
        } catch {
            logger.error("[BaseModelPicker] Failed to fetch models: \(error.localizedDescription)")
        }
        isFetchingModels = false
    }

    // MARK: - Handle Photo Selection

    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        logger.info("[ProfileImage] Photo selected, loading data...")
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                logger.error("[ProfileImage] Failed to load photo data — nil result")
                return
            }
            // Resize to reasonable size (max 512x512) before encoding
            guard let uiImage = UIImage(data: data) else {
                logger.error("[ProfileImage] Failed to create UIImage from data (size: \(data.count) bytes)")
                return
            }
            let resized = resizeImage(uiImage, maxDimension: 512)
            guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
                logger.error("[ProfileImage] Failed to encode image as JPEG")
                return
            }
            let base64 = jpegData.base64EncodedString()
            let dataURI = "data:image/jpeg;base64,\(base64)"

            selectedImageData = jpegData
            profileImageURL = dataURI
            logger.info("[ProfileImage] Photo encoded as data URI — original size: \(data.count) bytes, jpeg size: \(jpegData.count) bytes, data URI length: \(dataURI.count) chars")
        } catch {
            logger.error("[ProfileImage] Error loading photo: \(error.localizedDescription)")
        }
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxCurrent = max(size.width, size.height)
        guard maxCurrent > maxDimension else { return image }
        let scale = maxDimension / maxCurrent
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Build Detail from Form State

    private func buildDetail(id: String) -> ModelDetail {
        var detail = ModelDetail(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            baseModelId: baseModelId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : baseModelId.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces).isEmpty ? nil : description.trimmingCharacters(in: .whitespaces),
            profileImageURL: profileImageURL,
            tags: tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            isActive: isActive,
            accessGrants: localAccessGrants,
            writeAccess: existingModel?.writeAccess ?? true,
            userId: existingModel?.userId ?? "",
            createdAt: existingModel?.createdAt,
            updatedAt: existingModel?.updatedAt,
            systemPrompt: systemPrompt,
            capVision: capVision, capFileUpload: capFileUpload, capFileContext: capFileContext,
            capWebSearch: capWebSearch, capImageGeneration: capImageGeneration, capCodeInterpreter: capCodeInterpreter,
            capUsage: capUsage, capCitations: capCitations, capStatusUpdates: capStatusUpdates, capBuiltinTools: capBuiltinTools,
            defaultFeatureWebSearch: defaultWebSearch, defaultFeatureImageGen: defaultImageGen, defaultFeatureCodeInterpreter: defaultCodeInterpreter,
            builtinTime: builtinTime, builtinMemory: builtinMemory, builtinChats: builtinChats,
            builtinNotes: builtinNotes, builtinKnowledge: builtinKnowledge, builtinChannels: builtinChannels,
            builtinWebSearch: builtinWebSearch, builtinImageGen: builtinImageGen, builtinCodeInterpreter: builtinCodeInterpreter,
            knowledgeItems: knowledgeItems,
            suggestionPrompts: suggestionPrompts,
            ttsVoice: ttsVoice.trimmingCharacters(in: .whitespaces)
        )
        detail.advStreamResponse = advStreamResponse
        detail.advStreamDeltaChunkSize = advStreamDeltaChunkSize
        detail.advFunctionCalling = advFunctionCalling
        detail.advReasoningEffort = advReasoningEffort
        detail.advReasoningTagStart = advReasoningTagStart
        detail.advReasoningTagEnd = advReasoningTagEnd
        detail.advSeed = advSeed
        detail.advStopSequences = advStopSequences.map {
            $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        detail.advTemperature = advTemperature
        detail.advLogitBias = advLogitBias
        detail.advMaxTokens = advMaxTokens
        detail.advTopK = advTopK
        detail.advTopP = advTopP
        detail.advMinP = advMinP
        detail.advFrequencyPenalty = advFrequencyPenalty
        detail.advPresencePenalty = advPresencePenalty
        detail.advMirostat = advMirostat
        detail.advMirostatEta = advMirostatEta
        detail.advMirostatTau = advMirostatTau
        detail.advRepeatLastN = advRepeatLastN
        detail.advTfsZ = advTfsZ
        detail.advRepeatPenalty = advRepeatPenalty
        detail.advUseMmap = advUseMmap
        detail.advUseMlock = advUseMlock
        detail.advThink = advThink
        detail.advFormat = advFormat
        detail.advNumKeep = advNumKeep
        detail.advNumCtx = advNumCtx
        detail.advNumBatch = advNumBatch
        detail.advNumThread = advNumThread
        detail.advNumGpu = advNumGpu
        detail.advKeepAlive = advKeepAlive
        detail.customParams = customParams.filter { !$0.key.isEmpty }
        return detail
    }

    // MARK: - Save

    private func save() async {
        guard let manager else { return }
        isSaving = true
        validationError = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedId = modelId.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationError = "Please enter a name for the model."
            isSaving = false; return
        }
        guard !trimmedId.isEmpty else {
            validationError = "Please enter a Model ID."
            isSaving = false; return
        }

        var allGrants = localAccessGrants.filter { $0.userId != "*" }
        if !isPrivate {
            allGrants.append(AccessGrant(id: UUID().uuidString, userId: "*", groupId: nil, read: true, write: false))
        }

        do {
            if let existing = existingModel {
                var detail = buildDetail(id: existing.id)
                detail.accessGrants = allGrants

                let payload = detail.toUpdatePayload()
                logger.info("[Save] Updating model id='\(existing.id)' name='\(trimmedName)'")
                if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    logger.debug("[Save] Update payload:\n\(jsonString)")
                }

                var updated = try await manager.update(detail)
                logger.info("[Save] Model updated successfully: id='\(updated.id)'")

                let updatedGrants = try await manager.updateAccessGrants(
                    modelId: existing.id,
                    modelName: trimmedName,
                    grants: localAccessGrants.filter { $0.userId != "*" },
                    isPublic: !isPrivate
                )
                updated.accessGrants = updatedGrants
                onSave?(updated)
            } else {
                var detail = buildDetail(id: trimmedId)
                detail.accessGrants = allGrants

                let payload = detail.toCreatePayload()
                logger.info("[Save] Creating model id='\(trimmedId)' name='\(trimmedName)' baseModelId='\(baseModelId)'")
                if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    logger.debug("[Save] Create payload:\n\(jsonString)")
                }

                let created = try await manager.create(from: detail)
                logger.info("[Save] Model created successfully: id='\(created.id)' name='\(created.name)'")
                onSave?(created)
            }
            dismiss()
        } catch {
            logger.error("[Save] Error saving model: \(error.localizedDescription)")
            validationError = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Access Control Actions

    private func handleAccessModeChange(isPrivate: Bool) async {
        guard let id = existingModel?.id, let manager else { return }
        logger.info("[Access] Changing access mode: isPrivate=\(isPrivate) for model='\(id)'")
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: localAccessGrants,
                isPublic: !isPrivate
            )
            localAccessGrants = updated
            logger.info("[Access] Access mode updated successfully")
            Haptics.notify(.success)
        } catch {
            self.isPrivate = !isPrivate
            accessUpdateError = error.localizedDescription
            logger.error("[Access] Error updating access mode: \(error.localizedDescription)")
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func addUsers(_ userIds: [String]) async {
        guard let id = existingModel?.id, let manager else {
            for userId in userIds {
                if !localAccessGrants.contains(where: { $0.userId == userId }) {
                    localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
                }
            }
            logger.info("[Access] Added \(userIds.count) users locally (no existing model)")
            Haptics.notify(.success)
            return
        }
        logger.info("[Access] Adding \(userIds.count) users to model='\(id)'")
        isUpdatingAccess = true
        var newGrants = localAccessGrants
        for userId in userIds {
            if !newGrants.contains(where: { $0.userId == userId }) {
                newGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
            }
        }
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: newGrants
            )
            localAccessGrants = updated
            logger.info("[Access] Users added successfully. Total grants: \(updated.count)")
            Haptics.notify(.success)
        } catch {
            accessUpdateError = error.localizedDescription
            logger.error("[Access] Error adding users: \(error.localizedDescription)")
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

        guard let id = existingModel?.id, let manager else {
            localAccessGrants = newGrants
            Haptics.play(.light)
            return
        }
        logger.info("[Access] Toggling permission for userId='\(userId)' from write=\(currentlyWrite) to write=\(!currentlyWrite)")
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: newGrants
            )
            localAccessGrants = updated
            Haptics.play(.light)
        } catch {
            accessUpdateError = error.localizedDescription
            logger.error("[Access] Error toggling permission: \(error.localizedDescription)")
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func removeUser(_ userId: String) async {
        guard let id = existingModel?.id, let manager else {
            localAccessGrants.removeAll { $0.userId == userId }
            Haptics.play(.light)
            return
        }
        logger.info("[Access] Removing userId='\(userId)' from model='\(id)'")
        withAnimation(.easeInOut(duration: 0.2)) {
            localAccessGrants.removeAll { $0.userId == userId }
        }
        isUpdatingAccess = true
        do {
            let updated = try await manager.updateAccessGrants(
                modelId: id,
                modelName: existingModel?.name ?? name,
                grants: localAccessGrants
            )
            localAccessGrants = updated
            logger.info("[Access] User removed. Remaining grants: \(updated.count)")
            Haptics.play(.light)
        } catch {
            if let detail = try? await manager.getDetail(id: id) {
                localAccessGrants = detail.accessGrants.filter { $0.userId != "*" }
            }
            accessUpdateError = error.localizedDescription
            logger.error("[Access] Error removing user: \(error.localizedDescription)")
            Haptics.notify(.error)
        }
        isUpdatingAccess = false
    }

    private func persistActiveToggle(id: String?) async {
        guard let id, let manager else { return }
        logger.info("[Toggle] Toggling active state for model='\(id)' to isActive=\(isActive)")
        isTogglingActive = true
        do {
            try await manager.toggle(id: id)
            logger.info("[Toggle] Active state toggled successfully")
            Haptics.play(.light)
        } catch {
            isActive = !isActive
            initialIsActive = isActive
            accessUpdateError = error.localizedDescription
            logger.error("[Toggle] Error toggling active state: \(error.localizedDescription)")
            Haptics.notify(.error)
        }
        isTogglingActive = false
    }
}

// MARK: - BaseModelPickerSheet

struct BaseModelPickerSheet: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    var availableModels: [AIModel]
    var selectedModelId: String
    var serverBaseURL: String
    var authToken: String?
    var onSelect: (AIModel) -> Void
    var onClear: () -> Void
    var onDismiss: () -> Void

    @State private var searchText = ""

    private let logger = Logger(subsystem: "com.openui", category: "ModelEditor")

    private var filtered: [AIModel] {
        guard !searchText.isEmpty else { return availableModels }
        return availableModels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if availableModels.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "cpu")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(theme.textTertiary)
                        Text("No Models Found")
                            .scaledFont(size: 17, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                        Text("Could not load available models from the server.")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !selectedModelId.isEmpty {
                            Section {
                                Button {
                                    onClear()
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color.red.opacity(0.12))
                                                .frame(width: 36, height: 36)
                                            Image(systemName: "xmark")
                                                .scaledFont(size: 14, weight: .medium)
                                                .foregroundStyle(.red)
                                        }
                                        Text("None (clear selection)")
                                            .scaledFont(size: 15)
                                            .foregroundStyle(.red)
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(theme.surfaceContainer.opacity(0.4))
                            }
                        }

                        Section {
                            ForEach(filtered) { model in
                                Button {
                                    logger.info("[BaseModelPicker] User selected model: id='\(model.id)' name='\(model.name)'")
                                    onSelect(model)
                                } label: {
                                    HStack(spacing: 12) {
                                        ModelAvatar(
                                            size: 36,
                                            imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                                            label: model.name,
                                            authToken: authToken
                                        )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(model.name)
                                                .scaledFont(size: 15, weight: .medium)
                                                .foregroundStyle(theme.textPrimary)
                                                .lineLimit(1)
                                            Text(model.id)
                                                .scaledFont(size: 12)
                                                .foregroundStyle(theme.textTertiary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if model.id == selectedModelId {
                                            Image(systemName: "checkmark.circle.fill")
                                                .scaledFont(size: 18)
                                                .foregroundStyle(theme.brandPrimary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(model.id == selectedModelId
                                    ? theme.brandPrimary.opacity(0.08)
                                    : theme.surfaceContainer.opacity(0.4))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle("Select Base Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models…")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { onDismiss() }
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .onAppear {
            logger.info("[BaseModelPicker] Sheet opened. Available models: \(availableModels.count). Currently selected: '\(selectedModelId)'")
        }
    }
}

// MARK: - ModelAdvancedParamsSection (extracted child struct to prevent stack overflow)

/// All 30+ advanced parameter rows are in this separate struct so the Swift
/// compiler/runtime evaluates them in their own stack frame rather than
/// contributing to the parent's already-deep body evaluation.
struct ModelAdvancedParamsSection: View {
    @Environment(\.theme) private var theme

    @Binding var showAdvancedParams: Bool

    @Binding var advStreamResponse: Bool?
    @Binding var advStreamDeltaChunkSize: Int?
    @Binding var advFunctionCalling: String?
    @Binding var advReasoningEffort: String?
    @Binding var advReasoningTagStart: String?
    @Binding var advReasoningTagEnd: String?
    @Binding var advSeed: Int?
    @Binding var advStopSequences: String?
    @Binding var advTemperature: Double?
    @Binding var advLogitBias: String?
    @Binding var advMaxTokens: Int?
    @Binding var advTopK: Int?
    @Binding var advTopP: Double?
    @Binding var advMinP: Double?
    @Binding var advFrequencyPenalty: Double?
    @Binding var advPresencePenalty: Double?
    @Binding var advMirostat: Int?
    @Binding var advMirostatEta: Double?
    @Binding var advMirostatTau: Double?
    @Binding var advRepeatLastN: Int?
    @Binding var advTfsZ: Double?
    @Binding var advRepeatPenalty: Double?
    @Binding var advUseMmap: Bool?
    @Binding var advUseMlock: Bool?
    @Binding var advThink: Bool?
    @Binding var advFormat: String?
    @Binding var advNumKeep: Int?
    @Binding var advNumCtx: Int?
    @Binding var advNumBatch: Int?
    @Binding var advNumThread: Int?
    @Binding var advNumGpu: Int?
    @Binding var advKeepAlive: String?
    @Binding var customParams: [(key: String, value: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showAdvancedParams.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack {
                    Text("ADVANCED PARAMS")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.leading, 4)
                    Spacer()
                    Image(systemName: showAdvancedParams ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if showAdvancedParams {
                advancedParamsContent
            }
        }
    }

    // Split into two halves to keep individual body depth low
    private var advancedParamsContent: some View {
        VStack(spacing: 0) {
            advParamsFirstHalf
            advParamsSecondHalf
        }
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                .stroke(theme.inputBorder.opacity(0.3), lineWidth: 1)
        )
    }

    // First half: stream, function calling, reasoning, seed, stop, temperature, logit, max_tokens, top_k, top_p, min_p, freq, presence
    private var advParamsFirstHalf: some View {
        VStack(spacing: 0) {
            advBoolRow(label: "Stream Chat Response", value: $advStreamResponse)
            divider
            advIntSliderRow(label: "Stream Delta Chunk Size", value: $advStreamDeltaChunkSize, range: 1...1000, step: 1)
            divider
            advNativeToggleRow(label: "Function Calling", value: $advFunctionCalling)
            divider
            advTextRow(label: "Reasoning Effort", placeholder: "e.g. low, medium, high", value: $advReasoningEffort)
            divider
            advReasoningTagsRow
            divider
            advIntSliderRow(label: "Seed", value: $advSeed, range: 0...9999, step: 1)
            divider
            advTextRow(label: "Stop Sequence", placeholder: "Comma-separated", value: $advStopSequences)
            divider
            advDoubleSliderRow(label: "Temperature", tooltip: "The temperature of the model. Increasing the temperature will make the model answer more creatively.", value: $advTemperature, range: 0...2, step: 0.05)
            divider
            advTextRow(label: "logit_bias", placeholder: "Enter comma-separated \"token:bias_value\" pairs (example: 5432:100, 413:-100)", value: $advLogitBias)
            divider
            advIntSliderRow(label: "max_tokens", value: $advMaxTokens, range: 0...32768, step: 128)
            divider
            advIntSliderRow(label: "top_k", value: $advTopK, range: 0...100, step: 1)
            divider
            advDoubleSliderRow(label: "top_p", tooltip: nil, value: $advTopP, range: 0...1, step: 0.05)
            divider
            advDoubleSliderRow(label: "min_p", tooltip: nil, value: $advMinP, range: 0...1, step: 0.05)
            divider
            advDoubleSliderRow(label: "frequency_penalty", tooltip: nil, value: $advFrequencyPenalty, range: -2...2, step: 0.05)
            divider
            advDoubleSliderRow(label: "presence_penalty", tooltip: nil, value: $advPresencePenalty, range: -2...2, step: 0.05)
        }
    }

    // Second half: mirostat, repeat, use_mmap, use_mlock, think, format, num_keep, num_ctx, num_batch, num_thread, num_gpu, keep_alive, custom
    private var advParamsSecondHalf: some View {
        VStack(spacing: 0) {
            divider
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable Mirostat sampling for controlling perplexity.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            advIntSliderRow(label: "mirostat", value: $advMirostat, range: 0...2, step: 1)
            divider
            advDoubleSliderRow(label: "mirostat_eta", tooltip: nil, value: $advMirostatEta, range: 0...1, step: 0.01)
            divider
            advDoubleSliderRow(label: "mirostat_tau", tooltip: nil, value: $advMirostatTau, range: 0...10, step: 0.1)
            divider
            advIntSliderRow(label: "repeat_last_n", value: $advRepeatLastN, range: 0...512, step: 8)
            divider
            advDoubleSliderRow(label: "tfs_z", tooltip: nil, value: $advTfsZ, range: 0...2, step: 0.05)
            divider
            advDoubleSliderRow(label: "repeat_penalty", tooltip: nil, value: $advRepeatPenalty, range: 0...2, step: 0.05)
            divider
            advBoolRow(label: "use_mmap", value: $advUseMmap)
            divider
            advBoolRow(label: "use_mlock", value: $advUseMlock)
            divider
            advBoolRow(label: "think (Ollama)", value: $advThink)
            divider
            advTextRow(label: "format (Ollama)", placeholder: "e.g. json", value: $advFormat)
            divider
            advIntSliderRow(label: "num_keep (Ollama)", value: $advNumKeep, range: 0...512, step: 8)
            divider
            advIntSliderRow(label: "num_ctx (Ollama)", value: $advNumCtx, range: 512...32768, step: 512)
            divider
            advIntSliderRow(label: "num_batch (Ollama)", value: $advNumBatch, range: 1...1024, step: 16)
            divider
            advIntSliderRow(label: "num_thread (Ollama)", value: $advNumThread, range: 1...32, step: 1)
            divider
            VStack(alignment: .leading, spacing: 4) {
                Text("Set the number of layers, which will be off-loaded to GPU. Increasing this value can significantly improve performance for models that are optimized for GPU acceleration but may also consume more power and GPU resources.")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            advIntSliderRow(label: "num_gpu (Ollama)", value: $advNumGpu, range: 0...128, step: 1)
            divider
            advTextRow(label: "keep_alive (Ollama)", placeholder: "e.g. 5m", value: $advKeepAlive)
            divider
            customParamsSection
        }
    }

    private var divider: some View {
        Divider().background(theme.inputBorder.opacity(0.3))
    }

    // MARK: - Reasoning Tags Row

    private var advReasoningTagsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reasoning Tags")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                let isCustom = advReasoningTagStart != nil || advReasoningTagEnd != nil
                if isCustom {
                    Button {
                        advReasoningTagStart = nil
                        advReasoningTagEnd = nil
                        Haptics.play(.light)
                    } label: { defaultPill }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        advReasoningTagStart = "<think>"
                        advReasoningTagEnd = "</think>"
                        Haptics.play(.light)
                    } label: { defaultPill }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 10)

            if advReasoningTagStart != nil || advReasoningTagEnd != nil {
                HStack(spacing: Spacing.md) {
                    TextField("Start Tag", text: Binding(
                        get: { advReasoningTagStart ?? "" },
                        set: { advReasoningTagStart = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    TextField("End Tag", text: Binding(
                        get: { advReasoningTagEnd ?? "" },
                        set: { advReasoningTagEnd = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .padding(8)
                    .background(theme.surfaceContainer.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }

    // MARK: - Custom Params Section

    private var customParamsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Custom Parameters")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    customParams.append((key: "", value: ""))
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "plus.circle")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.brandPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)

            ForEach(Array(customParams.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: Spacing.sm) {
                    TextField("Key", text: Binding(
                        get: { customParams[idx].key },
                        set: { customParams[idx].key = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .frame(maxWidth: .infinity)

                    Text(":").foregroundStyle(theme.textTertiary)

                    TextField("Value", text: Binding(
                        get: { customParams[idx].value },
                        set: { customParams[idx].value = $0 }
                    ))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textPrimary)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .frame(maxWidth: .infinity)

                    Button {
                        customParams.remove(at: idx)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .scaledFont(size: 16)
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 8)
                Divider().background(theme.inputBorder.opacity(0.3))
            }
        }
    }

    // MARK: - Reusable Pill

    private var defaultPill: some View {
        Text("Default")
            .scaledFont(size: 11)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.surfaceContainer)
            .clipShape(Capsule())
    }

    // MARK: - Row Builders

    @ViewBuilder
    private func advBoolRow(label: String, value: Binding<Bool?>) -> some View {
        let isCustom = value.wrappedValue != nil
        HStack {
            Text(label)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if isCustom {
                Text(value.wrappedValue == true ? "On" : "Off")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                Toggle("", isOn: Binding(
                    get: { value.wrappedValue ?? false },
                    set: { value.wrappedValue = $0 }
                ))
                .tint(theme.brandPrimary)
                .labelsHidden()
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }
                    .buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = false; Haptics.play(.light) } label: { defaultPill }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func advDoubleSliderRow(label: String, tooltip: String?, value: Binding<Double?>, range: ClosedRange<Double>, step: Double) -> some View {
        let isCustom = value.wrappedValue != nil
        VStack(alignment: .leading, spacing: 4) {
            if let tip = tooltip {
                Text(tip)
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.top, 8)
            }
            HStack {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                Spacer()
                if isCustom {
                    Text(String(format: "%.2f", value.wrappedValue ?? 0))
                        .scaledFont(size: 12, weight: .semibold).foregroundStyle(theme.brandPrimary).monospacedDigit()
                    Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                } else {
                    Button { value.wrappedValue = (range.lowerBound + range.upperBound) / 2; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, tooltip == nil ? 10 : 2)

            if isCustom {
                Slider(value: Binding(get: { value.wrappedValue ?? range.lowerBound }, set: { value.wrappedValue = $0 }), in: range, step: step)
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }

    @ViewBuilder
    private func advIntSliderRow(label: String, value: Binding<Int?>, range: ClosedRange<Double>, step: Double) -> some View {
        let isCustom = value.wrappedValue != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                Spacer()
                if isCustom {
                    Text("\(value.wrappedValue ?? 0)")
                        .scaledFont(size: 12, weight: .semibold).foregroundStyle(theme.brandPrimary).monospacedDigit()
                    Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                } else {
                    Button { value.wrappedValue = Int((range.lowerBound + range.upperBound) / 2); Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, 10)

            if isCustom {
                Slider(value: Binding(get: { Double(value.wrappedValue ?? Int(range.lowerBound)) }, set: { value.wrappedValue = Int($0) }), in: range, step: step)
                    .tint(theme.brandPrimary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, 8)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }

    @ViewBuilder
    private func advTextRow(label: String, placeholder: String, value: Binding<String?>) -> some View {
        let isCustom = value.wrappedValue != nil
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
                if isCustom {
                    TextField(placeholder, text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 }))
                        .scaledFont(size: 13).foregroundStyle(theme.textSecondary)
                        .autocorrectionDisabled().autocapitalization(.none)
                } else {
                    Text(placeholder).scaledFont(size: 12).foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            if isCustom {
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = ""; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    /// Simple Default / Native toggle for function_calling.
    /// nil = Default (not sent), "native" = Native
    @ViewBuilder
    private func advNativeToggleRow(label: String, value: Binding<String?>) -> some View {
        let isNative = value.wrappedValue == "native"
        HStack {
            Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
            Spacer()
            if isNative {
                Text("Native")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }
                    .buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = "native"; Haptics.play(.light) } label: { defaultPill }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func advPickerRow(label: String, value: Binding<String?>, options: [String]) -> some View {
        let isCustom = value.wrappedValue != nil
        HStack {
            Text(label).scaledFont(size: 14).foregroundStyle(theme.textPrimary)
            Spacer()
            if isCustom {
                Picker("", selection: Binding(get: { value.wrappedValue ?? options.first ?? "" }, set: { value.wrappedValue = $0 })) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).tint(theme.brandPrimary).scaledFont(size: 14)
                Button { value.wrappedValue = nil; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            } else {
                Button { value.wrappedValue = options.first ?? ""; Haptics.play(.light) } label: { defaultPill }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }
}
