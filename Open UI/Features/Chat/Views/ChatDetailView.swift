import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import QuickLook
import MarkdownView

// MARK: - Chat Detail View

struct ChatDetailView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let initialConversationId: String?
    @State private var viewModel: ChatViewModel

    // MARK: Scroll state (iOS 18 ScrollPosition API)
    /// iOS 18+ declarative scroll position. Used with `.scrollPosition($scrollPosition)`
    /// to drive programmatic scrolling via `scrollTo(edge:)`.
    @State private var scrollPosition: ScrollPosition = .init()
    /// True when the user has manually scrolled away from the bottom.
    @State private var isScrolledUp = false
    /// Last known contentOffset.y — used to detect user-initiated upward drags.
    @State private var lastScrollOffset: CGFloat = 0
    /// Cached scroll content height — updated via a separate onScrollGeometryChange.
    @State private var viewState_contentHeight: CGFloat = 0
    /// Cached scroll container height — updated via a separate onScrollGeometryChange.
    @State private var viewState_containerHeight: CGFloat = 0


    // MARK: UI state
    @State private var showCopiedToast = false
    @State private var activeActionMessageId: String?
    @State private var activeVersionIndex: [String: Int] = [:]
    @State private var speakingMessageId: String?
    @State private var sourcesSheetMessage: ChatMessage?
    @State private var randomPrompts: [SuggestedPrompt] = []

    // MARK: Model mention (@ trigger)
    @State private var isShowingModelPicker = false
    @State private var modelPickerQuery = ""
    @State private var mentionedModel: AIModel? = nil

    // MARK: Inline edit
    @State private var editingMessageId: String?
    @State private var editingMessageText = ""
    @FocusState private var isEditFieldFocused: Bool

    // MARK: Keyboard
    @State private var keyboard = KeyboardTracker()

    // MARK: Attachment pickers
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showFilePicker = false
    @State private var showAudioPicker = false
    @State private var showCameraPicker = false
    @State private var showWebURLAlert = false
    @State private var webURLInput = ""


    // MARK: File download & preview
    @State private var isDownloadingFile = false
    @State private var downloadedFileURL: URL?
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""
    /// URL for QuickLook in-app file preview (PDF, images, docs, etc.)
    @State private var previewFileURL: URL?
    /// Code preview from MarkdownView's eye button (fullscreen code view)
    @State private var codePreviewCode: String?
    @State private var codePreviewLanguage: String = ""

    // MARK: Init

    init(conversationId: String, viewModel: ChatViewModel) {
        self.initialConversationId = conversationId
        self._viewModel = State(initialValue: viewModel)
    }

    init(viewModel: ChatViewModel) {
        self.initialConversationId = nil
        self._folderWorkspace = nil
        self._viewModel = State(initialValue: viewModel)
    }

    // MARK: - Folder Workspace Init

    /// Creates a ChatDetailView in "folder workspace" mode.
    /// When `folderWorkspace` is set, the welcome/empty state shows the folder
    /// icon + name centered (matching the web UI). New chats are created inside
    /// the folder with its system prompt injected.
    init(viewModel: ChatViewModel, folderWorkspace: ChatFolder?) {
        self.initialConversationId = nil
        self._folderWorkspace = folderWorkspace
        self._viewModel = State(initialValue: viewModel)
    }

    private var _folderWorkspace: ChatFolder?

    // MARK: - Body

    var body: some View {
        @Bindable var vm = viewModel

        ZStack {
            theme.background.ignoresSafeArea()
            messageListArea
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputFieldArea(vm: vm)
                .padding(.bottom, keyboard.height)
        }
        .ignoresSafeArea(.keyboard)
        // Knowledge picker — overlays content (floats over welcome cards / messages)
        .overlay(alignment: .bottom) {
            if vm.isShowingKnowledgePicker {
                KnowledgePickerView(
                    query: vm.knowledgeSearchQuery,
                    items: vm.knowledgeItems,
                    isLoading: vm.isLoadingKnowledge,
                    onSelect: { item in
                        viewModel.selectKnowledgeItem(item)
                    },
                    onDismiss: {
                        viewModel.dismissKnowledgePicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.2), value: vm.isShowingKnowledgePicker)
            }
        }
        // Prompt picker — overlays content (floats over welcome cards / messages)
        .overlay(alignment: .bottom) {
            if vm.isShowingPromptPicker {
                PromptPickerView(
                    query: vm.promptSearchQuery,
                    prompts: vm.availablePrompts,
                    isLoading: vm.isLoadingPrompts,
                    onSelect: { prompt in
                        viewModel.selectPrompt(prompt)
                    },
                    onDismiss: {
                        viewModel.dismissPromptPicker()
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.2), value: vm.isShowingPromptPicker)
            }
        }
        // Model picker — overlays content (floats over welcome cards / messages)
        .overlay(alignment: .bottom) {
            if isShowingModelPicker {
                ModelPickerView(
                    query: modelPickerQuery,
                    models: vm.availableModels,
                    serverBaseURL: vm.serverBaseURL,
                    authToken: vm.serverAuthToken,
                    onSelect: { model in
                        withAnimation(.easeOut(duration: 0.15)) {
                            mentionedModel = model
                            viewModel.mentionedModelId = model.id
                        }
                        viewModel.removeMentionToken()
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                        Haptics.play(.light)
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.2), value: isShowingModelPicker)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            keyboard.start()
            if let manager = dependencies.conversationManager {
                viewModel.configure(with: manager, socket: dependencies.socketService, store: dependencies.activeChatStore, asr: dependencies.asrService)
            }
            // Perform non-async setup before awaiting load() so the UI
            // populates prompts and temporary-chat state instantly.
            if viewModel.isNewConversation {
                viewModel.isTemporaryChat = UserDefaults.standard.bool(forKey: "temporaryChatDefault")
            }
            // Prompts are populated via the .onChange(initial: true) below —
        // no need to build them here. The onChange fires synchronously on
        // first evaluation, so prompts are always in sync with backendConfig.
            NotificationService.shared.activeConversationId =
                viewModel.conversationId ?? viewModel.conversation?.id
            await viewModel.load()
        }
        // Build welcome prompts from server config — fires immediately on first render
        // (initial: true) AND whenever the config changes later. This covers:
        //   • First app launch: backendConfig loads asynchronously after view appears.
        //     initial: true fires once synchronously on view attach (prompts = [] if
        //     config not yet ready), then fires again when config arrives.
        //   • Subsequent launches: config is already loaded — initial: true fires
        //     synchronously with the correct data, so prompts are populated instantly.
        //   • Admin updates suggestions while app is running — fires on count change.
        .onChange(of: dependencies.authViewModel.backendConfig?.defaultPromptSuggestions?.count, initial: true) { _, _ in
            let suggestions = dependencies.authViewModel.backendConfig?.defaultPromptSuggestions
            randomPrompts = Self.buildServerPrompts(from: suggestions, count: promptCardCount)
        }
        .onDisappear {
            keyboard.stop()
            NotificationService.shared.activeConversationId = nil
        }
        // Stop TTS when app enters background to prevent Metal GPU crashes
        // and keep the speakingMessageId state in sync with actual playback.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if speakingMessageId != nil {
                dependencies.textToSpeechService.stop()
                speakingMessageId = nil
            }
        }
        // Toasts & banners
        .overlay(alignment: .top) {
            if showCopiedToast { copiedToastView }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                errorBannerView(error)
                    .padding(.bottom, keyboard.height + 80)
            }
        }
        // Sheets & alerts
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { urls in
                Task {
                    for url in urls {
                        let ext = url.pathExtension.lowercased()
                        let audioExts = ["mp3","wav","m4a","aac","flac","ogg","caf","aiff","wma"]
                        if audioExts.contains(ext) {
                            await processAudioFileURL(url)
                        } else {
                            await processFileURL(url)
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView { image in processCameraImage(image) }
                .ignoresSafeArea()
        }
        .alert("Add Web Link", isPresented: $showWebURLAlert) {
            TextField("https://example.com", text: $webURLInput)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocapitalization(.none)
            Button("Cancel", role: .cancel) { webURLInput = "" }
            Button("Add") { processWebURL() }
        } message: {
            Text("Enter a URL to include as context in your message.")
        }
        .onChange(of: selectedPhotos) { _, newItems in
            Task { await processSelectedPhotos(newItems); selectedPhotos = [] }
        }
        // Pick up files shared from other apps via "Open In" / document import.
        // The version counter fires this even when the view is already visible.
        .onChange(of: dependencies.pendingIncomingFileVersion) { _, _ in
            if let file = dependencies.pendingIncomingFile {
                viewModel.attachments.append(file)
                // Trigger immediate upload for shared files (via "Open In")
                viewModel.uploadAttachmentImmediately(attachmentId: file.id)
                dependencies.pendingIncomingFile = nil
            }
        }
        .sheet(item: $sourcesSheetMessage) { message in
            SourcesDetailSheet(sources: message.sources)
        }
        // Prompt variable input sheet — shown when a selected prompt has {{variables}}
        .sheet(isPresented: Binding<Bool>(
            get: { viewModel.pendingPromptForVariables != nil },
            set: { if !$0 { viewModel.cancelPromptVariables() } }
        )) {
            if let prompt = viewModel.pendingPromptForVariables {
                PromptVariableSheet(
                    promptName: prompt.name,
                    variables: viewModel.pendingPromptVariables,
                    onSave: { values in
                        viewModel.submitPromptVariables(values: values)
                    },
                    onCancel: {
                        viewModel.cancelPromptVariables()
                    }
                )
            }
        }
        // Intercept link taps from MarkdownView: download server file URLs
        // with auth instead of opening Safari (the user may not be logged in
        // to the browser). MarkdownView posts a notification instead of
        // calling UIApplication.shared.open directly, so we can route the
        // URL through our authenticated download flow.
        .onReceive(NotificationCenter.default.publisher(for: .markdownLinkTapped)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            let urlString = url.absoluteString
            let base = viewModel.serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // Server file URL → download with auth token and present share sheet
            if !base.isEmpty, urlString.hasPrefix(base), urlString.contains("/api/v1/files/"),
               urlString.hasSuffix("/content") {
                let parts = urlString.split(separator: "/")
                if let filesIdx = parts.firstIndex(of: "files"),
                   filesIdx + 1 < parts.count {
                    let fileId = String(parts[filesIdx + 1])
                    Task { await downloadAndShareFile(fileId: fileId) }
                    return
                }
            }

            // All other URLs → open in Safari normally
            UIApplication.shared.open(url)
        }
        .overlay {
            if isDownloadingFile {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Downloading…")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.white)
                    }
                    .padding(Spacing.lg)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .alert("Download Failed", isPresented: $showDownloadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadErrorMessage)
        }
        .sheet(item: $downloadedFileURL) { url in
            ShareSheetView(activityItems: [url])
        }
        // In-app file preview using QuickLook (PDFs, images, docs, etc.)
        .quickLookPreview($previewFileURL)
        // Fullscreen code preview — triggered by eye button in code blocks
        .onReceive(NotificationCenter.default.publisher(for: .markdownCodePreview)) { notification in
            if let code = notification.userInfo?["code"] as? String {
                codePreviewLanguage = notification.userInfo?["language"] as? String ?? ""
                codePreviewCode = code
            }
        }
        .sheet(item: $codePreviewCode) { code in
            FullCodeView(code: code, language: codePreviewLanguage)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: Spacing.sm) {
                modelSelectorButton
                if viewModel.isTemporaryChat {
                    Image(systemName: "eye.slash.fill")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.warning)
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if viewModel.messages.isEmpty {
                Button {
                    withAnimation(MicroAnimation.snappy) {
                        viewModel.isTemporaryChat.toggle()
                    }
                    Haptics.play(.light)
                } label: {
                    Image(systemName: viewModel.isTemporaryChat ? "eye.slash.fill" : "eye")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(viewModel.isTemporaryChat ? theme.warning : theme.textTertiary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isTemporaryChat ? "Temporary chat on" : "Temporary chat off")
            }
        }
    }

    private var modelSelectorButton: some View {
        Group {
            if viewModel.availableModels.isEmpty {
                Text(viewModel.conversation?.title ?? String(localized: "New Chat"))
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Menu {
                    ForEach(viewModel.availableModels) { model in
                        Button {
                            withAnimation(MicroAnimation.snappy) { viewModel.selectModel(model.id) }
                        } label: {
                            HStack {
                                Text(model.name)
                                if model.id == viewModel.selectedModelId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if let model = viewModel.selectedModel {
                            ModelAvatar(
                                size: 22,
                                imageURL: viewModel.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: viewModel.serverAuthToken
                            )
                            .fixedSize()
                        }
                        Text(viewModel.selectedModel?.shortName ?? String(localized: "Select Model"))
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                    }
                }
                // Refresh model list silently when user opens the picker
                .onTapGesture { viewModel.refreshModelsInBackground() }
            }
        }
        // Cap the model selector width so long names truncate
        // instead of pushing into trailing toolbar buttons.
        .frame(maxWidth: 220)
    }

    // MARK: - Input Field Area

    @ViewBuilder
    private func inputFieldArea(vm: ChatViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            ChatInputField(
                text: $vm.inputText,
                attachments: $vm.attachments,
                placeholder: placeholderText,
                isEnabled: !vm.isStreaming,
                onSend: { Task { await viewModel.sendMessage() } },
                onStopGenerating: vm.isStreaming ? { viewModel.stopStreaming() } : nil,
                webSearchEnabled: $vm.webSearchEnabled,
                imageGenerationEnabled: $vm.imageGenerationEnabled,
                codeInterpreterEnabled: $vm.codeInterpreterEnabled,
                isWebSearchAvailable: isFeatureAvailable("web_search", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableWebSearch),
                isImageGenerationAvailable: isFeatureAvailable("image_generation", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableImageGeneration),
                isCodeInterpreterAvailable: isFeatureAvailable("code_interpreter", serverEnabled: dependencies.authViewModel.backendConfig?.features?.enableCodeInterpreter),
                tools: vm.availableTools,
                selectedToolIds: $vm.selectedToolIds,
                isLoadingTools: vm.isLoadingTools,
                terminalEnabled: vm.terminalEnabled,
                isTerminalAvailable: !vm.availableTerminalServers.isEmpty,
                terminalServerName: vm.selectedTerminalServer?.displayName ?? "",
                availableTerminalServers: vm.availableTerminalServers,
                onTerminalToggle: { viewModel.toggleTerminal() },
                onTerminalServerSelected: { server in
                    viewModel.selectedTerminalServer = server
                },
                onBrowseFiles: nil,
                mentionedModel: $mentionedModel,
                mentionedModelImageURL: mentionedModel.flatMap { viewModel.resolvedImageURL(for: $0) },
                mentionedModelAuthToken: viewModel.serverAuthToken,
                onAtTrigger: { query in
                    modelPickerQuery = query
                    if !isShowingModelPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isShowingModelPicker = true
                        }
                        viewModel.refreshModelsInBackground()
                    }
                },
                onAtDismiss: {
                    if isShowingModelPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isShowingModelPicker = false
                            modelPickerQuery = ""
                        }
                    }
                },
                selectedKnowledgeItems: $vm.selectedKnowledgeItems,
                onHashTrigger: { query in
                    viewModel.knowledgeSearchQuery = query
                    if !viewModel.isShowingKnowledgePicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.isShowingKnowledgePicker = true
                        }
                        viewModel.loadKnowledgeItems()
                    }
                },
                onHashDismiss: {
                    if viewModel.isShowingKnowledgePicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissKnowledgePicker()
                        }
                    }
                },
                onSlashTrigger: { query in
                    viewModel.promptSearchQuery = query
                    if !viewModel.isShowingPromptPicker {
                        withAnimation(.easeOut(duration: 0.2)) {
                            viewModel.isShowingPromptPicker = true
                        }
                        viewModel.loadPrompts()
                    }
                },
                onSlashDismiss: {
                    if viewModel.isShowingPromptPicker {
                        withAnimation(.easeOut(duration: 0.15)) {
                            viewModel.dismissPromptPicker()
                        }
                    }
                },
                onFileAttachment: { showFilePicker = true },
                onPhotoAttachment: nil,
                onCameraCapture: { showCameraPicker = true },
                onWebAttachment: { showWebURLAlert = true },
                onVoiceInput: { toggleVoiceInput() },
                onToolsSheetPresented: {
                    Task { await viewModel.loadTools() }
                },
                photoPicker: AnyView(
                    PhotosPicker(
                        selection: $selectedPhotos,
                        maxSelectionCount: 5,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        photoPickerLabel
                    }
                )
            )
        }
        .background(theme.background)
        .animation(.easeOut(duration: 0.2), value: vm.isShowingKnowledgePicker)
        .animation(.easeOut(duration: 0.15), value: vm.selectedKnowledgeItems.count)
        // Sync mentionedModel → viewModel.mentionedModelId when user taps × on chip
        .onChange(of: mentionedModel) { _, newModel in
            viewModel.mentionedModelId = newModel?.id
        }
    }

    private var photoPickerLabel: some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [theme.brandPrimary.opacity(0.2), theme.brandPrimary.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 36, height: 36)
                Image(systemName: "photo")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }
            Text("Photo")
                .scaledFont(size: 12, weight: .medium)
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(theme.isDark ? 0.45 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var placeholderText: String {
        if let model = viewModel.selectedModel {
            return String(localized: "Message \(model.shortName)…")
        }
        return String(localized: "Message")
    }

    /// Checks whether a feature (web_search, image_generation, code_interpreter)
    /// should be visible in the tools sheet. A feature is available only when:
    /// 1. The server-level feature flag is enabled (from `/api/config`), AND
    /// 2. The selected model has that capability enabled (from `info.meta.capabilities`).
    ///
    /// If the admin unchecks a capability on the model, the toggle disappears
    /// from the app — the model simply can't use it.
    private func isFeatureAvailable(_ capabilityKey: String, serverEnabled: Bool?) -> Bool {
        // Server must have the feature enabled globally
        guard serverEnabled == true else { return false }
        // Model must have the capability enabled
        guard let model = viewModel.selectedModel,
              let caps = model.capabilities,
              let value = caps[capabilityKey] else {
            // If model has no capabilities dict at all, default to showing
            // (backward compat — older servers may not send capabilities)
            return serverEnabled == true
        }
        return ["1", "true"].contains(value.lowercased())
    }
    
    // MARK: - iPad Layout Helpers

    /// Maximum reading width for iPad. Content is centered in the available space.
    /// On iPhone, this is effectively unlimited (fills the screen).
    private var iPadMaxContentWidth: CGFloat {
        horizontalSizeClass == .regular ? 760 : .infinity
    }

    /// Number of columns in the welcome prompt grid.
    private var promptColumnCount: Int {
        horizontalSizeClass == .regular ? 4 : 2
    }

    /// Number of prompt cards to show (4 cols needs 8, 2 cols needs 4).
    private var promptCardCount: Int {
        horizontalSizeClass == .regular ? 8 : 4
    }

    // MARK: - Message List Area

    private var messageListArea: some View {
        ZStack {
            scrollContent

            // Welcome screen — shown when no messages and not loading
            if !viewModel.isLoadingConversation && viewModel.messages.isEmpty {
                if let folder = _folderWorkspace {
                    folderWelcomeView(folder: folder)
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                } else {
                    welcomeView
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }
            }
        }
        // FAB overlay
        .overlay(alignment: .bottomTrailing) {
            scrollToBottomFAB
        }
        .onAppear {
            // Snap instantly to bottom on chat open.
            scrollPosition.scrollTo(edge: .bottom)
        }
        // Auto-scroll: when a new message arrives and user is near bottom.
        .onChange(of: viewModel.messages.count) { old, new in
            guard new > old, !isScrolledUp else { return }
            if old == 0 {
                scrollPosition.scrollTo(edge: .bottom)
            } else if viewModel.shouldAnimateNewMessages {
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        // Streaming: scroll to bottom at start only. During streaming,
        // `.defaultScrollAnchor(.bottom)` keeps the view pinned. When
        // streaming ends, do NOT force a scroll — if the user manually
        // scrolled up during streaming they should stay where they are.
        .onChange(of: viewModel.isStreaming) { _, streaming in
            if streaming {
                isScrolledUp = false
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
            }
        }
        // Resume auto-scroll: when the user scrolls back to the bottom
        // (or taps the FAB) during an active stream, re-pin so new
        // tokens keep the view anchored at the bottom.
        .onChange(of: isScrolledUp) { oldValue, newValue in
            if oldValue == true && newValue == false && viewModel.isStreaming {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.isLoadingConversation {
                    loadingPlaceholders
                } else {
                    messagesList
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            // iPad: constrain content to reading width and center it.
            // iPhone: fills the full screen (maxWidth: .infinity).
            .frame(maxWidth: iPadMaxContentWidth)
            .frame(maxWidth: .infinity)
            // Ensure content fills the viewport so that when there are few
            // messages they appear at the top (alignment: .top) instead of
            // being pushed to the bottom by .defaultScrollAnchor(.bottom).
            // When content exceeds the viewport, minHeight has no effect.
            .frame(minHeight: max(viewState_containerHeight, 0), alignment: .top)
            // Clip content to container width — prevents follow-up suggestions
            // or other animated insertions from temporarily expanding the
            // scroll content width during layout, which would enable 2D panning.
            .clipped()
        }
        // Lock the underlying UIScrollView to vertical-only scrolling.
        // Even if a child view momentarily reports wider-than-container
        // content during animated insertion (e.g. follow-up suggestions),
        // horizontal panning/bounce is physically impossible.
        .background(ScrollViewHorizontalLock())
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition, anchor: .bottom)
        // Detect scroll position to show/hide FAB
        .onScrollGeometryChange(for: CGPoint.self) { geo in
            geo.contentOffset
        } action: { _, newOffset in
            let distanceFromBottom = max(0,
                viewState_contentHeight - newOffset.y - viewState_containerHeight)
            if distanceFromBottom <= 120 {
                if isScrolledUp { isScrolledUp = false }
            } else if newOffset.y < lastScrollOffset - 40 {
                if !isScrolledUp { isScrolledUp = true }
            }
            if abs(newOffset.y - lastScrollOffset) > 2 {
                lastScrollOffset = newOffset.y
            }
        }
        .onScrollGeometryChange(for: CGSize.self) { geo in
            CGSize(width: geo.contentSize.height, height: geo.containerSize.height)
        } action: { _, newSize in
            if abs(newSize.width - viewState_contentHeight) > 1 {
                viewState_contentHeight = newSize.width
            }
            if abs(newSize.height - viewState_containerHeight) > 1 {
                viewState_containerHeight = newSize.height
            }
        }
    }

    // MARK: - Scroll-to-Bottom FAB

    @ViewBuilder
    private var scrollToBottomFAB: some View {
        if isScrolledUp && !viewModel.messages.isEmpty && !viewModel.isLoadingConversation {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                Circle()
                    .strokeBorder(theme.cardBorder.opacity(0.35), lineWidth: 0.5)
                    .frame(width: 38, height: 38)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
            }
            .contentShape(Circle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    withAnimation { scrollPosition.scrollTo(edge: .bottom) }
                    Haptics.play(.light)
                }
            )
            .padding(.trailing, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.7).combined(with: .opacity),
                    removal: .scale(scale: 0.7).combined(with: .opacity)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7))
            )
            .accessibilityLabel("Scroll to bottom")
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - Loading Placeholders

    private var loadingPlaceholders: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                SkeletonChatMessage(isUser: i % 2 == 1, lineCount: i == 0 ? 2 : i == 2 ? 3 : 2)
                    .padding(.vertical, 4)
            }
        }
        .padding(.top, Spacing.lg)
    }

    // MARK: - Messages List

    /// Uses direct `ForEach(viewModel.messages)` with `Identifiable` conformance
    /// instead of `Array(viewModel.messages.enumerated())` which creates new tuples
    /// on every evaluation, forcing SwiftUI to re-evaluate identity for all rows.
    /// Index is resolved via a pre-built O(1) dictionary instead of O(n) `firstIndex(where:)`.
    private var messagesList: some View {
        let messages = viewModel.messages
        let indexMap = Dictionary(messages.enumerated().map { ($1.id, $0) },
                                  uniquingKeysWith: { first, _ in first })

        return ForEach(messages) { message in
            let index = indexMap[message.id] ?? 0
            messageRow(message: message, index: index)
                .id(message.id)
        }
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(message: ChatMessage, index: Int) -> some View {
        let isLastAssistant = message.role == .assistant && index == viewModel.messages.count - 1

        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {

            // ── Assistant header (avatar + model name) ──
            if message.role == .assistant {
                assistantHeader(for: message)
            }

            // ── Streaming status indicators ──
            // Isolated into its own struct so that reads of streamingStore
            // properties (streamingStatusHistory, streamingContent, isActive)
            // are attributed to IsolatedStreamingStatus.body — NOT to
            // ChatDetailView.body. This prevents the entire ChatDetailView
            // from re-evaluating on every streaming token.
            if message.role == .assistant {
                IsolatedStreamingStatus(
                    streamingStore: viewModel.streamingStore,
                    message: message
                )
            }

            // ── Message bubble / content ──
            messageBubble(for: message, isLastAssistant: isLastAssistant)

            // ── Tool-generated images ──
            if message.role == .assistant && !message.isStreaming {
                let vIdx = activeVersionIndex[message.id] ?? -1
                let displayFiles: [ChatMessageFile] = {
                    if vIdx >= 0 && vIdx < message.versions.count {
                        return message.versions[vIdx].files
                    }
                    return message.files
                }()
                if !displayFiles.isEmpty {
                    messageFilesView(files: displayFiles)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)
                }
            }

            // ── Sources bar ──
            if message.role == .assistant && !message.isStreaming {
                let vIdx = activeVersionIndex[message.id] ?? -1
                let displaySources: [ChatSourceReference] = {
                    if vIdx >= 0 && vIdx < message.versions.count {
                        return message.versions[vIdx].sources
                    }
                    return message.sources
                }()
                if !displaySources.isEmpty {
                    sourcesBar(sources: displaySources, messageId: message.id)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, Spacing.xs)
                }
            }

            // ── Inline error ──
            if let error = message.error {
                messageErrorView(error.content ?? String(localized: "An error occurred"))
                    .padding(.horizontal, Spacing.screenPadding)
            }

            // ── Assistant action bar (always visible) ──
            if message.role == .assistant && !message.isStreaming {
                assistantActionBar(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.xs)
            }

            // ── User action bar (tap-revealed) ──
            if message.role == .user && activeActionMessageId == message.id && !viewModel.isStreaming {
                userActionBar(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // ── Follow-up suggestions (last assistant message only) ──
            if isLastAssistant && !message.isStreaming && !message.followUps.isEmpty {
                followUpSuggestions(for: message)
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, Spacing.sm)
                    // Use simple opacity transition — .move(edge: .bottom) triggers
                    // a layout re-measurement during animation that can temporarily
                    // make the scroll content wider than the screen, enabling 2D pan.
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(message.role == .user ? "You" : "Assistant"): \(message.content.prefix(200))"))
    }

    // MARK: - Assistant Header

    private func resolveModel(for message: ChatMessage) -> AIModel? {
        if let mid = message.model,
           let model = viewModel.availableModels.first(where: { $0.id == mid }) {
            return model
        }
        return viewModel.selectedModel
    }

    private func assistantHeader(for message: ChatMessage) -> some View {
        let model = resolveModel(for: message)
        return HStack(spacing: Spacing.sm) {
            if let m = model {
                ModelAvatar(size: 22, imageURL: viewModel.resolvedImageURL(for: m),
                            label: m.shortName, authToken: viewModel.serverAuthToken)
            } else {
                ModelAvatar(size: 22, label: message.model)
            }
            Text(model?.shortName ?? message.model ?? String(localized: "Assistant"))
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, Spacing.sm)
        .padding(.bottom, 4)
    }

    // MARK: - Message Bubble

    @ViewBuilder
    private func messageBubble(for message: ChatMessage, isLastAssistant: Bool) -> some View {
        ChatMessageBubble(
            role: message.role,
            showTimestamp: activeActionMessageId == message.id,
            timestamp: message.timestamp
        ) {
            messageContent(for: message)
        }
        // Only apply tap gesture to user bubbles — assistant content contains
        // interactive elements (links, text selection) that onTapGesture would block.
        // Assistant action bar is always visible so no tap-reveal is needed.
        .if(message.role == .user) { view in
            view.onTapGesture {
                withAnimation(MicroAnimation.snappy) {
                    activeActionMessageId = activeActionMessageId == message.id ? nil : message.id
                }
                Haptics.play(.light)
            }
        }
        .if(message.role != .assistant) { view in
            view.contextMenu { messageContextMenu(for: message) }
        }
    }

    @ViewBuilder
    private func messageContextMenu(for message: ChatMessage) -> some View {
        Button { copyMessage(message) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if message.role == .user && !viewModel.isStreaming {
            Button { beginInlineEdit(message: message) } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        if message.role == .assistant && !viewModel.isStreaming {
            Button { Task { await viewModel.regenerateResponse(messageId: message.id) } } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        if !viewModel.isStreaming {
            Button(role: .destructive) {
                Task { await viewModel.deleteMessage(id: message.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Message Content

    @ViewBuilder
    private func messageContent(for message: ChatMessage) -> some View {
        if message.role == .user {
            if editingMessageId == message.id {
                inlineEditContent
            } else {
                VStack(alignment: .trailing, spacing: Spacing.sm) {
                    // Inline images inside the bubble
                    let imageFiles = message.files.filter { $0.type == "image" }
                    if !imageFiles.isEmpty {
                        ForEach(Array(imageFiles.prefix(4).enumerated()), id: \.offset) { _, file in
                            if let fileId = file.url, !fileId.isEmpty {
                                AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                                    .frame(maxWidth: 220, maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }

                    // Non-image file cards inside the bubble
                    let nonImageFiles = message.files.filter { $0.type != "image" && $0.type != "collection" && $0.type != "folder" }
                    if !nonImageFiles.isEmpty {
                        ForEach(Array(nonImageFiles.enumerated()), id: \.offset) { _, file in
                            fileAttachmentCard(file: file)
                        }
                    }

                    // Text content
                    if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(message.content)
                            .scaledFont(size: 15, context: .content)
                            .lineSpacing(2)
                    }
                }
            }
        } else {
            // ── STREAMING ISOLATION ──
            // All streaming store reads (streamingContent, streamingSources,
            // isActive, streamingMessageId) are moved into IsolatedAssistantMessage
            // — a separate struct whose body is the only thing that re-evaluates
            // on every token. ChatDetailView.body never touches these properties,
            // so it stays completely inert during streaming.
            IsolatedAssistantMessage(
                streamingStore: viewModel.streamingStore,
                message: message,
                activeVersionIndex: activeVersionIndex[message.id] ?? -1,
                serverBaseURL: viewModel.serverBaseURL
            )
        }
    }

    private func preprocessCitations(_ content: String, sources: [ChatSourceReference]) -> String {
        guard !sources.isEmpty else { return content }
        let pattern = #"\[(\d+)\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        var result = ""
        var searchStart = content.startIndex
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard let fullRange = Range(match.range, in: content),
                  let numberRange = Range(match.range(at: 1), in: content) else { continue }
            guard let index = Int(content[numberRange]) else { continue }
            result += content[searchStart..<fullRange.lowerBound]
            let sourceIdx = index - 1
            if sourceIdx >= 0 && sourceIdx < sources.count,
               let url = sources[sourceIdx].resolvedURL, !url.isEmpty {
                let label = sources[sourceIdx].displayLabel ?? "\(index)"
                // #cite suffix triggers small pill badge rendering in MarkdownView
                result += " [\(label)](\(url)#cite) "
            } else {
                result += content[fullRange]
            }
            searchStart = fullRange.upperBound
        }
        result += content[searchStart...]
        return result
    }

    /// Rewrites relative server URLs (like `/api/v1/files/{id}/content`) in markdown
    /// link targets to absolute URLs using the server's base URL, so they can be
    /// opened by iOS when tapped.
    private func resolveRelativeURLs(_ content: String) -> String {
        let base = viewModel.serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return content }

        // Match markdown links: [text](url)
        // Capture the URL part — replace if it starts with /api/
        let pattern = #"(\]\()(/api/[^\s\)]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        guard !matches.isEmpty else { return content }

        var result = ""
        var currentIndex = 0

        for match in matches {
            let fullRange = match.range
            // Text before this match
            if fullRange.location > currentIndex {
                result += nsContent.substring(with: NSRange(location: currentIndex, length: fullRange.location - currentIndex))
            }
            // The "](" prefix
            let prefixRange = match.range(at: 1)
            let prefix = nsContent.substring(with: prefixRange)
            // The relative path
            let pathRange = match.range(at: 2)
            let relativePath = nsContent.substring(with: pathRange)
            // Build absolute URL
            result += "\(prefix)\(base)\(relativePath)"
            currentIndex = fullRange.location + fullRange.length
        }

        // Remaining content
        if currentIndex < nsContent.length {
            result += nsContent.substring(from: currentIndex)
        }

        return result
    }


    // MARK: - Inline Edit

    private var inlineEditContent: some View {
        VStack(alignment: .trailing, spacing: Spacing.sm) {
            TextField("Edit message…", text: $editingMessageText, axis: .vertical)
                .scaledFont(size: 14)
                .foregroundStyle(theme.chatBubbleUserText)
                .tint(theme.chatBubbleUserText)
                .lineLimit(1...20)
                .focused($isEditFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    if !editingMessageText.contains("\n") { submitInlineEdit() }
                }
                // Style the placeholder to be visible on the accent-colored bubble
                .overlay(alignment: .leading) {
                    if editingMessageText.isEmpty {
                        Text("Edit message…")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.chatBubbleUserText.opacity(0.5))
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: Spacing.sm) {
                Button { cancelInlineEdit() } label: {
                    Text("Cancel")
                        .scaledFont(size: 12, weight: .medium)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.chatBubbleUserText.opacity(0.7))
                }
                .buttonStyle(.plain)

                Button { submitInlineEdit() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").scaledFont(size: 11, weight: .bold)
                        Text("Save & Resend").scaledFont(size: 12, weight: .medium).fontWeight(.semibold)
                    }
                    .foregroundStyle(theme.chatBubbleUserText)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.chatBubbleUserText.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .disabled(editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
        }
    }

    private func beginInlineEdit(message: ChatMessage) {
        withAnimation(.easeInOut(duration: 0.2)) {
            editingMessageId = message.id
            editingMessageText = message.content
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isEditFieldFocused = true }
        Haptics.play(.light)
    }

    private func cancelInlineEdit() {
        withAnimation(.easeInOut(duration: 0.2)) {
            editingMessageId = nil
            editingMessageText = ""
            isEditFieldFocused = false
        }
    }

    private func submitInlineEdit() {
        guard let id = editingMessageId else { return }
        let trimmed = editingMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            editingMessageId = nil
            isEditFieldFocused = false
        }
        Task { await viewModel.editMessage(id: id, newContent: trimmed) }
        Haptics.play(.medium)
    }

    // MARK: - Welcome View

    private struct SuggestedPrompt: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        private let _fullText: String?
        var fullText: String { _fullText ?? "\(title) \(subtitle)" }

        init(title: String, subtitle: String, fullText: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self._fullText = fullText
        }
    }

    /// Converts server-provided `default_prompt_suggestions` into display models.
    ///
    /// Returns an empty array when the server has no suggestions configured
    /// (admin turned them off or the field is absent), which collapses the
    /// entire prompt grid and shows a clean hero-only welcome screen.
    private static func buildServerPrompts(
        from suggestions: [BackendConfig.PromptSuggestion]?,
        count: Int
    ) -> [SuggestedPrompt] {
        guard let suggestions, !suggestions.isEmpty else { return [] }

        let mapped: [SuggestedPrompt] = suggestions.compactMap { suggestion in
            // title[0] = bold heading, title[1] = subtitle (may be absent)
            guard let titleParts = suggestion.title, !titleParts.isEmpty else { return nil }
            let title = titleParts[0]
            let subtitle = titleParts.count > 1 ? titleParts[1] : ""
            // Use the server's `content` field as the sent message; fall back
            // to joining the title parts if content is missing.
            let content = suggestion.content ?? titleParts.joined(separator: " ")
            return SuggestedPrompt(title: title, subtitle: subtitle, fullText: content)
        }

        // Shuffle so a different subset appears each time, then cap to `count`
        // (4 cards on iPhone, 8 on iPad).
        return Array(mapped.shuffled().prefix(count))
    }

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 60).layoutPriority(1)

                // ── Hero: avatar + greeting ──
                VStack(spacing: Spacing.sm) {
                ZStack {
                    if let model = viewModel.selectedModel {
                        ModelAvatar(
                            size: 52,
                            imageURL: viewModel.resolvedImageURL(for: model),
                            label: model.shortName,
                            authToken: viewModel.serverAuthToken
                        )
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        ModelAvatar(size: 52, label: nil)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                VStack(spacing: 4) {
                    Text("How can I help?")
                        .scaledFont(size: 24, weight: .bold)
                        .foregroundStyle(theme.textPrimary)

                    if let model = viewModel.selectedModel {
                        Text(model.shortName)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                if viewModel.isTemporaryChat {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.slash.fill")
                            .scaledFont(size: 10, weight: .semibold)
                        Text("Temporary Chat")
                            .scaledFont(size: 11, weight: .semibold)
                    }
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.warning.opacity(0.1))
                    .clipShape(Capsule())
                }
            }

            // ── Suggested prompt cards ──
            // Only shown when the server has configured suggestions.
            // If the admin clears all suggestions (or the server doesn't
            // return any), this entire block is hidden and the welcome
            // screen shows only the hero avatar + "How can I help?".
            if !randomPrompts.isEmpty {
                Spacer().frame(height: 32)

                // Adaptive grid: 2-col iPhone, 4-col iPad
                let cols = promptColumnCount
                let rows = stride(from: 0, to: randomPrompts.count, by: cols).map { i in
                    Array(randomPrompts[i..<min(i + cols, randomPrompts.count)])
                }
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            ForEach(row) { prompt in
                                promptCard(prompt)
                            }
                            // Fill empty slots if row has fewer items than column count
                            ForEach(0..<(cols - row.count), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, Spacing.screenPadding)
                    }
                }
                .frame(maxWidth: iPadMaxContentWidth)
            }

                Spacer(minLength: 60).layoutPriority(1)
            }
            .frame(minHeight: max(viewState_containerHeight, 0))
            .onTapGesture {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Folder Workspace Welcome View

    /// Shown instead of the generic "How can I help?" welcome when the user
    /// navigates into a folder workspace. Mirrors the Open WebUI web design:
    /// large folder icon + folder name centred, with a hint that new chats
    /// will be created inside this folder.
    @ViewBuilder
    private func folderWelcomeView(folder: ChatFolder) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 60).layoutPriority(1)

            VStack(spacing: Spacing.md) {
                // Folder icon
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "folder.fill")
                        .scaledFont(size: 34, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }

                // Folder name
                Text(folder.name)
                    .scaledFont(size: 26, weight: .bold)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // Subtitle hint
                Text("New chats will be saved to this folder")
                    .scaledFont(size: 13, weight: .regular)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)

                // Show system prompt badge if the folder has one
                if let systemPrompt = folder.systemPrompt,
                   !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "text.bubble")
                            .scaledFont(size: 11, weight: .medium)
                        Text("Custom system prompt active")
                            .scaledFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(theme.brandPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(Capsule())
                }

                // Show configured model badge if the folder has default models
                if let firstModel = folder.modelIds.first, !firstModel.isEmpty {
                    let modelName = viewModel.availableModels.first(where: { $0.id == firstModel })?.shortName ?? firstModel
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "cpu")
                            .scaledFont(size: 11, weight: .medium)
                        Text(modelName)
                            .scaledFont(size: 11, weight: .medium)
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(theme.surfaceContainer.opacity(0.6))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
                    )
                }
            }
            .padding(.horizontal, Spacing.screenPadding)

            Spacer(minLength: 60).layoutPriority(1)
        }
        .frame(maxWidth: iPadMaxContentWidth)
        .frame(maxWidth: .infinity)
        .onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    @ViewBuilder
    private func promptCard(_ prompt: SuggestedPrompt) -> some View {
        Button {
            viewModel.inputText = prompt.fullText
            Task { await viewModel.sendMessage() }
            Haptics.play(.light)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.subtitle)
                    .scaledFont(size: 12, weight: .regular)
                    .foregroundStyle(theme.textSecondary.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.isDark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(PromptCardButtonStyle())
    }

    // MARK: - Assistant Action Bar

    private func assistantActionBar(for message: ChatMessage) -> some View {
        let totalVersions = message.versions.count + 1
        let currentIdx = activeVersionIndex[message.id] ?? -1
        let displayIndex = currentIdx < 0 ? totalVersions : (currentIdx + 1)

        return HStack(spacing: 6) {
            // Speak
            Button {
                toggleSpeech(for: message)
                Haptics.play(.light)
            } label: {
                compactActionIcon(
                    icon: speakingMessageId == message.id ? "stop.fill" : "speaker.wave.2",
                    isActive: speakingMessageId == message.id
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(speakingMessageId == message.id ? "Stop speaking" : "Speak")

            // Copy
            Button { copyMessage(message) } label: {
                compactActionIcon(icon: "doc.on.doc", isActive: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy")

            // Version switcher (only when versions exist)
            if !message.versions.isEmpty && !viewModel.isStreaming {
                HStack(spacing: 2) {
                    Button {
                        withAnimation(MicroAnimation.snappy) {
                            if currentIdx < 0 {
                                activeVersionIndex[message.id] = message.versions.count - 1
                            } else if currentIdx > 0 {
                                activeVersionIndex[message.id] = currentIdx - 1
                            }
                        }
                        Haptics.play(.light)
                    } label: {
                        compactActionIcon(icon: "chevron.left", isActive: false, size: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIdx == 0)
                    .opacity(currentIdx == 0 ? 0.35 : 1)

                    Text("\(displayIndex)/\(totalVersions)")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 28)

                    Button {
                        withAnimation(MicroAnimation.snappy) {
                            if currentIdx >= 0 && currentIdx < message.versions.count - 1 {
                                activeVersionIndex[message.id] = currentIdx + 1
                            } else if currentIdx == message.versions.count - 1 {
                                activeVersionIndex[message.id] = -1
                            }
                        }
                        Haptics.play(.light)
                    } label: {
                        compactActionIcon(icon: "chevron.right", isActive: false, size: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIdx < 0)
                    .opacity(currentIdx < 0 ? 0.35 : 1)
                }
            }

            // Regenerate
            if !viewModel.isStreaming {
                Button {
                    activeVersionIndex[message.id] = -1
                    Task { await viewModel.regenerateResponse(messageId: message.id) }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "arrow.clockwise", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate")
            }

            // Delete
            if !viewModel.isStreaming {
                Button {
                    let vIdx = activeVersionIndex[message.id] ?? -1
                    Task { await viewModel.deleteMessage(id: message.id, activeVersionIndex: vIdx) }
                    // Reset version index after deletion so UI doesn't point at a stale slot
                    if vIdx >= 0 {
                        // If we deleted a version, adjust the index
                        if message.versions.count <= 1 {
                            // Last version was removed — reset to main content
                            activeVersionIndex.removeValue(forKey: message.id)
                        } else if vIdx >= message.versions.count - 1 {
                            // Deleted the last version in the array — step back
                            activeVersionIndex[message.id] = max(0, vIdx - 1)
                        }
                    } else {
                        // Deleted main content, promoted last version — reset to main
                        activeVersionIndex.removeValue(forKey: message.id)
                    }
                    Haptics.play(.light)
                } label: {
                    compactActionIcon(icon: "trash", isActive: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete version")
            }

            Spacer()
        }
    }

    /// Compact action icon for the always-visible action bar.
    private func compactActionIcon(icon: String, isActive: Bool, size: CGFloat = 12) -> some View {
        Image(systemName: icon)
            .scaledFont(size: size, weight: .medium)
            .foregroundStyle(isActive ? theme.brandPrimary : theme.textTertiary.opacity(0.7))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }

    // MARK: - User Action Bar

    private func userActionBar(for message: ChatMessage) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: Spacing.xs) {
                Button { copyMessage(message) } label: {
                    Image(systemName: "doc.on.doc")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                if !viewModel.isStreaming {
                    Button { beginInlineEdit(message: message) } label: {
                        Image(systemName: "pencil")
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - User Attachment Images

    @ViewBuilder
    private func userAttachmentImages(for message: ChatMessage) -> some View {
        let imageFiles = message.files.filter { $0.type == "image" }
        let nonImageFiles = message.files.filter { $0.type != "image" }

        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if !imageFiles.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Spacer()
                    ForEach(Array(imageFiles.prefix(4).enumerated()), id: \.offset) { _, file in
                        if let fileId = file.url, !fileId.isEmpty {
                            AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                                .frame(
                                    maxWidth: imageFiles.count == 1 ? 200 : 100,
                                    maxHeight: imageFiles.count == 1 ? 200 : 100
                                )
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                        }
                    }
                }
            }
            if !nonImageFiles.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Spacer()
                    ForEach(Array(nonImageFiles.enumerated()), id: \.offset) { _, file in
                        fileAttachmentCard(file: file)
                    }
                }
            }
        }
    }

    private func fileAttachmentCard(file: ChatMessageFile) -> some View {
        let fileName = file.name ?? file.url ?? "File"
        let fileExt = (fileName as NSString).pathExtension.lowercased()
        let icon = fileIconName(for: fileExt)

        return Button {
            if let fileId = file.url {
                Task { await previewFileInApp(fileId: fileId, fileName: fileName) }
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.brandPrimary)
                    .frame(width: 32, height: 32)
                    .background(theme.brandPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .scaledFont(size: 14)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileExt.uppercased())
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func fileIconName(for ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx", "csv": return "tablecells"
        case "ppt", "pptx": return "rectangle.stack"
        case "json", "yaml", "yml", "xml", "conf", "toml", "ini", "cfg": return "curlybraces"
        case "txt", "md", "rtf": return "doc.plaintext"
        case "js", "ts", "py", "swift", "dart", "java", "cpp", "c", "h", "rb", "go", "rs":
            return "chevron.left.forwardslash.chevron.right"
        case "html", "css", "scss": return "globe"
        case "zip", "tar", "gz", "rar", "7z": return "archivebox"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        case "mp4", "mov", "avi", "mkv": return "film"
        default: return "doc"
        }
    }

    // MARK: - Tool-Generated Images

    @ViewBuilder
    private func messageFilesView(files: [ChatMessageFile]) -> some View {
        let imageFiles = files.filter { $0.type == "image" || ($0.contentType ?? "").hasPrefix("image/") }
        if !imageFiles.isEmpty {
            let columns = imageFiles.count == 1
                ? [GridItem(.flexible())]
                : [GridItem(.flexible(), spacing: Spacing.sm), GridItem(.flexible(), spacing: Spacing.sm)]

            LazyVGrid(columns: columns, spacing: Spacing.sm) {
                ForEach(Array(imageFiles.enumerated()), id: \.element) { _, file in
                    if let fileUrl = file.url, !fileUrl.isEmpty {
                        let fileId: String = {
                            if !fileUrl.contains("/") { return fileUrl }
                            let parts = fileUrl.split(separator: "/")
                            if let idx = parts.firstIndex(of: "files"), idx + 1 < parts.count {
                                return String(parts[idx + 1])
                            }
                            return fileUrl
                        }()
                        AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - Sources Bar

    private func sourcesBar(sources: [ChatSourceReference], messageId: String) -> some View {
        Button {
            if let msg = viewModel.messages.first(where: { $0.id == messageId }) {
                sourcesSheetMessage = msg
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                HStack(spacing: -4) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.offset) { _, source in
                        Circle()
                            .fill(theme.brandPrimary.opacity(0.2))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Text(String((source.title ?? source.url ?? "?").prefix(1)).uppercased())
                                    .scaledFont(size: 8, weight: .bold)
                                    .foregroundStyle(theme.brandPrimary)
                            )
                    }
                }
                Text("\(sources.count) Source\(sources.count == 1 ? "" : "s")")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(theme.surfaceContainer.opacity(0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Follow-Up Suggestions

    private func followUpSuggestions(for message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "lightbulb").scaledFont(size: 12).foregroundStyle(theme.brandPrimary)
                Text("Continue with")
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textTertiary)
            }
            ForEach(message.followUps, id: \.self) { suggestion in
                Button {
                    viewModel.inputText = suggestion
                    Task { await viewModel.sendMessage() }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "arrow.right")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(theme.brandPrimary)
                        Text(suggestion)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.brandPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(theme.brandPrimary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                            .strokeBorder(theme.brandPrimary.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Message Error View

    private func messageErrorView(_ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 12)
                .foregroundStyle(theme.error)
            Text(text)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
                .lineLimit(2)
            Spacer()
            if !viewModel.isStreaming {
                Button { Task { await viewModel.regenerateLastResponse() } } label: {
                    Text("Retry").scaledFont(size: 12, weight: .medium).foregroundStyle(theme.brandPrimary)
                }
            }
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - Error Banner

    private func errorBannerView(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.error)
            Text(message)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(3)
            Spacer()
            Button {
                withAnimation(MicroAnimation.snappy) { viewModel.errorMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
        }
        .padding(Spacing.md)
        .background(theme.errorBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(MicroAnimation.gentle, value: viewModel.errorMessage != nil)
    }

    // MARK: - Copied Toast

    private var copiedToastView: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.on.doc.fill").scaledFont(size: 12)
            Text("Copied to clipboard").scaledFont(size: 12, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
        .padding(.top, Spacing.md)
        .transition(.toastTransition)
        .animation(MicroAnimation.gentle, value: showCopiedToast)
    }


    // MARK: - Actions

    private func toggleVoiceInput() {
        Haptics.play(.medium)
        let voiceCallVM = dependencies.makeVoiceCallViewModel()
        if let manager = dependencies.conversationManager {
            voiceCallVM.configure(
                conversationManager: manager,
                chatViewModel: viewModel,
                modelName: viewModel.selectedModel?.name ?? "AI Assistant"
            )
        }
        router.presentVoiceCall(viewModel: voiceCallVM)
    }

    private func toggleSpeech(for message: ChatMessage) {
        let tts = dependencies.textToSpeechService
        if speakingMessageId == message.id {
            tts.stop()
            speakingMessageId = nil
        } else {
            tts.stop()
            let rate = UserDefaults.standard.double(forKey: "ttsSpeechRate")
            if rate > 0 { tts.speechRate = Float(rate) * AVSpeechUtteranceDefaultSpeechRate }
            let voiceId = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier") ?? ""
            tts.voiceIdentifier = voiceId.isEmpty ? nil : voiceId
            tts.onComplete = { speakingMessageId = nil }

            let vIdx = activeVersionIndex[message.id] ?? -1
            let content: String = {
                if vIdx >= 0 && vIdx < message.versions.count { return message.versions[vIdx].content }
                return message.content
            }()
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            speakingMessageId = message.id
            tts.speak(content)
        }
    }

    private func copyMessage(_ message: ChatMessage) {
        var clean = message.content
        if let re = try? NSRegularExpression(pattern: #"<details[^>]*>.*?</details>"#, options: [.dotMatchesLineSeparators]) {
            clean = re.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        }
        clean = clean
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.sources.isEmpty {
            clean += "\n\nSources:"
            for (i, src) in message.sources.enumerated() {
                clean += "\n[\(i+1)] \(src.resolvedURL ?? src.title ?? "Source \(i+1)")"
            }
        }
        UIPasteboard.general.string = clean
        Haptics.notify(.success)
        withAnimation(MicroAnimation.gentle) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(MicroAnimation.gentle) { showCopiedToast = false }
        }
    }

    // MARK: - Attachment Processing

private func processSelectedPhotos(_ items: [PhotosPickerItem]) async {
for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let image = UIImage(data: data)
                    let thumbnail = image.map { Image(uiImage: $0) }
                    // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
                    let resized = FileAttachmentService.downsampleForUpload(data: data, image: image)
                    let attachment = ChatAttachment(
                        type: .image, name: "Photo_\(Int(Date.now.timeIntervalSince1970)).jpg",
                        thumbnail: thumbnail, data: resized
                    )
                    viewModel.attachments.append(attachment)
                    // Start uploading immediately so it's ready by send time
                    viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
                }
            } catch {
                viewModel.errorMessage = "Failed to load photo: \(error.localizedDescription)"
            }
        }
    }

    private func processFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.errorMessage = "Failed to read file."
            return
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        if isImage {
            // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
            let resized = FileAttachmentService.downsampleForUpload(data: data)
            let thumbnail: Image? = UIImage(data: resized).map { Image(uiImage: $0) }
            let attachment = ChatAttachment(
                type: .image, name: url.lastPathComponent,
                thumbnail: thumbnail, data: resized
            )
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        } else {
            let attachment = ChatAttachment(
                type: .file, name: url.lastPathComponent,
                thumbnail: nil, data: data
            )
            viewModel.attachments.append(attachment)
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        }
    }

    private func processCameraImage(_ image: UIImage?) {
        guard let image else { return }
        // Downsample to ≤ 2 MP to stay under the API's 5 MB base64 limit
        let data = FileAttachmentService.downsampleForUpload(image: image)
        guard !data.isEmpty else { return }
        let attachment = ChatAttachment(
            type: .image, name: "Camera_\(Int(Date.now.timeIntervalSince1970)).jpg",
            thumbnail: Image(uiImage: image), data: data
        )
        viewModel.attachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
    }

    private func processAudioFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.errorMessage = "Failed to read audio file."
            return
        }
        let attachment = ChatAttachment(type: .audio, name: url.lastPathComponent, thumbnail: nil, data: data)
        viewModel.attachments.append(attachment)

        // Route to the user-selected transcription engine.
        // "device" and "server" are live-speech engines, not file transcription — skip ML for those.
        // Route based on the audio file transcription mode setting.
        // "server" (default): upload the audio file to the server via the files API —
        //   the server handles transcription/processing automatically (?process=true).
        //   No on-device work needed; the user can navigate away freely.
        // "device": use on-device Parakeet/Qwen3 ASR (existing behavior).
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        if audioFileMode == "server" {
            // Treat audio exactly like any other file attachment — upload immediately.
            // The server processes the audio via ?process=true and handles transcription.
            viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
        } else {
            // On-device mode: delegate to ViewModel so the Task survives navigation.
            viewModel.transcribeAudioAttachment(attachmentId: attachment.id, audioData: data, fileName: url.lastPathComponent)
        }
    }

    /// Opens a file in an in-app QuickLook preview.
    /// Uses a local cache keyed by file ID so files that were just uploaded
    /// don't need to be re-downloaded from the server.
    private func previewFileInApp(fileId: String, fileName: String) async {
        // Check cache first — if we already have this file locally, show it instantly
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let cachedFile = cacheDir.appendingPathComponent("\(fileId)_\(fileName)")
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            previewFileURL = cachedFile
            return
        }

        // Not cached — download from server
        guard let apiClient = dependencies.apiClient else { return }
        withAnimation { isDownloadingFile = true }

        do {
            let (data, _) = try await apiClient.getFileContent(id: fileId)
            try data.write(to: cachedFile)
            withAnimation { isDownloadingFile = false }
            previewFileURL = cachedFile
        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "Failed to load file: \(error.localizedDescription)"
            showDownloadError = true
        }
    }

    /// Downloads a file from the server using the authenticated API client,
    /// saves it to a temp directory, and presents the iOS share sheet.
    private func downloadAndShareFile(fileId: String) async {
        guard let apiClient = dependencies.apiClient else {
            downloadErrorMessage = "Not connected to server."
            showDownloadError = true
            return
        }

        withAnimation { isDownloadingFile = true }

        do {
            let (data, contentType) = try await apiClient.getFileContent(id: fileId)

            // Try to get the file name from file info
            var fileName = "download"
            if let info = try? await apiClient.getFileInfo(id: fileId) {
                if let meta = info["meta"] as? [String: Any], let name = meta["name"] as? String {
                    fileName = name
                } else if let name = info["filename"] as? String {
                    fileName = name
                } else if let name = info["name"] as? String {
                    fileName = name
                }
            }

            // If no extension, try to infer from content type
            if (fileName as NSString).pathExtension.isEmpty {
                let ext: String
                switch contentType {
                case let ct where ct.contains("pdf"): ext = "pdf"
                case let ct where ct.contains("word") || ct.contains("docx"): ext = "docx"
                case let ct where ct.contains("spreadsheet") || ct.contains("xlsx"): ext = "xlsx"
                case let ct where ct.contains("presentation") || ct.contains("pptx"): ext = "pptx"
                case let ct where ct.contains("plain"): ext = "txt"
                case let ct where ct.contains("json"): ext = "json"
                case let ct where ct.contains("png"): ext = "png"
                case let ct where ct.contains("jpeg") || ct.contains("jpg"): ext = "jpg"
                default: ext = "bin"
                }
                fileName = "\(fileName).\(ext)"
            }

            // Save to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(fileName)
            try data.write(to: tempFile)

            withAnimation { isDownloadingFile = false }

            // Present share sheet
            downloadedFileURL = tempFile

        } catch {
            withAnimation { isDownloadingFile = false }
            downloadErrorMessage = "Failed to download: \(error.localizedDescription)"
            showDownloadError = true
        }
    }

    private func processWebURL() {
        var urlString = webURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://\(urlString)"
        }
        if viewModel.inputText.isEmpty {
            viewModel.inputText = urlString
        } else {
            viewModel.inputText += "\n\(urlString)"
        }
        webURLInput = ""
    }
}

// MARK: - Isolated Streaming Status (Observation Isolation)

/// Isolates streaming status reads into its own view body so that
/// `StreamingContentStore` property accesses (streamingStatusHistory,
/// streamingContent, isActive) are attributed to THIS struct's body —
/// not to ChatDetailView.body. Without this, every token arrival would
/// re-evaluate the entire 800+ line ChatDetailView.
private struct IsolatedStreamingStatus: View {
    let streamingStore: StreamingContentStore
    let message: ChatMessage

    var body: some View {
        let isActiveStore = streamingStore.streamingMessageId == message.id
            && streamingStore.isActive
        let effectiveStatusHistory = isActiveStore
            ? streamingStore.streamingStatusHistory
            : message.statusHistory
        let effectiveContent = isActiveStore
            ? streamingStore.streamingContent
            : message.content
        let effectiveIsStreaming = isActiveStore || message.isStreaming

        if effectiveIsStreaming && !effectiveStatusHistory.isEmpty {
            let visible = effectiveStatusHistory.filter { $0.hidden != true }
            let hasPending = visible.contains { $0.done != true }
            let hasContent = !effectiveContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasPending && !hasContent {
                StreamingStatusView(statusHistory: effectiveStatusHistory, isStreaming: true)
                    .padding(.bottom, Spacing.xs)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Isolated Assistant Message (Observation Isolation)

/// Isolates ALL streaming store reads for assistant message content into
/// its own view body. This is the single most impactful performance fix:
///
/// **Before:** `streamingStore.streamingContent` was read inside
/// `ChatDetailView.messageContent()` which is called from `body`.
/// Swift's @Observable macro attributes that read to ChatDetailView,
/// causing the ENTIRE view (800+ lines, all messages, toolbar, input)
/// to re-evaluate on every token (~15-20x/sec).
///
/// **After:** Only this small struct re-evaluates per token. All other
/// message views, the toolbar, input field, and scroll infrastructure
/// remain completely inert during streaming.
///
/// ## Fixed-Height Streaming Container (VStack Re-layout Fix)
/// During active streaming, the content is wrapped in a fixed-height
/// (400pt) container with internal scrolling. This prevents the parent
/// VStack from re-measuring ALL sibling message rows when the streaming
/// content grows in height. When streaming completes, the fixed height
/// is removed and full content renders at its natural height.
private struct IsolatedAssistantMessage: View {
    let streamingStore: StreamingContentStore
    let message: ChatMessage
    let activeVersionIndex: Int
    let serverBaseURL: String

    var body: some View {
        let isActivelyStreaming = streamingStore.streamingMessageId == message.id
            && streamingStore.isActive

        let vIdx = activeVersionIndex
        let rawContent: String = {
            if isActivelyStreaming { return streamingStore.streamingContent }
            if vIdx >= 0 && vIdx < message.versions.count { return message.versions[vIdx].content }
            return message.content
        }()

        let effectiveSources: [ChatSourceReference] = isActivelyStreaming
            ? streamingStore.streamingSources : message.sources

        // During streaming: pass raw content through (zero processing per token).
        // After streaming: apply URL resolution and citation linking.
        // Note: soft breaks are now handled natively by MarkdownView (renders
        // \n as line breaks instead of spaces), so no convertSoftBreaksToHard needed.
        let displayContent: String = {
            if isActivelyStreaming { return rawContent }
            let resolved = Self.resolveRelativeURLs(rawContent, baseURL: serverBaseURL)
            return Self.preprocessCitations(resolved, sources: effectiveSources)
        }()

        let effectiveIsStreaming = isActivelyStreaming || message.isStreaming

        if effectiveIsStreaming && rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TypingIndicator()
        } else {
            AssistantMessageContent(
                content: displayContent,
                isStreaming: effectiveIsStreaming
            )
        }
    }

    // MARK: - Static Preprocessing (no ChatDetailView dependency)

    static func preprocessCitations(_ content: String, sources: [ChatSourceReference]) -> String {
        guard !sources.isEmpty else { return content }
        let pattern = #"\[(\d+)\](?!\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        var result = ""
        var searchStart = content.startIndex
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        for match in matches {
            guard let fullRange = Range(match.range, in: content),
                  let numberRange = Range(match.range(at: 1), in: content) else { continue }
            guard let index = Int(content[numberRange]) else { continue }
            result += content[searchStart..<fullRange.lowerBound]
            let sourceIdx = index - 1
            if sourceIdx >= 0 && sourceIdx < sources.count,
               let url = sources[sourceIdx].resolvedURL, !url.isEmpty {
                let label = sources[sourceIdx].displayLabel ?? "\(index)"
                // #cite suffix triggers small pill badge rendering in MarkdownView
                result += " [\(label)](\(url)#cite) "
            } else {
                result += content[fullRange]
            }
            searchStart = fullRange.upperBound
        }
        result += content[searchStart...]
        return result
    }

    static func resolveRelativeURLs(_ content: String, baseURL: String) -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return content }
        let pattern = #"(\]\()(/api/[^\s\)]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        guard !matches.isEmpty else { return content }
        var result = ""
        var currentIndex = 0
        for match in matches {
            let fullRange = match.range
            if fullRange.location > currentIndex {
                result += nsContent.substring(with: NSRange(location: currentIndex, length: fullRange.location - currentIndex))
            }
            let prefixRange = match.range(at: 1)
            let prefix = nsContent.substring(with: prefixRange)
            let pathRange = match.range(at: 2)
            let relativePath = nsContent.substring(with: pathRange)
            result += "\(prefix)\(base)\(relativePath)"
            currentIndex = fullRange.location + fullRange.length
        }
        if currentIndex < nsContent.length {
            result += nsContent.substring(from: currentIndex)
        }
        return result
    }

}

// MARK: - Superscript Number Helper

/// Converts an integer to its Unicode superscript representation.
/// e.g., 1 → "¹", 12 → "¹²", 9 → "⁹"
private func superscriptNumber(_ n: Int) -> String {
    let superDigits: [Character] = ["\u{2070}", "\u{00B9}", "\u{00B2}", "\u{00B3}", "\u{2074}", "\u{2075}", "\u{2076}", "\u{2077}", "\u{2078}", "\u{2079}"]
    return String(String(n).compactMap { c in
        guard let digit = c.wholeNumberValue, digit < superDigits.count else { return nil }
        return superDigits[digit]
    })
}

// MARK: - Prompt Card Button Style

struct PromptCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Document Picker (UIKit Wrapper)

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .pdf, .plainText, .text, .json, .image, .png, .jpeg,
            .spreadsheet, .presentation, .audio, .mp3, .wav, .aiff, .data
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - Camera Picker (UIKit Wrapper)

struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, dismiss: dismiss) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}

// MARK: - Share Sheet (UIKit Wrapper)

/// Wraps UIActivityViewController for presenting the iOS share sheet.
struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - ScrollView Horizontal Lock

/// A zero-size `UIViewRepresentable` that finds the enclosing `UIScrollView`
/// and installs a KVO observer on `contentOffset` to continuously snap
/// `contentOffset.x` back to 0. This is the nuclear option for preventing
/// horizontal panning — no matter what triggers it (animated insertions,
/// transient layout overflow, MarkdownView intrinsic size, etc.), the
/// horizontal offset is immediately corrected on the very next frame.
///
/// Also sets `alwaysBounceHorizontal = false` and `isDirectionalLockEnabled = true`
/// as static configuration, and uses a pan gesture recognizer delegate to
/// prevent horizontal pan recognition entirely.
private struct ScrollViewHorizontalLock: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Re-attach if the scroll view was recreated
        if context.coordinator.observedScrollView == nil {
            DispatchQueue.main.async {
                context.coordinator.attach(to: uiView)
            }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var observation: NSKeyValueObservation?
        weak var observedScrollView: UIScrollView?
        private var panBlocker: UIPanGestureRecognizer?

        func attach(to view: UIView) {
            guard observedScrollView == nil else { return }
            var current: UIView? = view.superview
            while let sv = current {
                if let scrollView = sv as? UIScrollView {
                    observedScrollView = scrollView

                    // Static configuration
                    scrollView.alwaysBounceHorizontal = false
                    scrollView.showsHorizontalScrollIndicator = false
                    scrollView.isDirectionalLockEnabled = true

                    // KVO: snap contentOffset.x to 0 on every change
                    observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, change in
                        guard self != nil, let offset = change.newValue else { return }
                        if abs(offset.x) > 0.5 {
                            // Use setContentOffset to avoid triggering another KVO notification loop
                            sv.contentOffset = CGPoint(x: 0, y: offset.y)
                        }
                    }

                    // Add a pan gesture recognizer that blocks horizontal panning
                    let blocker = UIPanGestureRecognizer(target: nil, action: nil)
                    blocker.delegate = self
                    blocker.cancelsTouchesInView = false
                    scrollView.addGestureRecognizer(blocker)
                    panBlocker = blocker

                    break
                }
                current = sv.superview
            }
        }

        func detach() {
            observation?.invalidate()
            observation = nil
            if let blocker = panBlocker, let sv = observedScrollView {
                sv.removeGestureRecognizer(blocker)
            }
            panBlocker = nil
            observedScrollView = nil
        }

        // MARK: UIGestureRecognizerDelegate

        /// Allow our blocker to recognize simultaneously with all other gestures
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// Block any pan gesture that is primarily horizontal
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            // Only block if it's our custom blocker AND the pan is horizontal
            if pan === panBlocker {
                return false // never let our blocker actually begin
            }
            return true
        }
    }
}

// MARK: - URL Identifiable

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
