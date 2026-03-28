import Foundation
import os.log
import SwiftUI

extension Notification.Name {
    static let conversationTitleUpdated = Notification.Name("conversationTitleUpdated")
    static let navigateToChannel = Notification.Name("navigateToChannel")
    static let conversationListNeedsRefresh = Notification.Name("conversationListNeedsRefresh")
    /// Posted by MemoriesView when the user toggles the Enable Memory switch.
    /// `object` is the new Bool value so ChatViewModel updates immediately.
    static let memorySettingChanged = Notification.Name("memorySettingChanged")
    /// Posted by AdminConsoleView when a user's chat is cloned.
    static let adminClonedChat = Notification.Name("adminClonedChat")
    /// Posted by the audio attachment thumbnail's retry button.
    /// `object` is the `UUID` of the attachment to retry uploading.
    static let retryAttachmentUpload = Notification.Name("retryAttachmentUpload")
}

/// Manages state and logic for a single chat conversation.
/// Handles sending/streaming messages via Socket.IO, loading history, and model selection.
/// Instances are held by `ActiveChatStore` so they survive navigation transitions.
@MainActor @Observable
final class ChatViewModel {
    // MARK: - Published State

    /// Isolated store for streaming content. Only the actively streaming
    /// message view observes this — all other message views read from
    /// `conversation.messages` which stays frozen during streaming.
    /// This breaks the observation chain that was causing ALL messages
    /// to re-evaluate on every token.
    let streamingStore = StreamingContentStore()

    var conversation: Conversation?
    var availableModels: [AIModel] = []

    // MARK: - Folder Context

    /// When set, new chats will be created inside this folder and use this system prompt.
    var folderContextId: String?
    var folderContextSystemPrompt: String?
    var folderContextModelIds: [String] = []

    /// Sets or clears the folder workspace context.
    /// Called when the user taps a folder name in the drawer.
    func setFolderContext(folderId: String?, systemPrompt: String?, modelIds: [String] = []) {
        folderContextId = folderId
        folderContextSystemPrompt = systemPrompt
        folderContextModelIds = modelIds
        // If the folder has default model IDs and we have no model selected, pick the first
        if let firstModel = modelIds.first, !firstModel.isEmpty {
            let available = availableModels.map(\.id)
            if available.contains(firstModel) {
                selectModel(firstModel)
            }
        }
    }
    var selectedModelId: String?
    var isStreaming: Bool = false
    var isLoadingConversation: Bool = false
    var isLoadingModels: Bool = false
    var errorMessage: String?
    var inputText: String = ""
    var attachments: [ChatAttachment] = []
    var webSearchEnabled: Bool = false
    var imageGenerationEnabled: Bool = false
    var codeInterpreterEnabled: Bool = false
    /// Whether memory is enabled for this chat session.
    /// Persisted to server user settings (`ui.memory`) so the web UI stays in sync.
    var memoryEnabled: Bool = false
    /// Pinned model IDs synced with server `ui.pinnedModels`.
    var pinnedModelIds: [String] = []
    var isTemporaryChat: Bool = false
    var availableTools: [ToolItem] = []
    var selectedToolIds: Set<String> = [] {
        didSet {
            // Track tools the user explicitly disabled (were in old set but not new)
            let removed = oldValue.subtracting(selectedToolIds)
            let added = selectedToolIds.subtracting(oldValue)
            userDisabledToolIds.formUnion(removed)
            userDisabledToolIds.subtract(added)
        }
    }
    /// Tools the user has explicitly toggled OFF during this chat session.
    /// Prevents `syncToolSelectionWithDefaults()` from re-enabling them.
    private var userDisabledToolIds: Set<String> = []
    var selectedKnowledgeItems: [KnowledgeItem] = []
    var knowledgeItems: [KnowledgeItem] = []
    var isLoadingTools: Bool = false
    /// Available terminal servers fetched from the backend.
    var availableTerminalServers: [TerminalServer] = []
    /// Whether the user has enabled terminal for this chat session.
    var terminalEnabled: Bool = false
    /// The currently selected terminal server (auto-selects first if only one).
    var selectedTerminalServer: TerminalServer?
    var isLoadingKnowledge: Bool = false
    var isShowingKnowledgePicker: Bool = false
    var knowledgeSearchQuery: String = ""

    // Prompt slash command state
    /// Cached prompts from the server. Fetched lazily on first `/` trigger.
    var availablePrompts: [PromptItem] = []
    /// Whether the prompt picker overlay is visible.
    var isShowingPromptPicker: Bool = false
    /// The current filter query (text typed after `/`).
    var promptSearchQuery: String = ""
    /// Whether prompts are currently being loaded from the server.
    var isLoadingPrompts: Bool = false
    // Skill $ trigger state
    /// Cached skills from the server. Fetched lazily on first `$` trigger.
    var availableSkills: [SkillItem] = []
    /// Whether the skill picker overlay is visible.
    var isShowingSkillPicker: Bool = false
    /// The current filter query (text typed after `$`).
    var skillSearchQuery: String = ""
    /// Whether skills are currently being loaded from the server.
    var isLoadingSkills: Bool = false
    /// Skills selected via the `$` picker for the current message.
    /// Sent as `skill_ids` in the API request and cleared after each send.
    var selectedSkillIds: [String] = []

    /// The prompt selected by the user that has variables requiring input.
    /// When set, the variable input sheet is presented.
    var pendingPromptForVariables: PromptItem?
    /// The parsed variables for the pending prompt.
    var pendingPromptVariables: [PromptVariable] = []
    /// The model ID selected via `@` mention in the chat input.
    /// Persists across messages until the user explicitly clears it.
    var mentionedModelId: String?
    /// Suggested emoji for the last assistant message (generated by server).
    var suggestedEmoji: String?
    private(set) var hasLoaded: Bool = false

    /// Whether an external client (website, another app tab) is currently
    /// streaming a response to this chat. When `true`, the app is passively
    /// observing socket events it did not initiate.
    private(set) var isExternallyStreaming: Bool = false

    /// Set to `true` after the initial load completes so that new messages
    /// arriving during a session get an appear animation, while the full
    /// history loaded on first launch does not.
    private(set) var shouldAnimateNewMessages: Bool = false

    // MARK: - Private State

    let conversationId: String?
    private var manager: ConversationManager?
    private var socketService: SocketIOService?
    /// Weak reference to the shared ASR service, set via configure().
    private weak var asrService: OnDeviceASRService?
    private var streamingTask: Task<Void, Never>?
    /// Active transcription tasks keyed by attachment ID.
    /// Stored here so they survive navigation — the VM lives in ActiveChatStore
    /// and is never destroyed when the user switches chats.
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    /// The post-streaming completion task (chatCompleted + file polling + metadata refresh).
    /// Cancelled when a new message is sent so it doesn't overwrite newer messages.
    private var completionTask: Task<Void, Never>?
    private var chatSubscription: SocketSubscription?
    private var channelSubscription: SocketSubscription?
    /// Persistent passive socket listener that observes events for this chat
    /// regardless of who initiated the generation. Mirrors the website's
    /// `Chat.svelte` `socket.on("events", chatEventHandler)` pattern.
    private var passiveSubscription: SocketSubscription?
    /// True when this VM initiated the current streaming session (sendMessage/regenerate).
    /// The passive listener skips processing when this is true to avoid conflicts.
    private var selfInitiatedStream: Bool = false
    /// Guards against flooding syncForExternalStream with duplicate fetch tasks
    /// when many socket tokens arrive before the first fetch completes.
    private var isSyncingExternalStream: Bool = false
    private var sessionId: String = UUID().uuidString
    private let logger = Logger(subsystem: "com.openui", category: "ChatViewModel")
    private var hasFinishedStreaming = false
    private var activeTaskId: String?
    private var recoveryTimer: Timer?
    /// Cancellable delay task for the initial recovery timer delay.
    /// Replaces `DispatchQueue.main.asyncAfter` so it can be cancelled
    /// when the user navigates away or sends a new message.
    private var recoveryDelayTask: Task<Void, Never>?
    private var emptyPollCount = 0
    /// Tracks whether the socket has received at least one content token.
    /// Used by the recovery timer to avoid overwriting an active stream.
    private var socketHasReceivedContent = false
    private(set) var serverBaseURL: String = ""
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    /// Separate background task assertion for on-device ASR transcription.
    /// Independent from backgroundTaskId (which covers streaming completion).
    @ObservationIgnored nonisolated(unsafe) private var transcriptionBackgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Pending transcriptions that were interrupted when the app moved to the background
    /// (iOS < 26 only — no GPU access in background). Keyed by attachment ID.
    /// Re-started automatically when the app returns to foreground.
    private var pendingResumeTranscriptions: [UUID: (audioData: Data, fileName: String)] = [:]

    /// Timestamp of the last successful server sync. Used to debounce
    /// redundant syncs when the app rapidly transitions foreground ↔ background.
    private var lastSyncTime: Date = .distantPast

    /// Minimum interval (seconds) between server syncs to avoid redundant fetches.
    private let syncDebounceInterval: TimeInterval = 3.0

    /// Timestamp when the app entered the background. Used to skip
    /// sync when the background duration was trivially short.
    @ObservationIgnored nonisolated(unsafe) private var backgroundEnteredAt: Date?

    /// The current auth token for authenticated image requests (model avatars).
    var serverAuthToken: String? {
        manager?.apiClient.network.authToken
    }

    var messages: [ChatMessage] {
        conversation?.messages ?? []
    }

    var selectedModel: AIModel? {
        guard let id = selectedModelId else { return nil }
        return availableModels.first { $0.id == id }
    }

    var canSend: Bool {
        !isStreaming
            && !attachments.contains(where: { $0.type == .audio && $0.isTranscribing })
            && !attachments.contains(where: { $0.isUploading })
            && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    /// True if any transcription Task is currently running.
    /// Used by ActiveChatStore to prevent evicting a VM that is still working.
    var hasActiveTranscriptions: Bool {
        !transcriptionTasks.isEmpty
    }

    /// Whether any attachment is still uploading or being processed.
    var hasUploadingAttachments: Bool {
        attachments.contains { $0.isUploading }
    }

    var isNewConversation: Bool {
        conversationId == nil && conversation == nil
    }

    // MARK: - Immediate File Upload

    /// Uploads an attachment to the server immediately after it's added.
    /// Call this right after appending an attachment to `self.attachments`.
    /// The attachment's `uploadStatus` will progress: uploading → completed/error.
    /// The send button is blocked while any attachment has `isUploading == true`.
    func uploadAttachmentImmediately(attachmentId: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == attachmentId }) else { return }
        // Skip audio only when in on-device transcription mode — server mode uploads audio like any file
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        guard !(attachments[index].type == .audio && audioFileMode == "device") else { return }

        attachments[index].uploadStatus = .uploading

        Task {
            guard let manager else {
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = "Not connected to server"
                }
                return
            }

            guard let idx = attachments.firstIndex(where: { $0.id == attachmentId }),
                  let data = attachments[idx].data else { return }

            let fileName = attachments[idx].name

            do {
                // APIClient.uploadFile handles ?process=true + SSE polling.
                // onUploaded fires after the file is stored on the server but BEFORE
                // SSE processing completes — we switch the chip from "uploading" to
                // "processing" so the user sees the two-phase status.
                let fileId = try await manager.uploadFile(
                    data: data,
                    fileName: fileName,
                    onUploaded: { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                                self.attachments[idx].uploadStatus = .processing
                            }
                        }
                    }
                )
                // Update on success
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .completed
                    attachments[idx].uploadedFileId = fileId
                    // STORAGE FIX: Release raw file data after successful upload.
                    // The file ID is sufficient for referencing the file going forward.
                    // Holding multi-MB image data in memory indefinitely causes bloat.
                    attachments[idx].data = nil
                }

                logger.info("Attachment \(fileName) uploaded + processed: \(fileId)")
            } catch {
                // Extract the clean server error message when available.
                // APIClient.waitForFileProcessing throws APIError.httpError with
                // the stripped server error text (e.g. "Error transcribing chunk…"
                // cleaned to just the relevant message).
                let errorMessage: String
                if let apiError = error as? APIError,
                   case .httpError(_, let msg, _) = apiError,
                   let msg, !msg.isEmpty {
                    errorMessage = msg
                } else {
                    errorMessage = error.localizedDescription
                }
                if let idx = attachments.firstIndex(where: { $0.id == attachmentId }) {
                    attachments[idx].uploadStatus = .error
                    attachments[idx].uploadError = errorMessage
                }
                logger.error("Attachment upload failed for \(fileName): \(errorMessage)")
            }
        }
    }

    // MARK: - Initialisation

    init(conversationId: String) {
        self.conversationId = conversationId
    }

    init() {
        self.conversationId = nil
    }

    // MARK: - Setup

    /// Weak reference to the shared store — used to write back model cache.
    private weak var activeChatStore: ActiveChatStore?

    func configure(with manager: ConversationManager, socket: SocketIOService? = nil, store: ActiveChatStore? = nil, asr: OnDeviceASRService? = nil) {
        self.manager = manager
        self.socketService = socket
        self.serverBaseURL = manager.baseURL
        self.activeChatStore = store
        self.asrService = asr
        setupRetryAttachmentObserver()
        setupMemorySettingObserver()
    }

    /// Registers the observer that handles retry requests posted by the
    /// audio attachment thumbnail's retry button.
    ///
    /// When the user taps the retry button on a failed audio upload chip,
    /// `ChatInputField` posts `.retryAttachmentUpload` with the attachment
    /// UUID as the `object`. This observer picks it up and re-runs
    /// `uploadAttachmentImmediately` so the status cycles back through
    /// uploading → processing → completed/error without requiring a new configure().
    private func setupRetryAttachmentObserver() {
        NotificationCenter.default.addObserver(
            forName: .retryAttachmentUpload,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let attachmentId = notification.object as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Reset to pending so the thumbnail immediately shows a spinner
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].uploadStatus = .pending
                    self.attachments[idx].uploadError = nil
                }
                self.uploadAttachmentImmediately(attachmentId: attachmentId)
            }
        }
    }

    /// Registers an observer for `.memorySettingChanged` so that when the user
    /// toggles memory in Settings → Personalization → Memories, all active
    /// ChatViewModels update `memoryEnabled` immediately without a server refetch.
    private func setupMemorySettingObserver() {
        NotificationCenter.default.addObserver(
            forName: .memorySettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let newValue = notification.object as? Bool else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryEnabled = newValue
            }
        }
    }

    // MARK: - Audio Transcription (Navigation-Persistent)

    /// Starts transcription for an audio attachment and stores the Task on the VM.
    ///
    /// Because the VM lives in `ActiveChatStore` and survives navigation, the Task
    /// stored here will NOT be cancelled when the user navigates to another chat,
    /// the welcome screen, or anywhere else in the app. When the user returns to
    /// this chat, the attachment's `isTranscribing` state reflects the live status
    /// and `transcribedText` is populated as soon as the model finishes.
    ///
    /// - Parameters:
    ///   - attachmentId: The UUID of the `ChatAttachment` to transcribe.
    ///   - audioData: Raw audio file bytes.
    ///   - fileName: Original filename (used for the temp file extension).
    func transcribeAudioAttachment(attachmentId: UUID, audioData: Data, fileName: String) {
        guard let asr = asrService, asr.isAvailable, asr.autoTranscribeEnabled else { return }

        // Cancel any existing task for this attachment (e.g., user re-added the same file)
        transcriptionTasks[attachmentId]?.cancel()

        // Begin a background task the first time transcription starts (if not already running).
        // This requests ~30 seconds of extra CPU time from iOS when the app moves to the
        // background. If transcription finishes before the time expires, we end it early.
        // If it takes longer (e.g. large file), iOS will suspend (NOT terminate) the process
        // after the grant expires, and the Task resumes naturally when the user returns.
        if transcriptionBackgroundTaskId == .invalid {
            transcriptionBackgroundTaskId = UIApplication.shared.beginBackgroundTask(
                withName: "OnDeviceASRTranscription"
            ) { [weak self] in
                // Expiry handler — iOS is about to suspend us; end the assertion gracefully.
                // The Task itself is NOT cancelled — it will resume when the app foregrounds.
                guard let self else { return }
                Task { @MainActor in self.endTranscriptionBackgroundTask() }
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            // Mark as transcribing
            if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                self.attachments[idx].isTranscribing = true
            }

            do {
                let transcript = try await asr.transcribe(audioData: audioData, fileName: fileName)

                // Only update if attachment still exists (user may have removed it)
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].transcribedText = transcript
                    self.attachments[idx].isTranscribing = false
                }
                // Clear any pending resume record — transcription succeeded
                self.pendingResumeTranscriptions.removeValue(forKey: attachmentId)
                self.logger.info("Transcription complete for \(fileName): \(transcript.count) chars")
            } catch ASRError.backgroundInterrupted {
                // iOS < 26: The app moved to the background and Metal GPU access
                // was revoked. The task was cancelled gracefully (no crash).
                // Keep the attachment in "transcribing" state and store the audio
                // data so we can restart automatically when the app foregrounds.
                self.logger.info("Transcription paused for background: \(fileName) — will auto-resume on foreground")
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    // Keep isTranscribing = true so the chip still shows a spinner
                    // (transcription resumes; user doesn't need to do anything).
                    self.attachments[idx].isTranscribing = true
                }
                // Store audio data + filename so foreground sync can restart it
                self.pendingResumeTranscriptions[attachmentId] = (audioData: audioData, fileName: fileName)
                // Remove from active tasks — the task has ended; a new one will be started on resume
                self.transcriptionTasks.removeValue(forKey: attachmentId)
                self.endTranscriptionBackgroundTask()
                return
            } catch {
                if let idx = self.attachments.firstIndex(where: { $0.id == attachmentId }) {
                    self.attachments[idx].isTranscribing = false
                }
                // Only surface the error if the task wasn't explicitly cancelled
                if !Task.isCancelled {
                    self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                    self.logger.error("Transcription failed for \(fileName): \(error.localizedDescription)")
                }
            }

            // Clean up the task reference once complete
            self.transcriptionTasks.removeValue(forKey: attachmentId)

            // If all transcriptions are done, unload the model to free ~400-600 MB of RAM.
            // The model will reload automatically on the next transcription request.
            // Also end the iOS background task assertion (no more CPU work needed).
            if self.transcriptionTasks.isEmpty {
                asr.unloadModel()
                self.logger.info("All transcriptions complete — ASR model unloaded to free memory")
                self.endTranscriptionBackgroundTask()
            }
        }

        transcriptionTasks[attachmentId] = task
    }

    /// Ends the iOS background task assertion for on-device transcription.
    private func endTranscriptionBackgroundTask() {
        guard transcriptionBackgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transcriptionBackgroundTaskId)
        transcriptionBackgroundTaskId = .invalid
    }

    func resolvedImageURL(for model: AIModel?) -> URL? {
        guard let model else { return nil }
        return model.resolveAvatarURL(baseURL: serverBaseURL)
    }

    // MARK: - Loading

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        let isNew = conversationId == nil

        // Models & tools are NOT fetched here — they load lazily:
        //  • Models: pre-populated from ActiveChatStore cache. Refreshed
        //    when user opens model picker or before each send.
        //  • Tools: fetched fresh every time user opens the tools section.
        //
        // If this is the very first VM and the cache is empty, do an initial
        // model fetch so the user has something to select.
        let needsModelFetch = availableModels.isEmpty

        if isNew {
            // ── New chat fast path ──
            // Skip conversation fetch, passive listener, and external stream
            // check — they are all no-ops when there is no conversation ID.
            if needsModelFetch {
                await loadModels()
            } else {
                syncUIWithModelDefaults()
            }
        } else {
            // ── Existing chat path ──
            // Run model fetch (if needed) and conversation fetch in parallel.
            if needsModelFetch {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.loadModels() }
                    group.addTask { await self.loadConversation() }
                }
            } else {
                syncUIWithModelDefaults()
                await loadConversation()
            }
        }

        // Ensure socket is connected — fire-and-forget so it never blocks
        // the UI. The socket will be ready by the time the user sends a
        // message; if not, sendMessage() can await it at that point.
        if let socket = socketService, !socket.isConnected {
            Task {
                let connected = await socket.ensureConnected(timeout: 5.0)
                self.logger.info("Socket connect on load: \(connected)")
                // Start passive listener once socket is actually connected
                // (only meaningful for existing conversations).
                if connected && !isNew {
                    self.startPassiveSocketListener()
                }
            }
        } else if !isNew {
            // Socket already connected — start passive listener immediately
            startPassiveSocketListener()
        }

        // Start listening for app foreground events to sync with server
        startForegroundSyncListener()

        // Check if an external client is currently streaming to this chat
        // (only meaningful for existing conversations)
        if !isNew {
            await checkForActiveExternalStream()
        }

        // Fetch terminal servers in the background (fire-and-forget).
        // This is lightweight and determines whether to show the terminal pill.
        Task { await loadTerminalServers() }

        // Now that all initial data is loaded, enable message appear animations.
        // New messages sent/received during this session will animate in smoothly.
        shouldAnimateNewMessages = true
    }

    func loadConversation() async {
        guard let conversationId, let manager else { return }
        isLoadingConversation = true
        errorMessage = nil
        do {
            let fetched = try await manager.fetchConversation(id: conversationId)
            // Always use server data as the source of truth.
            // Versions are now stored as sibling messages on the server,
            // so server-fetched data already contains them.
            conversation = fetched
            // Always adopt the last-used model for existing chats.
            // Priority: last assistant message's model (the actual model used
            // most recently) > conversation-level model > fallback.
            // This ensures returning to a chat uses the model from the most
            // recent response, even if it was changed mid-conversation from
            // the web UI or another client.
            if let lastAssistantModel = fetched.messages.last(where: { $0.role == .assistant })?.model,
               !lastAssistantModel.isEmpty {
                selectedModelId = lastAssistantModel
            } else if let conversationModel = fetched.model, !conversationModel.isEmpty {
                selectedModelId = conversationModel
            } else if selectedModelId == nil {
                selectedModelId = availableModels.first?.id
            }
        } catch {
            logger.error("Failed to load conversation: \(error.localizedDescription)")
            errorMessage = "Failed to load conversation: \(error.localizedDescription)"
        }
        isLoadingConversation = false
    }

    /// Syncs local conversation state with the server.
    ///
    /// This is the key mechanism for detecting external changes (e.g., when
    /// a response is regenerated from the website). Matches the Flutter app's
    /// `_syncRemoteTaskStatus` and `activeConversationProvider` listener pattern.
    ///
    /// It compares local messages with server messages and adopts server data
    /// when:
    /// - Server has more messages than local
    /// - Server's last assistant message has different/more content
    /// - Server's last assistant message has different files (regenerated images)
    ///
    /// Uses debouncing to avoid redundant syncs when the app rapidly transitions
    /// between foreground and background states.
    func syncWithServer() async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }

        // Debounce: skip if we synced very recently (e.g., foreground observer
        // + .task both firing within the same second)
        let now = Date()
        guard now.timeIntervalSince(lastSyncTime) >= syncDebounceInterval else {
            logger.debug("Server sync debounced (last sync \(self.lastSyncTime.formatted()))")
            return
        }

        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            lastSyncTime = Date()

            let serverMessages = serverConversation.messages
            let localMessages = conversation?.messages ?? []

            // Skip if no server messages
            guard !serverMessages.isEmpty else { return }

            // Fast path: if message IDs, counts, and content fingerprints match,
            // nothing changed — only update lightweight metadata (title/tags).
            if localMessages.count == serverMessages.count && !localMessages.isEmpty {
                let allMatch = zip(localMessages, serverMessages).allSatisfy { local, server in
                    local.id == server.id
                    && local.content.utf8.count == server.content.utf8.count // Fast O(1) reject
                    && local.content == server.content // Full compare only if lengths match
                    && local.files.count == server.files.count
                    && local.sources.count == server.sources.count
                    && local.followUps.count == server.followUps.count
                }
                if allMatch {
                    // Only update title if changed — no structural changes to messages
                    if !serverConversation.title.isEmpty
                        && serverConversation.title != "New Chat"
                        && serverConversation.title != conversation?.title {
                        conversation?.title = serverConversation.title
                    }
                    logger.debug("Server sync: no changes detected, skipping")
                    return
                }
            }

            // Case 1: Server has more messages than local — adopt surgically
            if serverMessages.count > localMessages.count {
                logger.info("Server sync: server has \(serverMessages.count) msgs vs local \(localMessages.count)")
                adoptServerMessages(serverConversation: serverConversation)
                return
            }

            // Case 2: Same message count — check if last assistant changed
            if !localMessages.isEmpty && !serverMessages.isEmpty {
                let localLast = localMessages.last!
                let serverLast = serverMessages.last!

                // Find matching message by ID
                if localLast.id == serverLast.id && localLast.role == .assistant {
                    let localContent = localLast.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let serverContent = serverLast.content.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Server has different content (regenerated from website)
                    let contentChanged = !serverContent.isEmpty && serverContent != localContent

                    // Server has different files (e.g., regenerated images from tool)
                    let filesChanged = serverLast.files != localLast.files

                    // Server has different sources
                    let sourcesChanged = serverLast.sources.count != localLast.sources.count

                    if contentChanged || filesChanged || sourcesChanged {
                        logger.info("Server sync: detected external change (content:\(contentChanged) files:\(filesChanged) sources:\(sourcesChanged))")

                        // Save current local state as a version before adopting server state
                        // (only if the content actually differs and has meaningful content)
                        if contentChanged && !localContent.isEmpty {
                            if let idx = conversation?.messages.lastIndex(where: { $0.id == localLast.id }) {
                                let version = ChatMessageVersion(
                                    content: localLast.content,
                                    timestamp: localLast.timestamp,
                                    model: localLast.model,
                                    error: localLast.error,
                                    files: localLast.files,
                                    sources: localLast.sources,
                                    followUps: localLast.followUps
                                )
                                // Only add if we don't already have this version
                                let isDuplicate = conversation?.messages[idx].versions.contains(where: {
                                    $0.content == version.content && $0.timestamp == version.timestamp
                                }) ?? false
                                if !isDuplicate {
                                    conversation?.messages[idx].versions.append(version)
                                }
                            }
                        }

                        adoptServerMessages(serverConversation: serverConversation)
                        return
                    }
                }

                // Case 3: Last messages have different IDs — server has a different
                // message chain (e.g., regeneration created a new message ID)
                if localLast.id != serverLast.id && serverLast.role == .assistant {
                    logger.info("Server sync: different last message IDs (local:\(localLast.id) server:\(serverLast.id))")
                    adoptServerMessages(serverConversation: serverConversation)
                    return
                }
            }

            // Update title if changed
            if !serverConversation.title.isEmpty && serverConversation.title != "New Chat" {
                conversation?.title = serverConversation.title
            }

        } catch {
            logger.warning("Server sync failed: \(error.localizedDescription)")
        }
    }

    /// Adopts server messages using **surgical in-place updates** to preserve
    /// SwiftUI identity tracking and scroll position in the inverted ScrollView.
    ///
    /// Instead of replacing the entire `conversation` object (which causes
    /// SwiftUI to rebuild the full LazyVStack and lose scroll position), this
    /// method:
    /// 1. Updates existing messages in-place by matching on ID
    /// 2. Appends only truly new messages
    /// 3. Removes only messages deleted server-side
    /// 4. Merges local-only versions that haven't been synced
    ///
    /// This eliminates the flicker/jump and scroll-stuck issues that occurred
    /// when returning from background, because SwiftUI's identity tracking
    /// (via `.id(message.id)`) remains stable throughout the update.
    private func adoptServerMessages(serverConversation: Conversation) {
        guard conversation != nil else {
            // No local conversation yet — just assign directly
            conversation = serverConversation
            if let serverModel = serverConversation.model, selectedModelId != serverModel {
                selectedModelId = serverModel
            }
            return
        }

        let serverMessages = serverConversation.messages

        // Build a set of server message IDs for removal detection
        let serverMessageIds = Set(serverMessages.map(\.id))

        // Phase 1: Remove local messages that no longer exist on server
        // Iterate in reverse to preserve indices during removal
        for i in (0..<(conversation!.messages.count)).reversed() {
            let localId = conversation!.messages[i].id
            if !serverMessageIds.contains(localId) {
                conversation!.messages.remove(at: i)
            }
        }

        // Phase 2: Update existing messages in-place and insert new ones
        for (serverIdx, serverMsg) in serverMessages.enumerated() {
            if let localIdx = conversation!.messages.firstIndex(where: { $0.id == serverMsg.id }) {
                // Message exists locally — update only changed fields in-place
                let local = conversation!.messages[localIdx]

                // GUARD: During active streaming, do NOT overwrite content of
                // already-completed (non-streaming) assistant messages. The server
                // may return stale/corrupted data during streaming that would
                // replace the first message's content with the second message's
                // streaming content — causing the "duplicate stream" bug.
                let isLocallyComplete = !local.isStreaming && local.role == .assistant
                    && !local.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let skipContentUpdate = isLocallyComplete && isStreaming

                if !skipContentUpdate && local.content != serverMsg.content {
                    conversation!.messages[localIdx].content = serverMsg.content
                }
                if local.files != serverMsg.files {
                    conversation!.messages[localIdx].files = serverMsg.files
                }
                if local.sources.count != serverMsg.sources.count || local.sources != serverMsg.sources {
                    conversation!.messages[localIdx].sources = serverMsg.sources
                }
                if local.followUps != serverMsg.followUps {
                    conversation!.messages[localIdx].followUps = serverMsg.followUps
                }
                if local.error != serverMsg.error {
                    conversation!.messages[localIdx].error = serverMsg.error
                }
                if local.isStreaming != serverMsg.isStreaming {
                    conversation!.messages[localIdx].isStreaming = serverMsg.isStreaming
                }

                // Merge versions: keep local-only versions + server versions
                var mergedVersions = serverMsg.versions
                let serverVersionIds = Set(mergedVersions.map(\.id))
                for localVersion in local.versions {
                    if !serverVersionIds.contains(localVersion.id) {
                        mergedVersions.append(localVersion)
                    }
                }
                if mergedVersions.count != local.versions.count || mergedVersions != local.versions {
                    conversation!.messages[localIdx].versions = mergedVersions
                }

                // Preserve usage data from server — never overwrite with nil
                if local.usage == nil,
                   let serverUsage = serverMsg.usage, !serverUsage.isEmpty {
                    conversation!.messages[localIdx].usage = serverUsage
                }
                // Preserve embeds from server — never overwrite non-empty embeds with empty
                if local.embeds.isEmpty && !serverMsg.embeds.isEmpty {
                    conversation!.messages[localIdx].embeds = serverMsg.embeds
                }
            } else {
                // New message from server — insert at correct position
                let insertIdx = min(serverIdx, conversation!.messages.count)
                conversation!.messages.insert(serverMsg, at: insertIdx)
            }
        }

        // Phase 3: Ensure message order matches server order
        // (only reorder if the IDs don't match sequence — avoids unnecessary mutation)
        let currentIds = conversation!.messages.map(\.id)
        let serverIds = serverMessages.map(\.id)
        if currentIds != serverIds {
            // Reorder by building a new array in server order, preserving local mutations
            let localMap = Dictionary(conversation!.messages.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
            var reordered: [ChatMessage] = []
            for serverId in serverIds {
                if let msg = localMap[serverId] {
                    reordered.append(msg)
                }
            }
            // Append any remaining local messages not in server (shouldn't happen, but safety)
            for msg in conversation!.messages where !serverMessageIds.contains(msg.id) {
                reordered.append(msg)
            }
            conversation!.messages = reordered
        }

        // Phase 4: Update conversation metadata (non-message fields)
        if !serverConversation.title.isEmpty && serverConversation.title != "New Chat" {
            conversation?.title = serverConversation.title
        }
        // NOTE: Do NOT override selectedModelId here. The user's model picker
        // selection is authoritative once the conversation is loaded. Overwriting
        // it from the server would revert a deliberate model change the user made
        // (e.g., picking a different model before regenerating). The initial load
        // case at the top of this method already sets selectedModelId when
        // conversation is nil.
        if serverConversation.tags != conversation?.tags {
            conversation?.tags = serverConversation.tags
        }
    }

    // MARK: - Foreground Sync

    /// Listens for app becoming active to trigger a server sync,
    /// and for app entering background to start completion monitoring.
    /// This catches changes made externally (e.g., regeneration from website)
    /// and ensures tool-generated files/images are picked up after backgrounding.
    private func startForegroundSyncListener() {
        // Remove any existing observers to prevent duplicates
        if let existing = foregroundObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        if let existing = backgroundObserver {
            NotificationCenter.default.removeObserver(existing)
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Skip sync if the app was only backgrounded for a trivially
                // short period (< 2s). This prevents unnecessary flicker when
                // the user accidentally swipes to the app switcher and back.
                let bgDuration: TimeInterval
                if let bgStart = self.backgroundEnteredAt {
                    bgDuration = Date().timeIntervalSince(bgStart)
                } else {
                    bgDuration = .infinity // Unknown — assume long
                }
                self.backgroundEnteredAt = nil

                if self.isStreaming {
                    // App was backgrounded during streaming — socket events may
                    // have been missed. Check server for actual completion state.
                    await self.recoverFromBackgroundStreaming()
                } else if bgDuration >= 10.0 {
                    // Only sync if we were backgrounded long enough for
                    // something to have changed on the server (10s threshold
                    // avoids triggering on quick app-switcher glances which
                    // would cause scroll position loss and a flicker).
                    await self.syncWithServer()
                } else {
                    self.logger.debug("Foreground sync skipped — background duration \(bgDuration)s < 10s")
                }

                // Auto-resume any transcriptions that were paused when the app
                // went to background on iOS < 26 (where GPU access is forbidden
                // in the background). The audio data was saved in
                // pendingResumeTranscriptions at pause time; restart them now.
                if !self.pendingResumeTranscriptions.isEmpty {
                    let pending = self.pendingResumeTranscriptions
                    self.pendingResumeTranscriptions = [:]
                    self.logger.info("Resuming \(pending.count) paused transcription(s) after foreground return")
                    for (attachmentId, info) in pending {
                        self.transcribeAudioAttachment(
                            attachmentId: attachmentId,
                            audioData: info.audioData,
                            fileName: info.fileName
                        )
                    }
                }
            }
        }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.backgroundEnteredAt = Date()
                guard self.isStreaming else { return }
                self.startBackgroundCompletionPolling()
            }
        }
    }

    /// Removes the foreground/background sync listeners.
    func removeForegroundSyncListener() {
        if let existing = foregroundObserver {
            NotificationCenter.default.removeObserver(existing)
            foregroundObserver = nil
        }
        if let existing = backgroundObserver {
            NotificationCenter.default.removeObserver(existing)
            backgroundObserver = nil
        }
    }

    deinit {
        let fgObserver = foregroundObserver
        let bgObserver = backgroundObserver
        if let fgObserver {
            NotificationCenter.default.removeObserver(fgObserver)
        }
        if let bgObserver {
            NotificationCenter.default.removeObserver(bgObserver)
        }
    }

    // MARK: - Background Completion Polling

    /// Starts a background task that polls the server for streaming completion.
    /// iOS grants ~30s of background execution. If the generation completes within
    /// that window, we fire a local notification and adopt the server state.
    private func startBackgroundCompletionPolling() {
        guard backgroundTaskId == .invalid else { return }

        backgroundTaskId = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.endBackgroundTask() }
        }

        let chatId = conversationId ?? conversation?.id
        Task { @MainActor [weak self] in
            guard let self, let chatId, let manager = self.manager else {
                self?.endBackgroundTask()
                return
            }

            // Poll server every 3s, up to 10 times (~30s — near iOS limit)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.isStreaming else {
                    self.endBackgroundTask()
                    return
                }

                do {
                    let refreshed = try await manager.fetchConversation(id: chatId)
                    if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }),
                       !serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.logger.info("Background poll: server completed (\(serverAssistant.content.count) chars)")
                        self.adoptServerMessages(serverConversation: refreshed)
                        await self.sendCompletionNotificationIfNeeded(content: serverAssistant.content)
                        self.cleanupStreaming()
                        self.endBackgroundTask()
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                        return
                    }
                } catch {
                    self.logger.warning("Background poll failed: \(error.localizedDescription)")
                }
            }

            self.endBackgroundTask()
        }
    }

    /// Ends the iOS background task.
    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    /// Recovers streaming state when the app returns to foreground.
    /// Socket events may have been missed while backgrounded, so we check
    /// the server for the actual completion state and adopt it.
    private func recoverFromBackgroundStreaming() async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }

        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            guard let serverAssistant = serverConversation.messages.last(where: { $0.role == .assistant }) else { return }

            let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // If server has content, the generation completed while we were backgrounded
            if !serverContent.isEmpty {
                logger.info("Foreground recovery: server has completed content (\(serverContent.count) chars, \(serverAssistant.files.count) files)")

                // Adopt server state fully (includes files from tool calls)
                adoptServerMessages(serverConversation: serverConversation)

                // Safety net: if server didn't populate files but tool results
                // contain file references, extract them from the message content.
                // This is the primary fix for the "backgrounded during image gen" scenario.
                if let lastAssistantId = conversation?.messages.last(where: { $0.role == .assistant })?.id {
                    populateFilesFromToolResults(messageId: lastAssistantId)
                }

                // Send notification — generation completed while we were away
                await sendCompletionNotificationIfNeeded(content: serverContent)

                // Cleanup streaming state
                cleanupStreaming()

                // Notify conversation list
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

                // Schedule a delayed re-sync to pick up title, follow-ups, and tags.
                // These background tasks run asynchronously on the server and may not
                // be ready when we first recover. A 3s + 8s poll catches most cases.
                Task {
                    for delay: UInt64 in [3, 8] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        await self.syncWithServer()
                    }
                }
            }
            // If server content is still empty, streaming may still be in progress.
            // The existing socket handlers / recovery timer will handle it when
            // the socket reconnects.
        } catch {
            logger.warning("Foreground recovery failed: \(error.localizedDescription)")
        }
    }

    func loadModels() async {
        guard let manager else { return }
        isLoadingModels = true
        do {
            availableModels = try await manager.fetchModels()
            if selectedModelId == nil {
                if let def = await manager.fetchDefaultModel() {
                    selectedModelId = def
                } else {
                    selectedModelId = availableModels.first?.id
                }
            }
            // Write back to shared cache so subsequent VMs are pre-populated
            activeChatStore?.updateModelCache(models: availableModels, selectedId: selectedModelId)
        } catch {
            logger.error("Failed to load models: \(error.localizedDescription)")
        }
        isLoadingModels = false
        // Sync UI toggles with model defaults after models are loaded
        syncUIWithModelDefaults()
    }

    /// Silently refreshes the model list from the server in the background.
    /// Called when the user opens the model picker to pick up admin-added models.
    func refreshModelsInBackground() {
        guard !isLoadingModels else { return }
        Task { await loadModels() }
    }

    /// Fetches terminal servers available to the user.
    ///
    /// Called once at chat load time. If any terminals are available, the
    /// user can toggle them on via the terminal pill in the input field.
    func loadTerminalServers() async {
        guard let manager else { return }
        do {
            availableTerminalServers = try await manager.fetchTerminalServers()
            // Auto-select first terminal if only one available
            if selectedTerminalServer == nil, let first = availableTerminalServers.first {
                selectedTerminalServer = first
            }
        } catch {
            logger.debug("Terminal servers fetch failed: \(error.localizedDescription)")
        }
    }

    /// Toggles the terminal on/off. When turning on, auto-selects the first
    /// server if none is selected. When multiple servers are available,
    /// the caller should set `selectedTerminalServer` before enabling.
    func toggleTerminal() {
        if terminalEnabled {
            terminalEnabled = false
        } else {
            if selectedTerminalServer == nil, let first = availableTerminalServers.first {
                selectedTerminalServer = first
            }
            terminalEnabled = true
        }
    }

    func loadTools() async {
        guard let manager else { return }
        isLoadingTools = true
        do {
            let serverTools = try await manager.fetchTools()
            if !serverTools.isEmpty {
                availableTools = serverTools
                // Auto-select globally-enabled tools (server-side defaults)
                // and model-assigned tools into selectedToolIds
                syncToolSelectionWithDefaults()
                isLoadingTools = false
                return
            }
        } catch {
            logger.warning("Failed to fetch tools: \(error.localizedDescription)")
        }
        var seen = Set<String>()
        var items: [ToolItem] = []
        for model in availableModels {
            for toolId in model.toolIds where !seen.contains(toolId) {
                seen.insert(toolId)
                items.append(ToolItem(
                    id: toolId,
                    name: toolId.replacingOccurrences(of: "_", with: " ").capitalized,
                    description: nil
                ))
            }
        }
        availableTools = items
        syncToolSelectionWithDefaults()
        isLoadingTools = false
    }

    /// Adds globally-enabled tools (server `is_active`) and model-assigned
    /// tools to `selectedToolIds` so the toggles show as on by default.
    /// Respects `userDisabledToolIds` — tools the user explicitly toggled
    /// OFF during this session are NOT re-enabled by server defaults.
    private func syncToolSelectionWithDefaults() {
        // 1. Globally-enabled tools (server admin marked as active)
        for tool in availableTools where tool.isEnabled {
            if !userDisabledToolIds.contains(tool.id) {
                selectedToolIds.insert(tool.id)
            }
        }
        // 2. Model-assigned tools (admin attached to the selected model)
        if let model = selectedModel {
            for toolId in model.toolIds {
                if !userDisabledToolIds.contains(toolId) {
                    selectedToolIds.insert(toolId)
                }
            }
        }
    }

    // MARK: - Knowledge

    /// Timestamp of the last knowledge fetch — used for stale-while-revalidate.
    private var lastKnowledgeFetchTime: Date = .distantPast

    /// Fetches knowledge bases and user files for the `#` picker.
    ///
    /// Uses a **stale-while-revalidate** strategy:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    /// - Cache is refreshed every time the picker opens (async).
    func loadKnowledgeItems() {
        // If we already have cached items, show them immediately
        // and refresh in the background (stale-while-revalidate)
        if !knowledgeItems.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchKnowledgeItemsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingKnowledge = true
        Task {
            await fetchKnowledgeItemsFromServer()
            isLoadingKnowledge = false
        }
    }

    /// Fetches folders + knowledge bases + knowledge files from the server
    /// and updates the cache. All 3 APIs are called concurrently.
    private func fetchKnowledgeItemsFromServer() async {
        guard let manager else { return }

        // Fetch all 3 sources concurrently — each is independent and
        // a single failure shouldn't prevent the others from showing.
        async let foldersReq: [KnowledgeItem] = {
            (try? await manager.fetchFolderItems()) ?? []
        }()
        async let collectionsReq: [KnowledgeItem] = {
            (try? await manager.fetchKnowledgeItems()) ?? []
        }()
        async let filesReq: [KnowledgeItem] = {
            (try? await manager.fetchKnowledgeFileItems()) ?? []
        }()

        let (folders, collections, files) = await (foldersReq, collectionsReq, filesReq)

        // Only update if we got at least something
        let combined = folders + collections + files
        if !combined.isEmpty || knowledgeItems.isEmpty {
            knowledgeItems = combined
        }
        lastKnowledgeFetchTime = Date()
    }

    /// Called when a knowledge item is selected from the `#` picker.
    ///
    /// Adds the item to the selected list (if not already there),
    /// removes the `#query` from the input text, and dismisses the picker.
    func selectKnowledgeItem(_ item: KnowledgeItem) {
        // Avoid duplicates
        guard !selectedKnowledgeItems.contains(where: { $0.id == item.id }) else {
            dismissKnowledgePicker()
            return
        }
        selectedKnowledgeItems.append(item)

        // Remove the `#query` token from input text
        removeHashToken()
        dismissKnowledgePicker()
    }

    /// Removes the `#...` token from the input text (the text from the last `#`
    /// at a word boundary up to the cursor position).
    private func removeHashToken() {
        let text = inputText
        // Find the last `#` at a word boundary
        guard let hashIndex = text.lastIndex(of: "#") else { return }
        let hashPos = text.distance(from: text.startIndex, to: hashIndex)
        let isAtStart = hashPos == 0
        let precededBySpace = hashPos > 0 && {
            let beforeIdx = text.index(before: hashIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            // Remove from `#` to the end of the current token (no whitespace after #)
            let afterHash = text[hashIndex...]
            let tokenEnd = afterHash.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<hashIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Removes the `@...` token from the input text (the text from the last `@`
    /// at a word boundary up to the cursor position).
    func removeMentionToken() {
        let text = inputText
        guard let atIndex = text.lastIndex(of: "@") else { return }
        let atPos = text.distance(from: text.startIndex, to: atIndex)
        let isAtStart = atPos == 0
        let precededBySpace = atPos > 0 && {
            let beforeIdx = text.index(before: atIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterAt = text[atIndex...]
            let tokenEnd = afterAt.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<atIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Dismisses the knowledge picker popup.
    func dismissKnowledgePicker() {
        isShowingKnowledgePicker = false
        knowledgeSearchQuery = ""
    }

    // MARK: - Prompt Slash Commands

    /// Fetches the prompt library from the server.
    ///
    /// Uses a **stale-while-revalidate** strategy like knowledge items:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    /// - Only fetches active prompts (is_active == true) from `GET /api/v1/prompts/`.
    func loadPrompts() {
        if !availablePrompts.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchPromptsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingPrompts = true
        Task {
            await fetchPromptsFromServer()
            isLoadingPrompts = false
        }
    }

    /// Fetches prompts from the server API.
    private func fetchPromptsFromServer() async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let raw = try await apiClient.getPrompts()
            let parsed = raw.compactMap { PromptItem(json: $0) }
            // Only cache active prompts — disabled prompts don't appear in slash commands
            availablePrompts = parsed.filter(\.isActive)
            logger.info("Loaded \(self.availablePrompts.count) active prompts")
        } catch {
            logger.warning("Failed to load prompts: \(error.localizedDescription)")
        }
    }

    /// Called when the user selects a prompt from the `/` picker.
    ///
    /// 1. Removes the `/query` token from the input text
    /// 2. Dismisses the picker
    /// 3. Extracts custom variables from the prompt content
    /// 4. If variables exist → presents the variable input sheet
    /// 5. If no variables → processes and inserts the prompt directly
    func selectPrompt(_ prompt: PromptItem) {
        // Remove the `/command` token from input text
        removeSlashToken()
        dismissPromptPicker()

        // Extract custom input variables (skips system variables)
        let variables = PromptService.extractCustomVariables(from: prompt.content)

        if variables.isEmpty {
            // No variables — process system variables and insert directly
            let processed = PromptService.resolveSystemVariables(
                in: prompt.content,
                userName: nil,
                userEmail: nil
            )
            inputText = processed
        } else {
            // Has variables — present the variable input sheet
            pendingPromptForVariables = prompt
            pendingPromptVariables = variables
        }

        Haptics.play(.light)
    }

    /// Called when the user submits variable values from the PromptVariableSheet.
    func submitPromptVariables(values: [String: String]) {
        guard let prompt = pendingPromptForVariables else { return }
        let variables = pendingPromptVariables

        let processed = PromptService.processPrompt(
            content: prompt.content,
            userValues: values,
            variables: variables,
            userName: nil,
            userEmail: nil
        )

        inputText = processed
        pendingPromptForVariables = nil
        pendingPromptVariables = []

        Haptics.play(.light)
    }

    /// Called when the user cancels the variable input sheet.
    func cancelPromptVariables() {
        pendingPromptForVariables = nil
        pendingPromptVariables = []
    }

    /// Removes the `/...` token from the input text (the text from the last `/`
    /// at a word boundary up to the cursor position).
    private func removeSlashToken() {
        let text = inputText
        guard let slashIndex = text.lastIndex(of: "/") else { return }
        let slashPos = text.distance(from: text.startIndex, to: slashIndex)
        let isAtStart = slashPos == 0
        let precededBySpace = slashPos > 0 && {
            let beforeIdx = text.index(before: slashIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterSlash = text[slashIndex...]
            let tokenEnd = afterSlash.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<slashIndex]) + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Dismisses the prompt picker popup.
    func dismissPromptPicker() {
        isShowingPromptPicker = false
        promptSearchQuery = ""
    }

    // MARK: - Skills Dollar Commands

    /// Fetches active skills from the server for the `$` picker.
    ///
    /// Uses a **stale-while-revalidate** strategy like prompts:
    /// - If cache exists, shows it instantly and refreshes in the background.
    /// - If no cache, shows a loading state while fetching.
    func loadSkills() {
        if !availableSkills.isEmpty {
            // Background refresh — no loading indicator
            Task { await fetchSkillsFromServer() }
            return
        }

        // No cache — show loading state
        isLoadingSkills = true
        Task {
            await fetchSkillsFromServer()
            isLoadingSkills = false
        }
    }

    /// Fetches skills from the server API.
    private func fetchSkillsFromServer() async {
        guard let apiClient = manager?.apiClient else { return }
        do {
            let items = try await apiClient.getSkills()
            // Only cache active skills — disabled skills don't appear in $ commands
            availableSkills = items.filter(\.isActive)
            logger.info("Loaded \(self.availableSkills.count) active skills")
        } catch {
            logger.warning("Failed to load skills: \(error.localizedDescription)")
        }
    }

    /// Called when the user selects a skill from the `$` picker.
    ///
    /// Replaces the `$query` token with `<$slug|slug> ` in the input text
    /// (matching the Open WebUI wire format), and records the skill ID in
    /// `selectedSkillIds` so it is sent as `skill_ids` in the API request.
    func selectSkill(_ skill: SkillItem) {
        // Use the web UI format: <$slug|slug>
        replaceDollarTokenWith("<$\(skill.id)|\(skill.id)> ")
        dismissSkillPicker()

        if !selectedSkillIds.contains(skill.id) {
            selectedSkillIds.append(skill.id)
        }

        Haptics.play(.light)
    }

    /// Replaces the `$...` token in the input text with `replacement`.
    /// The token is the text from the last bare `$` (at start or preceded by
    /// whitespace) up to the next whitespace or end of string.
    private func replaceDollarTokenWith(_ replacement: String) {
        let text = inputText
        guard let dollarIndex = text.lastIndex(of: "$") else { return }
        let dollarPos = text.distance(from: text.startIndex, to: dollarIndex)
        let isAtStart = dollarPos == 0
        let precededBySpace = dollarPos > 0 && {
            let beforeIdx = text.index(before: dollarIndex)
            return text[beforeIdx].isWhitespace || text[beforeIdx].isNewline
        }()

        if isAtStart || precededBySpace {
            let afterDollar = text[dollarIndex...]
            let tokenEnd = afterDollar.firstIndex(where: { $0.isWhitespace || $0.isNewline }) ?? text.endIndex
            let newText = String(text[text.startIndex..<dollarIndex]) + replacement + String(text[tokenEnd...])
            inputText = newText
        }
    }

    /// Removes the `$...` token from the input text (replaces with empty string).
    private func removeDollarToken() {
        replaceDollarTokenWith("")
    }

    /// Dismisses the skill picker popup.
    func dismissSkillPicker() {
        isShowingSkillPicker = false
        skillSearchQuery = ""
    }

    /// Restores `selectedKnowledgeItems` from the conversation's user messages.
    ///
    /// When loading an existing conversation, scans user messages for files
    /// with `type == "collection"`, `"folder"`, or knowledge `"file"` entries
    /// and rebuilds the knowledge chips so they persist across navigation.
    private func restoreKnowledgeItemsFromConversation() {
        guard let conversation, selectedKnowledgeItems.isEmpty else { return }

        // Collect unique knowledge files from the most recent user message
        // that has them. Knowledge files are stored with type "collection"/"folder"/"file".
        let knowledgeTypes: Set<String> = ["collection", "folder"]
        var restored: [KnowledgeItem] = []
        var seenIds = Set<String>()

        // Scan from newest to oldest — find the first user message with knowledge files
        for message in conversation.messages.reversed() where message.role == .user {
            let knowledgeFiles = message.files.filter { f in
                guard let type = f.type else { return false }
                return knowledgeTypes.contains(type)
            }
            if !knowledgeFiles.isEmpty {
                for file in knowledgeFiles {
                    guard let id = file.url, !seenIds.contains(id) else { continue }
                    seenIds.insert(id)
                    let knowledgeType: KnowledgeItem.KnowledgeType
                    switch file.type {
                    case "folder": knowledgeType = .folder
                    case "collection": knowledgeType = .collection
                    default: knowledgeType = .file
                    }
                    restored.append(KnowledgeItem(
                        id: id,
                        name: file.name ?? id,
                        description: nil,
                        type: knowledgeType,
                        fileCount: nil
                    ))
                }
                break // Only restore from the most recent user message
            }
        }

        if !restored.isEmpty {
            selectedKnowledgeItems = restored
            logger.info("Restored \(restored.count) knowledge item(s) from conversation history")
        }
    }

    // MARK: - Passive Socket Listener (Cross-Client Stream Observation)

    /// Registers a persistent, passive socket listener for this chat that
    /// observes ALL socket events broadcast by the server to `user:{id}`.
    ///
    /// This mirrors the Open WebUI website's `Chat.svelte` approach where
    /// `socket.on("events", chatEventHandler)` listens for events matching
    /// the current `chat_id` — regardless of which client initiated the generation.
    ///
    /// The passive listener enables bidirectional real-time sync:
    /// - Website starts generation → app sees it streaming live
    /// - App starts generation → website sees it (already worked)
    ///
    /// When the app itself initiates a stream (`sendMessage`/`regenerateResponse`),
    /// the active handlers (`chatSubscription`/`channelSubscription`) take over
    /// and `selfInitiatedStream` is set to `true` so the passive listener skips
    /// content events to avoid conflicts. Metadata events (title, tags, follow-ups)
    /// are always processed by the passive listener regardless.
    private func startPassiveSocketListener() {
        // Only for existing conversations with a known ID
        guard let chatId = conversationId ?? conversation?.id else { return }
        guard let socket = socketService, socket.isConnected else { return }

        // Dispose any previous passive subscription
        passiveSubscription?.dispose()

        passiveSubscription = socket.addChatEventHandler(
            conversationId: chatId,
            sessionId: nil // No session filter — observe ALL events for this chat
        ) { [weak self] event, _ in
            guard let self else { return }
            Task { @MainActor in
                self.handlePassiveEvent(event)
            }
        }

        logger.info("Passive socket listener registered for chat \(chatId)")
    }

    /// Handles a socket event received by the passive listener.
    ///
    /// Processes events from external clients (website, other tabs) that are
    /// generating content for this chat. Skips processing when this VM has
    /// its own active stream (`selfInitiatedStream == true`) to avoid conflicts
    /// with the dedicated active handlers.
    private func handlePassiveEvent(_ event: [String: Any]) {
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]
        let messageId = event["message_id"] as? String
        let chatId = conversationId ?? conversation?.id

        // --- Metadata events: ALWAYS process (title, tags, follow-ups) ---
        switch type {
        case "chat:title":
            var newTitle: String?
            if let titleStr = data["data"] as? String, !titleStr.isEmpty {
                newTitle = titleStr
            } else if let p = payload, let t = p["title"] as? String, !t.isEmpty {
                newTitle = t
            }
            if let newTitle {
                conversation?.title = newTitle
                if let chatId {
                    NotificationCenter.default.post(
                        name: .conversationTitleUpdated,
                        object: nil,
                        userInfo: ["conversationId": chatId, "title": newTitle]
                    )
                }
            }
            return

        case "chat:tags":
            if let chatId, let msgId = messageId {
                Task { try? await refreshConversationMetadata(chatId: chatId, assistantMessageId: msgId) }
            }
            return

        case "chat:message:follow_ups":
            if let msgId = messageId {
                var followUps: [String] = []
                if let payload {
                    followUps = payload["follow_ups"] as? [String]
                        ?? payload["followUps"] as? [String]
                        ?? payload["suggestions"] as? [String] ?? []
                }
                if followUps.isEmpty, let directArray = data["data"] as? [String] {
                    followUps = directArray
                }
                let trimmed = followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !trimmed.isEmpty {
                    appendFollowUps(id: msgId, followUps: trimmed)
                }
            }
            return

        default:
            break
        }

        // --- Content/streaming events: only process when NOT self-initiated ---
        guard !selfInitiatedStream else { return }

        // Extract content from events. Handle both message AND chat:completion
        // event types, using replace-if-longer to prevent duplication.
        var contentDelta: String?
        var isReplace = false
        
        switch type {
        case "chat:message:delta", "event:message:delta":
            contentDelta = payload?["content"] as? String
        case "message", "chat:message", "replace":
            contentDelta = payload?["content"] as? String
            isReplace = true
        case "chat:completion":
            if let choices = payload?["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let c = delta["content"] as? String, !c.isEmpty {
                contentDelta = c
            } else if let c = payload?["content"] as? String, !c.isEmpty {
                contentDelta = c
                isReplace = true
            }
        default:
            break
        }

        // If this is a content event with actual text
        if let contentDelta, !contentDelta.isEmpty {
            guard let msgId = messageId else { return }

            // If message doesn't exist locally, do ONE sync (guarded by flag)
            if conversation?.messages.first(where: { $0.id == msgId }) == nil {
                guard !isSyncingExternalStream else { return }
                isSyncingExternalStream = true
                isExternallyStreaming = true
                isStreaming = true
                // Reset hasFinishedStreaming so self-initiated cleanup guards
                // don't interfere with this new external stream
                hasFinishedStreaming = false
                Task {
                    await self.syncOnceForExternalStream(messageId: msgId)
                    self.isSyncingExternalStream = false
                }
                return
            }

            // Message exists — append content directly (real-time socket streaming)
            if !isExternallyStreaming {
                isExternallyStreaming = true
                isStreaming = true
                // Reset hasFinishedStreaming for each new external stream session
                hasFinishedStreaming = false
                logger.info("External stream: first token for message \(msgId)")
            }
            if let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                if isReplace {
                    // Full content replacement (message, chat:message, replace, chat:completion fallback)
                    conversation?.messages[index].content = contentDelta
                } else {
                    // Delta/token append (chat:message:delta, chat:completion choices.delta)
                    conversation?.messages[index].content += contentDelta
                }
                conversation?.messages[index].isStreaming = true
                triggerStreamingHaptic()
            }

            // Also check for done signal within content events (chat:completion
            // can carry both content AND done:true in the same event)
            if type == "chat:completion", let payload, payload["done"] as? Bool == true {
                let finalContent = conversation?.messages.first(where: { $0.id == msgId })?.content ?? ""
                isExternallyStreaming = false
                isStreaming = false
                isSyncingExternalStream = false
                if let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                    conversation?.messages[index].isStreaming = false
                }
                let chatId = conversationId ?? conversation?.id
                Task {
                    await self.sendCompletionNotificationIfNeeded(content: finalContent)
                    if let chatId {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let manager = self.manager else { return }
                        if let serverConv = try? await manager.fetchConversation(id: chatId) {
                            self.adoptServerMessages(serverConversation: serverConv)
                        }
                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                    }
                }
            }
            return
        }

        // Handle done signal (when no content in the event)
        if type == "chat:completion", let payload, payload["done"] as? Bool == true {
            let finalContent = messageId.flatMap { id in
                conversation?.messages.first(where: { $0.id == id })?.content
            } ?? ""
            isExternallyStreaming = false
            isStreaming = false
            isSyncingExternalStream = false
            if let msgId = messageId,
               let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                conversation?.messages[index].isStreaming = false
            }
            // Final sync to pick up complete content, files, sources
            let chatId = conversationId ?? conversation?.id
            Task {
                await self.sendCompletionNotificationIfNeeded(content: finalContent)
                if let chatId {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let manager = self.manager else { return }
                    if let serverConv = try? await manager.fetchConversation(id: chatId) {
                        self.adoptServerMessages(serverConversation: serverConv)
                    }
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                }
            }
            return
        }

        // Handle errors and cancellation
        if type == "chat:message:error" || type == "chat:tasks:cancel" {
            isExternallyStreaming = false
                isStreaming = false
            isSyncingExternalStream = false
            if let msgId = messageId,
               let index = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
                conversation?.messages[index].isStreaming = false
            }
            return
        }
    }

    /// Fetches conversation from server ONCE to pick up the message structure
    /// (user + assistant messages) that an external client created. After this
    /// sync, the message exists locally and subsequent socket tokens can be
    /// appended directly without needing another fetch.
    private func syncOnceForExternalStream(messageId: String) async {
        guard let chatId = conversationId ?? conversation?.id, let manager else { return }
        do {
            let serverConversation = try await manager.fetchConversation(id: chatId)
            adoptServerMessages(serverConversation: serverConversation)

            // After syncing, mark the target message as streaming
            if let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) {
                conversation?.messages[index].isStreaming = true
            }
            logger.info("External stream: synced messages, now tracking \(messageId)")
        } catch {
            logger.warning("External stream sync failed: \(error.localizedDescription)")
        }
    }

    /// Task for the external stream polling loop.
    private var externalStreamPollTask: Task<Void, Never>?

    /// Starts a polling loop that fetches conversation content from the server
    /// every 1.5 seconds during an external stream. The server persists streamed
    /// content to the database in real-time, so each poll gets the latest
    /// accumulated text — giving a near-real-time streaming effect.
    private func startExternalStreamPolling() {
        // Cancel any existing poll task
        externalStreamPollTask?.cancel()

        let chatId = conversationId ?? conversation?.id
        externalStreamPollTask = Task { @MainActor [weak self] in
            guard let self, let chatId, let manager = self.manager else { return }

            // Initial fetch to pick up new messages (user + assistant from website)
            do {
                let serverConv = try await manager.fetchConversation(id: chatId)
                self.adoptServerMessages(serverConversation: serverConv)
                // Mark last assistant as streaming for UI
                if let lastIdx = self.conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
                    self.conversation?.messages[lastIdx].isStreaming = true
                }
            } catch {
                self.logger.warning("External stream initial fetch failed: \(error.localizedDescription)")
            }

            // Poll every 1.5s until cancelled or stream ends.
            // DO NOT call adoptServerMessages here — it has guards that flip
            // isStreaming back to false (server DB doesn't store isStreaming=true),
            // causing the streaming indicator to vanish and content rendering to break.
            // Instead, just directly set the content from the server response.
            while !Task.isCancelled && self.isExternallyStreaming {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, self.isExternallyStreaming else { break }

                do {
                    let serverConv = try await manager.fetchConversation(id: chatId)
                    if let serverAssistant = serverConv.messages.last(where: { $0.role == .assistant }),
                       let localIdx = self.conversation?.messages.firstIndex(where: { $0.id == serverAssistant.id }) {
                        self.conversation?.messages[localIdx].content = serverAssistant.content
                        self.conversation?.messages[localIdx].isStreaming = true
                    }
                    // Also update title if changed
                    if !serverConv.title.isEmpty && serverConv.title != "New Chat" {
                        self.conversation?.title = serverConv.title
                    }
                } catch {
                    self.logger.warning("External stream poll failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Stops the external stream polling loop and does a final sync.
    private func stopExternalStreamPolling() {
        externalStreamPollTask?.cancel()
        externalStreamPollTask = nil
        isExternallyStreaming = false
                isStreaming = false

        // Mark last assistant as not streaming
        if let lastIdx = conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
            conversation?.messages[lastIdx].isStreaming = false
        }

        logger.info("External stream completed — final sync")

        // Final sync to pick up complete content, files, sources
        let chatId = conversationId ?? conversation?.id
        if let chatId {
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let manager = self.manager else { return }
                if let serverConv = try? await manager.fetchConversation(id: chatId) {
                    self.adoptServerMessages(serverConversation: serverConv)
                }
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
            }
        }
    }

    /// Checks whether an external client is currently streaming to this chat.
    ///
    /// Uses the `POST /api/v1/tasks/active/chats` endpoint to detect in-progress
    /// generations. If active, sets isExternallyStreaming and isStreaming to true, and marks
    /// the last assistant message as streaming so the UI shows the correct state.
    private func checkForActiveExternalStream() async {
        guard let chatId = conversationId ?? conversation?.id else { return }
        guard let apiClient = manager?.apiClient else { return }

        do {
            let activeChats = try await apiClient.checkActiveChats(chatIds: [chatId])
            if activeChats.contains(chatId) {
                // This chat has an active generation from another client
                if let lastAssistant = conversation?.messages.last(where: { $0.role == .assistant }) {
                    // Only mark as externally streaming if the message looks incomplete
                    // (empty or the server is still producing content)
                    let content = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if content.isEmpty || lastAssistant.isStreaming {
                        isExternallyStreaming = true
                isStreaming = true
                        if let index = conversation?.messages.firstIndex(where: { $0.id == lastAssistant.id }) {
                            conversation?.messages[index].isStreaming = true
                        }
                        logger.info("Detected active external stream on chat open")
                    }
                }
            }
        } catch {
            // Non-critical — passive listener will catch events anyway
            logger.debug("Active chat check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - New Conversation

    func startNewConversation() {
        conversation = nil
        inputText = ""
        attachments = []
        errorMessage = nil
        cleanupStreaming()
        webSearchEnabled = false
        imageGenerationEnabled = false
        codeInterpreterEnabled = false
        isTemporaryChat = UserDefaults.standard.bool(forKey: "temporaryChatDefault")
        userDisabledToolIds = []
        selectedToolIds = []
        selectedKnowledgeItems = []
        selectedSkillIds = []
        // Sync UI toggles with the selected model's server-configured defaults.
        syncUIWithModelDefaults()
    }

    /// Converts a temporary chat into a permanent one by saving it to the server.
    func saveTemporaryChat() async {
        guard isTemporaryChat, let conversation, let manager else { return }
        let modelId = selectedModelId ?? conversation.model ?? ""
        do {
            let created = try await manager.createConversation(
                title: conversation.title, messages: [], model: modelId,
                folderId: folderContextId)
            // Update the conversation ID to the server-assigned one
            self.conversation?.id = created.id
            // Sync all messages
            try await manager.syncConversationMessages(
                id: created.id, messages: conversation.messages, model: modelId)
            isTemporaryChat = false
            logger.info("Temporary chat saved as \(created.id)")
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
        } catch {
            logger.error("Failed to save temporary chat: \(error.localizedDescription)")
            errorMessage = "Failed to save chat: \(error.localizedDescription)"
        }
    }

    // MARK: - Sending Messages

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        guard let manager else { return }
        // Use mentioned model (@ override) if set, otherwise the chat's selected model
        guard let modelId = mentionedModelId ?? selectedModelId else {
            errorMessage = "Please select a model first."
            return
        }

        // Process audio attachments depending on transcription mode.
        // Server mode: audio was already uploaded via /api/v1/files/?process=true —
        //   treat it like any other uploaded file (pass through with its uploadedFileId).
        // Device mode: on-device transcription produced transcribedText — convert that
        //   to a .txt file attachment so the model can read it as a document.
        let audioFileMode = UserDefaults.standard.string(forKey: "audioFileTranscriptionMode") ?? "server"
        var processedAttachments: [ChatAttachment] = []

        for attachment in attachments {
            if attachment.type == .audio {
                if audioFileMode == "server" {
                    // Server already transcribed the file — pass it through so
                    // the uploadedFileId is included in the message payload.
                    processedAttachments.append(attachment)
                } else {
                    // On-device mode: convert transcription to a text file attachment.
                    if let transcript = attachment.transcribedText, !transcript.isEmpty {
                        let baseName = (attachment.name as NSString).deletingPathExtension
                        let transcriptFileName = "\(baseName)_transcript.txt"
                        let transcriptData = transcript.data(using: .utf8) ?? Data()

                        let textAttachment = ChatAttachment(
                            type: .file,
                            name: transcriptFileName,
                            thumbnail: nil,
                            data: transcriptData
                        )
                        processedAttachments.append(textAttachment)
                    }
                    // Don't include the raw audio file in device mode — only the transcript
                }
            } else {
                processedAttachments.append(attachment)
            }
        }

        // Capture and clear knowledge items — they attach to this message only.
        // The server handles RAG retrieval per-message from the files array.
        let currentKnowledgeItems = selectedKnowledgeItems
        selectedKnowledgeItems = []

        // Capture and clear skill IDs — sent as skill_ids in the API request.
        let currentSkillIds = selectedSkillIds
        selectedSkillIds = []

        let currentText = text
        let currentAttachments = processedAttachments
        inputText = ""
        attachments = []
        errorMessage = nil

        // Build file references from pre-uploaded attachments.
        // Files are uploaded at attach time (uploadAttachmentImmediately),
        // so we just collect the already-assigned file IDs here.
        // Only fall back to uploading at send time for attachments that
        // somehow don't have a file ID yet (e.g., audio transcription text files).
        var fileRefs: [[String: Any]] = []
        for attachment in currentAttachments {
            if let fileId = attachment.uploadedFileId {
                // Already uploaded + processed — just reference the ID
                fileRefs.append([
                    "type": attachment.type == .image ? "image" : "file",
                    "id": fileId,
                    "name": attachment.name
                ])
            } else if let data = attachment.data, attachment.uploadStatus != .error {
                // Fallback: upload now (e.g., audio transcript text files that don't go
                // through uploadAttachmentImmediately). Skip attachments that previously
                // failed — the error chip is already shown; the user must retry or remove.
                do {
                    let fileId = try await manager.uploadFile(data: data, fileName: attachment.name)
                    fileRefs.append([
                        "type": attachment.type == .image ? "image" : "file",
                        "id": fileId,
                        "name": attachment.name
                    ])
                } catch {
                    logger.error("Upload failed: \(error.localizedDescription)")
                }
            }
            // Note: attachments with uploadStatus == .error and no uploadedFileId are
            // intentionally skipped — they failed at attach-time and must be retried or removed.
        }

        // Create user message - store file IDs (not base64) matching Flutter behavior
        let uploadedAttachmentIds = fileRefs.compactMap { $0["id"] as? String }
        var messageFiles: [ChatMessageFile] = fileRefs.map { ref in
            // Derive content_type from filename so the Open WebUI web client
            // knows to append `/content` to the file URL. Without content_type,
            // the web client constructs `/files/{id}` (returns JSON metadata)
            // instead of `/files/{id}/content` (returns actual file bytes).
            // This affects images (broken thumbnails), PDFs, docs, and all files.
            let name = ref["name"] as? String
            let contentType: String? = mimeType(for: name ?? "file")
            return ChatMessageFile(
                type: ref["type"] as? String,
                url: ref["id"] as? String,  // Store file ID, not base64
                name: name,
                contentType: contentType
            )
        }
        // Also store knowledge items (collection/folder/file) on the user message
        // so they persist in conversation history and appear on reload.
        for knowledgeItem in currentKnowledgeItems {
            messageFiles.append(ChatMessageFile(
                type: knowledgeItem.type.rawValue,
                url: knowledgeItem.id,
                name: knowledgeItem.name,
                contentType: nil
            ))
        }
        let userMessage = ChatMessage(
            role: .user,
            content: currentText,
            timestamp: .now,
            attachmentIds: uploadedAttachmentIds,
            files: messageFiles
        )

        // Ensure conversation exists on server (skip for temporary chats)
        if conversation == nil {
            let chatTitle = String(currentText.prefix(50))
            var serverId: String?
            if !isTemporaryChat {
                do {
                    let created = try await manager.createConversation(
                        title: chatTitle, messages: [], model: modelId,
                        folderId: folderContextId)
                    serverId = created.id
                } catch {
                    logger.warning("Pre-create failed: \(error.localizedDescription)")
                }
            }
            let localId = isTemporaryChat ? "local:\(UUID().uuidString)" : (serverId ?? UUID().uuidString)
            conversation = Conversation(
                id: localId,
                title: chatTitle, model: modelId, messages: [userMessage])
            // Update active conversation ID so notifications are suppressed
            // while the user is viewing this newly created chat
            NotificationService.shared.activeConversationId = localId
        } else {
            conversation?.messages.append(userMessage)
        }

        // Assistant placeholder
        let assistantMessageId = UUID().uuidString
        conversation?.messages.append(ChatMessage(
            id: assistantMessageId, role: .assistant, content: "",
            timestamp: .now, model: modelId, isStreaming: true))

        // Build API messages with image content fetched from server
        let apiMessages = await buildAPIMessagesAsync()
        let parentId = userMessage.id
        sessionId = UUID().uuidString
        let effectiveChatId = conversationId ?? conversation?.id

        // Cancel any previous message's completion task that may still be
        // running delayed polls — prevents it from overwriting this new
        // message's content via adoptServerMessages/refreshConversationMetadata.
        completionTask?.cancel()
        completionTask = nil

        isStreaming = true
        hasFinishedStreaming = false
        socketHasReceivedContent = false
        selfInitiatedStream = true

        // Activate the isolated streaming store so token updates bypass
        // conversation.messages and only invalidate the streaming message view.
        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)

        // Ensure socket connected with resilient retry.
        // For Cloudflare-protected servers, WebSocket connections may be blocked
        // entirely. In that case, we fall back to SSE streaming (normal HTTPS).
        let socket = socketService
        var socketConnected = socket?.isConnected ?? false

        if let socket, !socketConnected {
            // Show "Reconnecting..." status while we wait
            appendStatusUpdate(id: assistantMessageId,
                status: ChatStatusUpdate(action: "reconnecting", description: "Reconnecting to server…", done: false))

            // Try up to 3 times with increasing timeouts (5s, 8s, 12s)
            for (attempt, timeout) in [(1, 5.0), (2, 8.0), (3, 12.0)] as [(Int, TimeInterval)] {
                socketConnected = await socket.ensureConnected(timeout: timeout)
                if socketConnected { break }
                logger.warning("Socket connect attempt \(attempt) failed, retrying…")
            }

            if socketConnected {
                appendStatusUpdate(id: assistantMessageId,
                    status: ChatStatusUpdate(action: "reconnecting", description: "Connected", done: true))
            } else {
                // Socket failed — will use SSE fallback below
                appendStatusUpdate(id: assistantMessageId,
                    status: ChatStatusUpdate(action: "reconnecting", description: "Using direct connection", done: true))
                logger.info("Socket unavailable — falling back to SSE streaming")
            }
        }

        let useSSEFallback = !socketConnected
        let socketSessionId = socket?.sid ?? sessionId

        // Register socket handlers BEFORE HTTP POST (only if socket is connected)
        if socketConnected, let socket {
            registerSocketHandlers(
                socket: socket, assistantMessageId: assistantMessageId,
                modelId: modelId, socketSessionId: socketSessionId,
                effectiveChatId: effectiveChatId)
        }

        // Sync conversation to server — this writes the message tree structure
        // (user message + assistant placeholder with parentId/childrenIds) so the
        // server has the complete history tree. Content passes through as-is
        // (including <details> blocks) which the web client handles natively.
        if let chatId = effectiveChatId {
            do {
                try await manager.syncConversationMessages(
                    id: chatId, messages: conversation?.messages ?? [], model: modelId,
                    title: conversation?.title)
            } catch {
                logger.warning("Pre-sync failed: \(error.localizedDescription)")
            }
        }

        // Send message to server. When socket is connected, use HTTP POST + socket events.
        // When socket is unavailable (e.g., Cloudflare blocking WebSocket), fall back to
        // SSE streaming which uses normal HTTPS and passes through CF with cookie + UA.
        let capturedUseSSEFallback = useSSEFallback
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: assistantMessageId, parentId: parentId)

                // Merge file attachment refs + knowledge item refs into request.files
                var allFileRefs = fileRefs
                for knowledgeItem in currentKnowledgeItems {
                    allFileRefs.append(knowledgeItem.toChatFileRef())
                }
                if !allFileRefs.isEmpty { request.files = allFileRefs }

                // Refresh model metadata to pick up live admin changes
                // (e.g., enabling/disabling web search, image gen, tools)
                await self.refreshSelectedModelMetadata()

                // Populate model_item with the full raw model JSON so OpenWebUI
                // can route the request to the correct pipe/function model.
                // Without model_item, pipe models fail because the server
                // cannot resolve which pipe function to invoke.
                request.modelItem = self.selectedModel?.rawModelItem

                // Flag pipe/function models so toJSON() omits session_id/chat_id/id.
                // Those three fields together trigger the Redis async-task queue (~60s
                // delay). Pipe models stream directly from the HTTP response body.
                if self.selectedModel?.isPipeModel == true {
                    request.isPipeModel = true
                }

                // Populate filter_ids from model's server-configured filter list.
                let modelFilterIds = self.selectedModel?.filterIds ?? []
                if !modelFilterIds.isEmpty { request.filterIds = modelFilterIds }

                // Always send the full features object with explicit true/false for
                // each feature. Omitting features (or only sending true ones) causes
                // the server to fall back to the model's defaultFeatureIds, ignoring
                // toggles the user explicitly turned OFF.
                request.features = self.buildChatFeatures()

                // Always explicitly send the server's function_calling mode.
                // The server reads params["function_calling"] to decide between
                // native and default tool calling. Omitting it or sending empty {}
                // causes the server to fall back to whatever its global default is,
                // which may differ from the per-model setting. Sending "default"
                // explicitly forces the server to use the non-native path even when
                // its global default is "native".
                let functionCallingMode = self.selectedModel?.functionCallingMode ?? "default"
                request.params = ["function_calling": functionCallingMode.isEmpty ? "default" : functionCallingMode]

                // Request usage statistics in the streaming response.
                // Matches the web UI payload: "stream_options": {"include_usage": true}
                // The server forwards this to the LLM provider, which returns usage
                // in the final SSE chunk. We capture it via sendChatCompleted().
                request.streamOptions = ["include_usage": true]

                // Use only selectedToolIds — model-assigned and globally-enabled
                // tools are already synced into selectedToolIds by
                // syncToolSelectionWithDefaults(). This ensures that if the user
                // disabled a tool via the tools sheet, it stays disabled.
                let allToolIds = Array(self.selectedToolIds)
                if !allToolIds.isEmpty { request.toolIds = allToolIds }

                // Include skill IDs selected via the `$` picker.
                // Sent as `skill_ids` in the top-level request body (separate from tool_ids).
                if !currentSkillIds.isEmpty { request.skillIds = currentSkillIds }

                // Include terminal_id if terminal is enabled for this session
                if self.terminalEnabled, let terminalServer = self.selectedTerminalServer {
                    request.terminalId = terminalServer.id
                }

                // Build background tasks — respect BOTH server config AND user settings.
                // A task is only requested if the server admin has it enabled globally
                // AND the user hasn't disabled it locally.
                let serverConfig = self.activeChatStore?.serverTaskConfig ?? .default
                let titleGenEnabled = (UserDefaults.standard.object(forKey: "titleGenerationEnabled") as? Bool ?? true)
                    && serverConfig.enableTitleGeneration
                let suggestionsEnabled = (UserDefaults.standard.object(forKey: "suggestionsEnabled") as? Bool ?? true)
                    && serverConfig.enableFollowUpGeneration
                let tagsEnabled = serverConfig.enableTagsGeneration
                let isFirst = (self.conversation?.messages.filter { !$0.isStreaming }.count ?? 0) <= 2

                var bgTasks: [String: Any] = [:]
                if suggestionsEnabled { bgTasks["follow_up_generation"] = true }
                if isFirst && titleGenEnabled { bgTasks["title_generation"] = true }
                if isFirst && tagsEnabled { bgTasks["tags_generation"] = true }
                if self.webSearchEnabled { bgTasks["web_search"] = true }
                if !bgTasks.isEmpty { request.backgroundTasks = bgTasks }

                if capturedUseSSEFallback {
                    // ── HTTP + POLLING FALLBACK ──
                    // Socket.IO is unavailable (e.g., Cloudflare blocks WebSocket).
                    // OpenWebUI delivers content via socket events, not SSE — so we
                    // use HTTP POST + aggressive server polling to pick up content
                    // in near-real-time. Poll every 1.5s with no initial delay.
                    self.logger.info("Using HTTP + polling fallback (no socket)")
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: detail))
                        self.cleanupStreaming()
                        return
                    }
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    // Aggressive polling: start immediately, poll every 1.5s
                    // Content is being generated server-side and persisted to DB
                    // in real-time. Each poll picks up the latest accumulated text.
                    self.logger.info("HTTP POST done – starting aggressive polling (no socket)")
                    guard let chatId = effectiveChatId else {
                        self.cleanupStreaming()
                        return
                    }
                    var lastContentLength = 0
                    var staleCount = 0
                    for _ in 0..<40 { // up to ~60s of polling
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if Task.isCancelled { break }

                        do {
                            let refreshed = try await manager.fetchConversation(id: chatId)
                            if let serverAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !serverContent.isEmpty {
                                    self.updateAssistantMessage(id: assistantMessageId, content: serverAssistant.content, isStreaming: true)
                                    // Check if content is still growing
                                    if serverContent.count > lastContentLength {
                                        lastContentLength = serverContent.count
                                        staleCount = 0
                                    } else {
                                        staleCount += 1
                                    }
                                    // If content hasn't changed for 3 consecutive polls (4.5s), it's done
                                    if staleCount >= 3 {
                                        self.logger.info("Polling: content stable at \(serverContent.count) chars — finalizing")
                                        self.updateAssistantMessage(id: assistantMessageId, content: serverAssistant.content, isStreaming: false)
                                        self.hasFinishedStreaming = true
                                        self.isStreaming = false
                                        // Post-completion
                                        self.adoptServerMessages(serverConversation: refreshed)
                                        await manager.sendChatCompleted(chatId: chatId, messageId: assistantMessageId, model: modelId, sessionId: socketSessionId, messages: self.buildSimpleAPIMessages())
                                        try? await self.refreshConversationMetadata(chatId: chatId, assistantMessageId: assistantMessageId)
                                        self.cleanupStreaming()
                                        await self.sendCompletionNotificationIfNeeded(content: serverContent)
                                        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                                        return
                                    }
                                }
                            }
                        } catch {
                            self.logger.warning("Polling failed: \(error.localizedDescription)")
                        }
                    }
                    // Polling exhausted — finalize with whatever we have
                    self.updateAssistantMessage(id: assistantMessageId,
                        content: self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? "",
                        isStreaming: false)
                    self.cleanupStreaming()
                    NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                } else if request.isPipeModel {
                    // ── PIPE MODEL SSE PATH ──
                    // Pipe/function models bypass the Redis async-task queue when
                    // session_id, chat_id, and id are absent. Content streams directly
                    // from the HTTP response body as standard OpenAI SSE.
                    self.logger.info("Using pipe model SSE path for \(modelId)")
                    let acc = ContentAccumulator()

                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }

                            // Content delta tokens
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(
                                    id: assistantMessageId,
                                    content: acc.content,
                                    isStreaming: true
                                )
                            }

                            // Stream finished
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: acc.content.isEmpty ? "" : acc.content,
                                isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription)
                            )
                            self.cleanupStreaming()
                            return
                        }
                    }

                    if Task.isCancelled { return }

                    // Finalize — sync the completed message to server, then do
                    // metadata refresh to pick up any tool-generated files/sources.
                    self.finishStreamingSuccessfully(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        socketSessionId: socketSessionId,
                        effectiveChatId: effectiveChatId,
                        acc: acc
                    )
                } else {
                    // ── SOCKET PATH (normal) ──
                    // HTTP POST returns immediately; content delivered via socket events
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }
                    if let detail = json["detail"] as? String, !detail.isEmpty, json["choices"] == nil {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: detail))
                        self.cleanupStreaming()
                        return
                    }

                    // Capture the server's task_id for server-side stop
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    self.logger.info("HTTP POST done – waiting for socket events")
                    self.startRecoveryTimer(assistantMessageId: assistantMessageId, chatId: effectiveChatId)
                }
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                 isStreaming: false,
                                                 error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    /// Stops the current streaming response by cancelling the server-side task
    /// via `/api/tasks/stop/{taskId}` and cleaning up local state.
    func stopStreaming() {
        // Cancel the local HTTP task
        streamingTask?.cancel()
        streamingTask = nil

        // Stop the server-side task.
        // For self-initiated streams we already have the task_id from the HTTP POST response.
        // For externally-initiated streams (another device/browser) activeTaskId is nil,
        // so we query /api/tasks/chat/{chat_id} to discover and stop all active tasks.
        let chatId = conversationId ?? conversation?.id
        if let taskId = activeTaskId, let apiClient = manager?.apiClient {
            Task {
                try? await apiClient.stopTask(taskId: taskId)
                logger.info("Server task stopped: \(taskId)")
            }
        } else if let chatId, let apiClient = manager?.apiClient {
            Task {
                do {
                    let taskIds = try await apiClient.getTasksForChat(chatId: chatId)
                    for taskId in taskIds {
                        try? await apiClient.stopTask(taskId: taskId)
                        logger.info("External server task stopped: \(taskId)")
                    }
                } catch {
                    logger.warning("Failed to fetch tasks for chat \(chatId): \(error.localizedDescription)")
                }
            }
        }

        // Flush streaming store content back to conversation.messages
        // before cleanup so the partial content is preserved for server sync.
        if streamingStore.isActive, let msgId = streamingStore.streamingMessageId,
           let idx = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
            let result = streamingStore.endStreaming()
            conversation?.messages[idx].content = result.content
            conversation?.messages[idx].isStreaming = false
            if !result.statusHistory.isEmpty {
                conversation?.messages[idx].statusHistory = result.statusHistory
            }
            if !result.sources.isEmpty {
                conversation?.messages[idx].sources = result.sources
            }
        } else if let idx = conversation?.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            conversation?.messages[idx].isStreaming = false
        }

        cleanupStreaming()

        // Sync partial content to server so the chat isn't blank.
        // This is user-initiated stop — the partial content is clean streamed
        // text (no tool result blocks), safe to save back to the server.
        Task {
            if let chatId = conversationId ?? conversation?.id, let manager {
                let modelId = selectedModelId ?? conversation?.model ?? ""
                try? await manager.syncConversationMessages(
                    id: chatId, messages: conversation?.messages ?? [], model: modelId,
                    title: conversation?.title)
            }
        }
    }

    /// Regenerates the last assistant response. Convenience wrapper
    /// around ``regenerateResponse(messageId:)`` for the most common case.
    func regenerateLastResponse() async {
        guard let lastAssistant = conversation?.messages.last(where: { $0.role == .assistant }) else { return }
        await regenerateResponse(messageId: lastAssistant.id)
    }

    /// Regenerates a specific assistant response by its message ID.
    ///
    /// If the targeted message is NOT the last assistant message, all messages
    /// after it are removed first (truncating the conversation to that point),
    /// matching the OpenWebUI web client's regeneration behavior for mid-conversation
    /// messages.
    func regenerateResponse(messageId: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard let assistantIdx = conversation?.messages.firstIndex(where: { $0.id == messageId && $0.role == .assistant }) else { return }

        // If regenerating a message that's NOT the last one, truncate everything after it
        if let totalCount = conversation?.messages.count, assistantIdx < totalCount - 1 {
            conversation?.messages.removeSubrange((assistantIdx + 1)..<totalCount)
        }

        // Save the current response as a version before regenerating
        // Include files and model so switching versions restores images/attachments
        let currentMessage = conversation!.messages[assistantIdx]
        let version = ChatMessageVersion(
            content: currentMessage.content,
            timestamp: currentMessage.timestamp,
            model: currentMessage.model,
            error: currentMessage.error,
            files: currentMessage.files,
            sources: currentMessage.sources,
            followUps: currentMessage.followUps
        )
        conversation?.messages[assistantIdx].versions.append(version)

        // Clear the current content, files, and reset for a new response
        // Files must be cleared so tool-generated images from previous
        // generation don't persist into the new response
        conversation?.messages[assistantIdx].content = ""
        conversation?.messages[assistantIdx].files = []
        conversation?.messages[assistantIdx].embeds = []
        conversation?.messages[assistantIdx].isStreaming = true
        conversation?.messages[assistantIdx].error = nil
        conversation?.messages[assistantIdx].sources = []
        conversation?.messages[assistantIdx].statusHistory = []
        conversation?.messages[assistantIdx].followUps = []
        conversation?.messages[assistantIdx].timestamp = .now
        // Update the model to the currently selected one so the bubble label
        // reflects the new model immediately (e.g. user switched model before regenerating).
        conversation?.messages[assistantIdx].model = selectedModelId ?? conversation?.model

        // Get the user's last message to resend
        guard let lastUser = conversation?.messages.last(where: { $0.role == .user }) else { return }

        let apiMessages = await buildAPIMessagesAsync()
        let parentId = lastUser.id
        let assistantMessageId = currentMessage.id
        let modelId = selectedModelId ?? conversation?.model ?? ""
        sessionId = UUID().uuidString
        let effectiveChatId = conversationId ?? conversation?.id

        // Reset streaming state — must set hasFinishedStreaming = false so
        // the new streaming session's cleanup will work
        isStreaming = true
        hasFinishedStreaming = false
        selfInitiatedStream = true

        // Activate the isolated streaming store for the regenerated message
        streamingStore.beginStreaming(messageId: assistantMessageId, modelId: modelId)

        // Cancel any previous subscriptions/timers
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil

        guard let socket = socketService else {
            updateAssistantMessage(id: assistantMessageId, content: "No connection available.",
                                   isStreaming: false, error: ChatMessageError(content: "No socket"))
            isStreaming = false
            return
        }
        if !socket.isConnected {
            let ok = await socket.ensureConnected(timeout: 10.0)
            if !ok {
                updateAssistantMessage(
                    id: assistantMessageId,
                    content: "Unable to connect. Check your connection.",
                    isStreaming: false,
                    error: ChatMessageError(content: "Connection failed"))
                isStreaming = false
                return
            }
        }

        let socketSessionId = socket.sid ?? sessionId

        // Sync the cleared message to server BEFORE registering socket handlers
        // so the server knows we've cleared the content and won't send old content back.
        if let chatId = effectiveChatId {
            do {
                try await manager?.syncConversationMessages(
                    id: chatId, messages: conversation?.messages ?? [], model: modelId,
                    title: conversation?.title)
            } catch {
                logger.warning("Pre-sync for regeneration failed: \(error.localizedDescription)")
            }
        }

        registerSocketHandlers(
            socket: socket, assistantMessageId: assistantMessageId,
            modelId: modelId, socketSessionId: socketSessionId,
            effectiveChatId: effectiveChatId)

        streamingTask = Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            do {
                var request = ChatCompletionRequest(
                    model: modelId, messages: apiMessages, stream: true,
                    chatId: effectiveChatId, sessionId: socketSessionId,
                    messageId: assistantMessageId, parentId: parentId)

                // Refresh model metadata to pick up live admin changes
                await self.refreshSelectedModelMetadata()

                // Populate model_item with the full raw model JSON so OpenWebUI
                // can route the request to the correct pipe/function model.
                request.modelItem = self.selectedModel?.rawModelItem

                // Populate filter_ids from model's server-configured filter list.
                let regenFilterIds = self.selectedModel?.filterIds ?? []
                if !regenFilterIds.isEmpty { request.filterIds = regenFilterIds }

                // Always send the full features object with explicit true/false.
                let regenFeatures = self.buildChatFeatures()
                request.features = regenFeatures

                // Always explicitly send the server's function_calling mode.
                let functionCallingMode = self.selectedModel?.functionCallingMode ?? "default"
                request.params = ["function_calling": functionCallingMode.isEmpty ? "default" : functionCallingMode]

                // Request usage statistics in the streaming response (matches web UI).
                request.streamOptions = ["include_usage": true]

                // Use only selectedToolIds — respects user's in-session disabling
                let allToolIds = Array(self.selectedToolIds)
                if !allToolIds.isEmpty { request.toolIds = allToolIds }

                // Include terminal_id if terminal is enabled for this session
                if self.terminalEnabled, let terminalServer = self.selectedTerminalServer {
                    request.terminalId = terminalServer.id
                }

                let suggestionsEnabled = UserDefaults.standard.object(forKey: "suggestionsEnabled") as? Bool ?? true
                var bgTasks: [String: Any] = [:]
                if suggestionsEnabled { bgTasks["follow_up_generation"] = true }
                if regenFeatures.webSearch { bgTasks["web_search"] = true }
                request.backgroundTasks = bgTasks

                // Flag pipe/function models so toJSON() omits session_id/chat_id/id.
                if self.selectedModel?.isPipeModel == true {
                    request.isPipeModel = true
                }

                if request.isPipeModel {
                    // ── PIPE MODEL SSE PATH (regeneration) ──
                    self.logger.info("Regenerate: using pipe model SSE path for \(modelId)")
                    let acc = ContentAccumulator()

                    do {
                        let sseStream = try await manager.apiClient.sendMessagePipeSSE(request: request)
                        for try await event in sseStream {
                            if Task.isCancelled { break }
                            if let delta = event.contentDelta, !delta.isEmpty {
                                acc.append(delta)
                                self.updateAssistantMessage(
                                    id: assistantMessageId, content: acc.content, isStreaming: true)
                            }
                            if event.isFinished { break }
                        }
                    } catch {
                        if !Task.isCancelled {
                            self.updateAssistantMessage(
                                id: assistantMessageId,
                                content: acc.content.isEmpty ? "" : acc.content,
                                isStreaming: false,
                                error: ChatMessageError(content: error.localizedDescription))
                            self.cleanupStreaming()
                            return
                        }
                    }

                    if Task.isCancelled { return }

                    self.finishStreamingSuccessfully(
                        assistantMessageId: assistantMessageId,
                        modelId: modelId,
                        socketSessionId: socketSessionId,
                        effectiveChatId: effectiveChatId,
                        acc: acc
                    )
                } else {
                    let json = try await manager.sendMessageHTTP(request: request)

                    if let err = json["error"] as? String, !err.isEmpty {
                        self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                     isStreaming: false, error: ChatMessageError(content: err))
                        self.cleanupStreaming()
                        return
                    }

                    // Capture the server's task_id for server-side stop
                    if let taskId = json["task_id"] as? String {
                        self.activeTaskId = taskId
                    }

                    self.logger.info("Regenerate HTTP POST done – waiting for socket events")
                    // Do NOT start recovery timer for regeneration — the server still
                    // may have stale content until new streaming completes.
                }
            } catch {
                if !Task.isCancelled {
                    self.updateAssistantMessage(id: assistantMessageId, content: "",
                                                 isStreaming: false,
                                                 error: ChatMessageError(content: error.localizedDescription))
                    self.cleanupStreaming()
                }
            }
        }
    }

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
        // Switching models is a deliberate user action — reset disabled tools
        // so the new model's defaults apply cleanly without stale overrides.
        userDisabledToolIds = []
        syncUIWithModelDefaults()
        conversation?.model = modelId
        // Fetch full model config from single-model endpoint to get params.function_calling,
        // toolIds, defaultFeatureIds, and capabilities — which /api/models doesn't return.
        Task { [weak self] in
            await self?.refreshSelectedModelConfig()
        }
    }

    // MARK: - Edit & Delete Messages

    /// Edits a user message: replaces its content and removes all messages
    /// after it, then resends with the new content. This matches the Flutter
    /// app's behavior where editing a message resets the conversation from
    /// that point forward.
    func editMessage(id: String, newContent: String) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        guard conversation?.messages[index].role == .user else { return }

        // Remove the edited user message and all messages after it.
        // We'll let sendMessage() recreate the user message with the new content.
        if let totalCount = conversation?.messages.count, totalCount > index {
            conversation?.messages.removeSubrange(index..<totalCount)
        }

        // Sync truncated conversation to server
        if let chatId = conversationId ?? conversation?.id, let manager {
            let modelId = selectedModelId ?? conversation?.model ?? ""
            try? await manager.syncConversationMessages(
                id: chatId, messages: conversation?.messages ?? [], model: modelId,
                title: conversation?.title)
        }

        // Resend with the new content — sendMessage() will create
        // the user message and assistant placeholder cleanly.
        inputText = newContent
        await sendMessage()
    }

    /// Deletes a specific message from the conversation.
    /// If the message is a user message and there's an assistant response after it,
    /// both are removed. If it's the last assistant message, only that is removed.
    ///
    /// For assistant messages with versions (regeneration history):
    /// - Only the currently viewed version is removed instead of the entire message.
    /// - If viewing the main (latest) content, the most recent version is promoted.
    /// - If viewing an older version, that version is removed from the array.
    /// - The full message is only deleted when no versions remain.
    ///
    /// - Parameter activeVersionIndex: The currently viewed version index for assistant
    ///   messages. `-1` or `nil` means the main/latest content. `0...N-1` means a
    ///   specific version from `message.versions`. Ignored for user messages.
    func deleteMessage(id: String, activeVersionIndex: Int? = nil) async {
        guard !isStreaming || isExternallyStreaming else { return }
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }

        let message = conversation!.messages[index]

        if message.role == .user {
            // Remove user message and the following assistant message (if any)
            var removeIndices = IndexSet([index])
            if index + 1 < (conversation?.messages.count ?? 0),
               conversation?.messages[index + 1].role == .assistant {
                removeIndices.insert(index + 1)
            }
            conversation?.messages.remove(atOffsets: removeIndices)
        } else if message.role == .assistant && !message.versions.isEmpty {
            // Assistant message with versions — only remove the active version
            let vIdx = activeVersionIndex ?? -1

            if vIdx < 0 {
                // Viewing the main (latest) content — promote the last version
                let lastVersion = message.versions.last!
                conversation?.messages[index].content = lastVersion.content
                conversation?.messages[index].timestamp = lastVersion.timestamp
                conversation?.messages[index].model = lastVersion.model
                conversation?.messages[index].error = lastVersion.error
                conversation?.messages[index].files = lastVersion.files
                conversation?.messages[index].sources = lastVersion.sources
                conversation?.messages[index].followUps = lastVersion.followUps
                conversation?.messages[index].versions.removeLast()
            } else if vIdx >= 0 && vIdx < message.versions.count {
                // Viewing a specific older version — remove it
                conversation?.messages[index].versions.remove(at: vIdx)
            } else {
                // Invalid index — fall back to removing the entire message
                conversation?.messages.remove(at: index)
            }
        } else {
            // No versions — remove just this message
            conversation?.messages.remove(at: index)
        }

        // Sync to server
        if let chatId = conversationId ?? conversation?.id, let manager {
            let modelId = selectedModelId ?? conversation?.model ?? ""
            try? await manager.syncConversationMessages(
                id: chatId, messages: conversation?.messages ?? [], model: modelId,
                title: conversation?.title)
        }

        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }

    // MARK: - WebSocket Event Handlers

    private func registerSocketHandlers(
        socket: SocketIOService,
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?
    ) {
        chatSubscription?.dispose()
        channelSubscription?.dispose()
        let acc = ContentAccumulator()

        // Wire up the throttled UI update callback.
        // The accumulator coalesces rapid token arrivals into ~30 fps
        // updates, preventing main actor congestion that causes the
        // "no stream then all text at once" symptom.
        let msgId = assistantMessageId
        acc.onUpdate = { [weak self] content in
            // Guard: if streaming already finished (done:true processed),
            // ignore late-arriving accumulated content dispatches.
            guard let self, !self.hasFinishedStreaming else { return }
            self.socketHasReceivedContent = true
            self.updateAssistantMessage(id: msgId, content: content, isStreaming: true)
        }

        chatSubscription = socket.addChatEventHandler(
            conversationId: effectiveChatId,
            sessionId: socketSessionId
        ) { [weak self] event, ack in
            guard let self else { return }
            // Fast-path: check if this is a content delta we can handle
            // entirely through the throttled accumulator WITHOUT scheduling
            // a @MainActor task per token.
            let data = event["data"] as? [String: Any] ?? event
            let type = data["type"] as? String
            if type == "chat:message:delta" || type == "message" || type == "event:message:delta" {
                let payload = data["data"] as? [String: Any]
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    // Append directly — the accumulator's onUpdate callback
                    // handles dispatching to the main actor at throttled rate.
                    acc.append(content)
                    return
                }
            }
            // For all other event types, dispatch to main actor normally
            Task { @MainActor in
                self.handleChatEvent(
                    event, ack: ack, assistantMessageId: assistantMessageId,
                    modelId: modelId, socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId, acc: acc)
            }
        }

        channelSubscription = socket.addChannelEventHandler(
            conversationId: effectiveChatId,
            sessionId: socketSessionId
        ) { [weak self] event, _ in
            guard let self else { return }
            // Fast-path for channel content deltas
            let data = event["data"] as? [String: Any] ?? event
            let type = data["type"] as? String
            let payload = data["data"] as? [String: Any]
            if type == "message", let content = payload?["content"] as? String, !content.isEmpty {
                acc.append(content)
                return
            }
            Task { @MainActor in
                self.handleChannelEvent(event, assistantMessageId: assistantMessageId, acc: acc)
            }
        }
    }

    private func handleChatEvent(
        _ event: [String: Any], ack: ((Any?) -> Void)?,
        assistantMessageId: String, modelId: String,
        socketSessionId: String, effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]

        // Title, tags, follow-ups, and sources can arrive AFTER done:true
        // so we must NOT guard on hasFinishedStreaming for those event types.
        // Only guard for content-producing events.

        switch type {
        // --- Events that MUST work after streaming finishes ---

        case "chat:title":
            // Title can be a direct string or nested in payload
            var newTitle: String?
            if let titleStr = data["data"] as? String, !titleStr.isEmpty {
                newTitle = titleStr
            } else if let p = payload, let t = p["title"] as? String, !t.isEmpty {
                newTitle = t
            } else if let p = payload {
                for (_, value) in p {
                    if let s = value as? String, !s.isEmpty && s.count < 200 {
                        newTitle = s
                        break
                    }
                }
            }
            if let newTitle {
                conversation?.title = newTitle
                logger.info("Title updated: \(newTitle)")
                // NOTE: We do NOT persist the title back to the server here.
                // The server generated this title via background_tasks and already
                // has it stored. Writing it back would be redundant and could race
                // with the server's own save.
                if let chatId = effectiveChatId {
                    // Notify the conversation list to update
                    NotificationCenter.default.post(
                        name: .conversationTitleUpdated,
                        object: nil,
                        userInfo: ["conversationId": chatId, "title": newTitle]
                    )
                }
            }

        case "chat:tags":
            // Refresh conversation from server to get tags
            if let chatId = effectiveChatId {
                Task {
                    try? await refreshConversationMetadata(chatId: chatId, assistantMessageId: assistantMessageId)
                }
            }

        case "chat:message:follow_ups":
            // Follow-ups can arrive in various formats:
            // 1. { data: { follow_ups: [...] } }
            // 2. { data: { followUps: [...] } }
            // 3. { data: [...] } (direct array)
            var followUps: [String] = []
            if let payload {
                followUps = payload["follow_ups"] as? [String]
                    ?? payload["followUps"] as? [String]
                    ?? payload["suggestions"] as? [String] ?? []
            }
            // Try direct array format
            if followUps.isEmpty, let directArray = data["data"] as? [String] {
                followUps = directArray
            }
            if !followUps.isEmpty {
                let trimmed = followUps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !trimmed.isEmpty {
                    logger.info("Received \(trimmed.count) follow-ups")
                    appendFollowUps(id: assistantMessageId, followUps: trimmed)
                }
            }

        case "source", "citation":
            if let payload, let sources = parseSources([payload]) {
                appendSources(id: assistantMessageId, sources: sources)
            }

        case "notification":
            if let msg = payload?["content"] as? String { logger.info("Notification: \(msg)") }

        case "confirmation":
            ack?(true)

        // --- Events that should only work during active streaming ---

        default:
            guard !hasFinishedStreaming else { return }

            switch type {
            case "chat:completion":
                guard let payload else { break }
                handleChatCompletion(payload, assistantMessageId: assistantMessageId,
                                      modelId: modelId, socketSessionId: socketSessionId,
                                      effectiveChatId: effectiveChatId, acc: acc)

            case "chat:message:delta", "message", "event:message:delta":
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    acc.append(content)
                    updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                }

            case "chat:message", "replace":
                let content = payload?["content"] as? String ?? ""
                if !content.isEmpty {
                    acc.replace(content)
                    updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
                }

            case "status", "event:status":
                if let payload {
                    let su = parseStatusData(payload)
                    appendStatusUpdate(id: assistantMessageId, status: su)
                }

            case "chat:message:error":
                let errContent = extractErrorContent(from: payload ?? data)
                updateAssistantMessage(id: assistantMessageId, content: acc.content,
                                        isStreaming: false, error: ChatMessageError(content: errContent))
                cleanupStreaming()

            case "chat:tasks:cancel":
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
                cleanupStreaming()

            case "request:chat:completion":
                if let ch = payload?["channel"] as? String, !ch.isEmpty {
                    logger.info("Channel request: \(ch)")
                }

            case "execute:tool":
                if let name = payload?["name"] as? String, !name.isEmpty {
                    let su = ChatStatusUpdate(action: name, description: "Executing \(name)…", done: false)
                    appendStatusUpdate(id: assistantMessageId, status: su)
                }

            default:
                break
            }
        }
    }

    private func handleChatCompletion(
        _ payload: [String: Any],
        assistantMessageId: String, modelId: String,
        socketSessionId: String, effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        // OpenAI choices format
        if let choices = payload["choices"] as? [[String: Any]],
           let first = choices.first,
           let delta = first["delta"] as? [String: Any] {
            if let c = delta["content"] as? String, !c.isEmpty {
                acc.append(c)
                updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    if let fn = call["function"] as? [String: Any],
                       let name = fn["name"] as? String, !name.isEmpty {
                        appendStatusUpdate(id: assistantMessageId,
                            status: ChatStatusUpdate(action: name, description: "Calling \(name)…", done: false))
                    }
                }
            }
            if let status = delta["status"] as? [String: Any] {
                appendStatusUpdate(id: assistantMessageId, status: parseStatusData(status))
            }
            if let sourcesArray = delta["sources"] as? [[String: Any]],
               let sources = parseSources(sourcesArray) {
                appendSources(id: assistantMessageId, sources: sources)
            }
            if let citations = delta["citations"] as? [[String: Any]],
               let sources = parseSources(citations) {
                appendSources(id: assistantMessageId, sources: sources)
            }
        }

        // Direct content field
        if let content = payload["content"] as? String, !content.isEmpty {
            acc.replace(content)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }

        // Top-level tool_calls
        if let toolCalls = payload["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                if let fn = call["function"] as? [String: Any],
                   let name = fn["name"] as? String, !name.isEmpty {
                    appendStatusUpdate(id: assistantMessageId,
                        status: ChatStatusUpdate(action: name, description: "Calling \(name)…", done: false))
                }
            }
        }

        // Top-level sources
        if let rawSources = payload["sources"] as? [[String: Any]] ?? payload["citations"] as? [[String: Any]],
           let sources = parseSources(rawSources) {
            appendSources(id: assistantMessageId, sources: sources)
        }

        // Done signal
        if payload["done"] as? Bool == true {
            logger.info("Received done:true – finalizing streaming")
            finishStreamingSuccessfully(
                assistantMessageId: assistantMessageId,
                modelId: modelId,
                socketSessionId: socketSessionId,
                effectiveChatId: effectiveChatId,
                acc: acc
            )
        }

        // Error in completion payload
        if let err = payload["error"] as? String, !err.isEmpty {
            updateAssistantMessage(id: assistantMessageId, content: acc.content,
                                    isStreaming: false, error: ChatMessageError(content: err))
            cleanupStreaming()
        }
    }

    /// Handles channel events (secondary streaming channel).
    private func handleChannelEvent(
        _ event: [String: Any],
        assistantMessageId: String,
        acc: ContentAccumulator
    ) {
        guard !hasFinishedStreaming else { return }
        let data = event["data"] as? [String: Any] ?? event
        let type = data["type"] as? String
        let payload = data["data"] as? [String: Any]

        if type == "message", let content = payload?["content"] as? String, !content.isEmpty {
            acc.append(content)
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: true)
        }
    }

    // MARK: - Streaming Completion

    private func finishStreamingSuccessfully(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        acc: ContentAccumulator
    ) {
        // If content is empty, poll server for it
        if acc.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await pollAndFinish(
                    assistantMessageId: assistantMessageId,
                    modelId: modelId,
                    socketSessionId: socketSessionId,
                    effectiveChatId: effectiveChatId,
                    acc: acc
                )
            }
            return
        }

        // Finalize the message — mark as not streaming but DON'T dispose
        // socket subscriptions yet. Follow-ups, title, and tags arrive
        // AFTER done:true via socket events, so we need to keep listening.
        updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
        hasFinishedStreaming = true
        isStreaming = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDelayTask?.cancel()
        recoveryDelayTask = nil
        emptyPollCount = 0
        endBackgroundTask()

        // Capture the current subscriptions by value so the async Task below
        // disposes ONLY the subscriptions that belong to this streaming session.
        //
        // Without this capture, if the user sends a 2nd message before this
        // Task completes (which can take 10+ seconds due to file-poll sleeps),
        // the Task would dispose the NEW subscriptions created for the 2nd
        // message — killing live socket delivery mid-stream and causing all
        // text to appear at once at the end instead of token-by-token.
        let capturedChatSub = chatSubscription
        let capturedChannelSub = channelSubscription
        chatSubscription = nil
        channelSubscription = nil

        // Send chatCompleted, refresh metadata immediately for files/images,
        // then poll for tool-generated files before final cleanup.
        // Store as completionTask so it can be cancelled if user sends a new
        // message before it finishes (prevents content overwrite bug).
        completionTask = Task {
            // Send notification first before any metadata refresh
            await sendCompletionNotificationIfNeeded(content: acc.content)

            if let chatId = effectiveChatId {
                await manager?.sendChatCompleted(
                    chatId: chatId, messageId: assistantMessageId,
                    model: modelId, sessionId: socketSessionId,
                    messages: buildSimpleAPIMessages())

                // Immediately refresh metadata to pick up tool-generated files/images
                try? await refreshConversationMetadata(
                    chatId: chatId, assistantMessageId: assistantMessageId)

                // Check if files are still missing (tool outputs take time to process).
                // Poll with increasing delays specifically for files.
                let needsFilePoll = self.conversation?.messages
                    .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true
                if needsFilePoll {
                    for delay: UInt64 in [2, 3, 5] {
                        try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                        try? await refreshConversationMetadata(
                            chatId: chatId, assistantMessageId: assistantMessageId)
                        let hasFiles = !(self.conversation?.messages
                            .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true)
                        if hasFiles { break }
                    }

                    // Last resort: if server still hasn't provided files, extract
                    // file IDs directly from tool call results in the message content.
                    // This handles the case where the server metadata doesn't include
                    // files but the tool response clearly references generated images.
                    self.populateFilesFromToolResults(messageId: assistantMessageId)
                } else {
                    // Files already present — just wait for follow-ups/title
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    try? await refreshConversationMetadata(
                        chatId: chatId, assistantMessageId: assistantMessageId)
                }
            }
            // NOTE: Do NOT call saveConversationToServer() here.
            // The server already has the authoritative state after chatCompleted
            // processed tool results (web search, image gen). Saving our local
            // copy back would overwrite the server's clean format with raw
            // streamed content containing <details> blocks, causing the chat
            // to appear blank on the web client.

            // Dispose only the subscriptions captured at the start of THIS
            // completion handler — not the instance vars (which may already
            // belong to a newer streaming session).
            capturedChatSub?.dispose()
            capturedChannelSub?.dispose()

            // Notify the conversation list to refresh
            NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)

            // Generate a suggested emoji for the response (fire-and-forget)
            await self.generateSuggestedEmoji(for: acc.content)
        }
    }

    /// Generates a suggested emoji for the assistant's response via the server's
    /// emoji completions endpoint. Fire-and-forget — failure just means no emoji.
    private func generateSuggestedEmoji(for content: String) async {
        guard let apiClient = manager?.apiClient,
              let modelId = selectedModelId else { return }
        // Only generate if content is meaningful
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20 else { return }
        // Use first 200 chars as prompt to keep it fast
        let prompt = String(trimmed.prefix(200))
        do {
            if let emoji = try await apiClient.generateEmoji(model: modelId, prompt: prompt) {
                // Only accept single emoji or very short strings
                let cleaned = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.count <= 4 {
                    suggestedEmoji = cleaned
                }
            }
        } catch {
            // Non-critical — just skip the emoji suggestion
            logger.debug("Emoji generation failed: \(error.localizedDescription)")
        }
    }

    /// Polls the server for content when the done signal arrives with empty content.
    private func pollAndFinish(
        assistantMessageId: String,
        modelId: String,
        socketSessionId: String,
        effectiveChatId: String?,
        acc: ContentAccumulator
    ) async {
        guard let chatId = effectiveChatId, let manager else {
            updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)
            cleanupStreaming()
            return
        }

        // Poll up to 5 times with 1s delay
        for attempt in 1...5 {
            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                if let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }),
                   !lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    acc.replace(lastAssistant.content)
                    logger.info("Server poll \(attempt): got content (\(lastAssistant.content.count) chars)")
                    break
                }
            } catch {
                logger.warning("Poll attempt \(attempt) failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        updateAssistantMessage(id: assistantMessageId, content: acc.content, isStreaming: false)

        // Send background notification if app is not active
        await sendCompletionNotificationIfNeeded(content: acc.content)

        await manager.sendChatCompleted(
            chatId: chatId, messageId: assistantMessageId,
            model: modelId, sessionId: socketSessionId,
            messages: buildSimpleAPIMessages())

        // Refresh metadata to pick up tool-generated files/images.
        // Poll with retries since tool outputs may take time to process.
        for delay: UInt64 in [1, 2, 3] {
            try? await refreshConversationMetadata(
                chatId: chatId, assistantMessageId: assistantMessageId)
            let hasFiles = !(conversation?.messages
                .first(where: { $0.id == assistantMessageId })?.files.isEmpty ?? true)
            if hasFiles { break }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }

        // Last resort: extract file IDs from tool call results in content
        populateFilesFromToolResults(messageId: assistantMessageId)

        // NOTE: Do NOT call saveConversationToServer() here — same reason
        // as finishStreamingSuccessfully. The server's chatCompleted has the
        // authoritative state; pushing our local copy would corrupt tool results.
        cleanupStreaming()
    }

    // MARK: - Recovery Timer

    /// Starts a timer that polls the server periodically to recover from stuck streaming.
    ///
    /// The first poll is delayed by 8 seconds to give socket streaming time to
    /// begin. The previous 3-second initial fire competed with socket events for
    /// main actor time and sometimes caused the "all text at once" symptom by
    /// triggering a full conversation fetch right when tokens were starting to flow.
    private func startRecoveryTimer(assistantMessageId: String, chatId: String?) {
        recoveryTimer?.invalidate()
        recoveryDelayTask?.cancel()
        emptyPollCount = 0

        // Use a cancellable Task for the initial delay instead of
        // DispatchQueue.main.asyncAfter, which cannot be cancelled when
        // the user navigates away or sends a new message.
        recoveryDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.isStreaming, !self.hasFinishedStreaming else { return }

            self.recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.runRecoveryPoll(assistantMessageId: assistantMessageId, chatId: chatId)
                }
            }
            // Also run the first poll immediately after the delay
            self.runRecoveryPoll(assistantMessageId: assistantMessageId, chatId: chatId)
        }
    }

    /// Extracted recovery poll logic (called by the recovery timer).
    private func runRecoveryPoll(assistantMessageId: String, chatId: String?) {
        Task { @MainActor in
            guard self.isStreaming, !self.hasFinishedStreaming else {
                self.recoveryTimer?.invalidate()
                self.recoveryTimer = nil
                return
            }
            guard let chatId, let manager = self.manager else { return }

            do {
                let refreshed = try await manager.fetchConversation(id: chatId)
                if let lastAssistant = refreshed.messages.last(where: { $0.role == .assistant }) {
                    let serverContent = lastAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let localContent = self.conversation?.messages.last(where: { $0.role == .assistant })?.content
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    // Server has more content than local — but ONLY update
                    // if the socket has NOT been delivering tokens. If the
                    // socket is actively streaming, let it continue token-by-token
                    // rather than dumping the entire server content at once.
                    if !serverContent.isEmpty && serverContent.count > localContent.count && !self.socketHasReceivedContent {
                        self.logger.info("Recovery: adopting server content (socket silent)")
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: lastAssistant.content, isStreaming: true)
                    }

                    // Server says streaming is done
                    if !lastAssistant.isStreaming && !serverContent.isEmpty {
                        self.logger.info("Recovery: server says done with \(serverContent.count) chars")
                        self.updateAssistantMessage(
                            id: assistantMessageId, content: lastAssistant.content, isStreaming: false)
                        self.cleanupStreaming()
                        return
                    }
                }
            } catch {
                self.logger.warning("Recovery poll failed: \(error.localizedDescription)")
            }

            // Check if there are active (pending) tool statuses — if so, tools
            // are still executing on the server. Do NOT count these polls toward
            // the give-up threshold. The server will eventually finish or error;
            // the user can also cancel manually via the stop button.
            let hasActiveToolStatus: Bool = {
                guard let msgIdx = self.conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) else { return false }
                let statuses = self.conversation?.messages[msgIdx].statusHistory ?? []
                return statuses.contains { $0.done != true && $0.hidden != true }
            }()

            if hasActiveToolStatus {
                // Tools still running — reset the empty poll counter so we
                // never give up while the server is actively processing.
                self.emptyPollCount = 0
                self.logger.debug("Recovery: tools still active, resetting poll count")
            } else {
                self.emptyPollCount += 1
            }

            // After 60s (12 polls at 5s) with NO active tools, give up.
            // When tools ARE active, emptyPollCount stays at 0 so we wait
            // indefinitely until the server finishes or the user cancels.
            if self.emptyPollCount >= 12 {
                self.logger.warning("Recovery: giving up after \(self.emptyPollCount) polls (no active tools)")
                self.updateAssistantMessage(
                    id: assistantMessageId,
                    content: self.conversation?.messages.last(where: { $0.role == .assistant })?.content ?? "",
                    isStreaming: false)
                self.cleanupStreaming()
            }
        }
    }

    // MARK: - Cleanup

    /// Sends a local notification when generation completes.
    /// Always schedules the notification — the `UNUserNotificationCenterDelegate`
    /// controls presentation (banner vs silent) based on foreground state.
    private func sendCompletionNotificationIfNeeded(content: String) async {
        // Check if user has disabled generation notifications
        let notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard notificationsEnabled else { return }

        // Always schedule the notification. The UNUserNotificationCenterDelegate
        // (willPresent) handles foreground suppression — if the user is viewing
        // this conversation, it returns [] (no banner). This avoids stale
        // UIApplication.shared.connectedScenes state when called from background tasks.
        let chatId = conversationId ?? conversation?.id ?? ""
        let title = conversation?.title ?? "Chat"
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return }

        await NotificationService.shared.notifyGenerationComplete(
            conversationId: chatId,
            title: title,
            preview: preview
        )
    }

    private func cleanupStreaming() {
        guard !hasFinishedStreaming else { return }
        hasFinishedStreaming = true
        isStreaming = false
        isExternallyStreaming = false
        selfInitiatedStream = false
        activeTaskId = nil

        // CRITICAL: Flush the streaming store if it's still active.
        // Without this, background recovery paths (recoverFromBackgroundStreaming,
        // startBackgroundCompletionPolling) bypass updateAssistantMessage(isStreaming:false)
        // and go directly to adoptServerMessages → cleanupStreaming. The store's
        // isActive stays true, causing IsolatedAssistantMessage to remain stuck
        // in the fixed-height streaming container forever.
        if streamingStore.isActive, let msgId = streamingStore.streamingMessageId,
           let idx = conversation?.messages.firstIndex(where: { $0.id == msgId }) {
            let result = streamingStore.endStreaming()
            // Only overwrite content if the store has meaningful content
            // (adoptServerMessages may have already set the correct content)
            if !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               conversation?.messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                conversation?.messages[idx].content = result.content
            }
            conversation?.messages[idx].isStreaming = false
            if !result.sources.isEmpty && (conversation?.messages[idx].sources.isEmpty ?? true) {
                conversation?.messages[idx].sources = result.sources
            }
            if !result.statusHistory.isEmpty {
                conversation?.messages[idx].statusHistory = result.statusHistory
            }
        } else if streamingStore.isActive {
            // Store is active but message not found — just flush it
            streamingStore.endStreaming()
        }
        chatSubscription?.dispose()
        chatSubscription = nil
        channelSubscription?.dispose()
        channelSubscription = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        emptyPollCount = 0
        // or remove them if they never produced meaningful output
        if let lastIdx = conversation?.messages.lastIndex(where: { $0.role == .assistant }) {
            let statuses = conversation?.messages[lastIdx].statusHistory ?? []
            let hasContent = !(conversation?.messages[lastIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if hasContent {
                // Mark any incomplete statuses as done
                for (i, status) in statuses.enumerated() {
                    if status.done != true {
                        conversation?.messages[lastIdx].statusHistory[i].done = true
                    }
                }
            }

            // Remove statuses that are all incomplete and have no meaningful info
            // (they were just transient placeholders that never completed)
            let allIncomplete = statuses.allSatisfy { $0.done != true }
            if allIncomplete && !statuses.isEmpty {
                conversation?.messages[lastIdx].statusHistory = []
            }
        }
    }

    // MARK: - Private Helpers

    /// Timestamp of the last model metadata refresh. Used to throttle
    /// the per-send refresh so we don't add 100-500ms of network latency
    /// to every message when the models haven't changed.
    private var lastModelMetadataRefreshTime: Date = .distantPast

    /// Fetches full model config from `/api/v1/models/model?id={id}` for the selected model.
    ///
    /// This is the authoritative source for:
    /// - `params.function_calling` ("native" | absent) — which /api/models never returns
    /// - `meta.capabilities`, `meta.toolIds`, `meta.defaultFeatureIds`
    ///
    /// Called when a model is selected (selectModel) so the UI always reflects
    /// the server's actual config. Updates the model in `availableModels` and
    /// re-syncs UI defaults.
    private func refreshSelectedModelConfig() async {
        guard let modelId = selectedModelId, let manager else { return }
        do {
            if var fullModel = try await manager.apiClient.fetchModelConfig(modelId: modelId) {
                // Preserve pipe fields from the list endpoint — the single-model endpoint
                // (/api/v1/models/model) returns workspace-model schema which lacks
                // pipe/filters fields. Overwriting them would destroy isPipeModel=true,
                // filterIds, and the correct rawModelItem needed for pipe routing.
                if let existingModel = availableModels.first(where: { $0.id == modelId }) {
                    if existingModel.isPipeModel {
                        fullModel.isPipeModel = existingModel.isPipeModel
                        fullModel.filterIds = existingModel.filterIds
                    }
                    if existingModel.rawModelItem != nil {
                        fullModel.rawModelItem = existingModel.rawModelItem
                    }
                }
                if let idx = availableModels.firstIndex(where: { $0.id == modelId }) {
                    availableModels[idx] = fullModel
                } else {
                    availableModels.append(fullModel)
                }
                lastModelMetadataRefreshTime = Date()
                syncUIWithModelDefaults()
                logger.info("Model config loaded: \(modelId) function_calling=\(fullModel.functionCallingMode ?? "default") isPipe=\(fullModel.isPipeModel)")
            }
        } catch {
            logger.debug("Model config fetch failed for \(modelId): \(error.localizedDescription)")
        }
    }

    /// Refreshes the selected model's metadata (capabilities, defaultFeatureIds, toolIds)
    /// from the server. Called before each message send to pick up live admin changes
    /// without requiring the user to restart the chat.
    ///
    /// Throttled to at most once per 60 seconds to avoid adding unnecessary
    /// network latency to every send operation. Uses the single-model endpoint
    /// (/api/v1/models/model) which also returns params.function_calling.
    ///
    /// IMPORTANT: Uses `applyIncrementalModelDefaults` instead of `syncUIWithModelDefaults`
    /// to avoid wiping tools/features the user has manually toggled during the session.
    private func refreshSelectedModelMetadata() async {
        guard let modelId = selectedModelId, let manager else { return }
        // Skip if we refreshed recently (< 60s) — model admin changes are rare
        guard Date().timeIntervalSince(lastModelMetadataRefreshTime) > 60 else {
            return
        }
        do {
            if var fullModel = try await manager.apiClient.fetchModelConfig(modelId: modelId) {
                lastModelMetadataRefreshTime = Date()
                // Preserve pipe fields from the list endpoint — the single-model endpoint
                // (/api/v1/models/model) returns workspace-model schema which lacks
                // pipe/filters fields. Overwriting them would destroy isPipeModel=true,
                // filterIds, and the correct rawModelItem needed for pipe routing.
                if let existingModel = availableModels.first(where: { $0.id == modelId }) {
                    if existingModel.isPipeModel {
                        fullModel.isPipeModel = existingModel.isPipeModel
                        fullModel.filterIds = existingModel.filterIds
                    }
                    if existingModel.rawModelItem != nil {
                        fullModel.rawModelItem = existingModel.rawModelItem
                    }
                }
                if let idx = availableModels.firstIndex(where: { $0.id == modelId }) {
                    availableModels[idx] = fullModel
                }
                // Use incremental sync — only ADD new defaults; never wipe user selections.
                // syncUIWithModelDefaults() resets selectedToolIds = [] which would discard
                // any tools the user manually enabled this session.
                applyIncrementalModelDefaults(for: fullModel)
            }
        } catch {
            // Non-critical — proceed with cached model data
            logger.debug("Model metadata refresh failed: \(error.localizedDescription)")
        }
    }

    /// Incrementally applies server-side model defaults to the current session
    /// **without** clearing existing user selections.
    ///
    /// Unlike `syncUIWithModelDefaults()` (which is a full reset intended for
    /// model switches and new conversations), this method only ADDS newly-discovered
    /// defaults. It respects `userDisabledToolIds` so tools the user explicitly
    /// toggled off stay off, and it never removes tools/features the user turned on.
    ///
    /// Called by `refreshSelectedModelMetadata()` before each message send.
    private func applyIncrementalModelDefaults(for model: AIModel) {
        let defaults = model.defaultFeatureIds
        let caps = model.capabilities ?? [:]

        func isTruthy(_ key: String) -> Bool {
            guard let value = caps[key] else { return false }
            return ["1", "true"].contains(value.lowercased())
        }

        // Only enable features if admin has them on — never force-disable ones
        // the user turned on manually.
        if defaults.contains("web_search") && isTruthy("web_search") {
            webSearchEnabled = true
        }
        if defaults.contains("image_generation") && isTruthy("image_generation") {
            imageGenerationEnabled = true
        }
        if defaults.contains("code_interpreter") && isTruthy("code_interpreter") {
            codeInterpreterEnabled = true
        }

        // Add model-assigned tools (admin attached to this model) that aren't
        // user-disabled and aren't already selected.
        for toolId in model.toolIds {
            if !userDisabledToolIds.contains(toolId) {
                selectedToolIds.insert(toolId)
            }
        }

        // Add any globally-enabled tools (is_active) that aren't user-disabled.
        for tool in availableTools where tool.isEnabled {
            if !userDisabledToolIds.contains(tool.id) {
                selectedToolIds.insert(tool.id)
            }
        }
    }

    /// Whether the selected model supports the memory builtin tool.
    /// Controls visibility of the memory toggle in ToolsMenuSheet.
    var isMemoryAvailable: Bool {
        selectedModel?.supportsMemory ?? false
    }

    /// Syncs the UI toggles (web search pill, selected tools) with the selected
    /// model's server-configured defaults. Matches the OpenWebUI web client's
    /// `setDefaults()` which pre-enables features and tools from model metadata.
    ///
    /// Called on:
    /// - Initial model load (`loadModels`)
    /// - Model switch (`selectModel`)
    /// - New conversation (`startNewConversation`)
    private func syncUIWithModelDefaults() {
        guard let model = selectedModel else { return }
        let defaults = model.defaultFeatureIds
        let caps = model.capabilities ?? [:]

        func isTruthy(_ key: String) -> Bool {
            guard let value = caps[key] else { return false }
            return ["1", "true"].contains(value.lowercased())
        }

        // Reset all feature toggles to match THIS model's config.
        // Each toggle is set to true only if the model has it as a
        // default AND the capability is enabled. This ensures switching
        // models correctly reflects per-model feature availability.
        webSearchEnabled = defaults.contains("web_search") && isTruthy("web_search")
        imageGenerationEnabled = defaults.contains("image_generation") && isTruthy("image_generation")
        codeInterpreterEnabled = defaults.contains("code_interpreter") && isTruthy("code_interpreter")

        // Memory is an account-level preference stored server-side (ui.memory).
        // Fetch it once for all models (not just memory-capable ones) so the
        // value is cached for when a capable model is selected later.
        Task { await fetchMemorySettingFromServer() }

        // Reset and re-populate tool selections for this model.
        // Clear first so tools from a previous model don't persist.
        selectedToolIds = []
        if !model.toolIds.isEmpty {
            for toolId in model.toolIds {
                selectedToolIds.insert(toolId)
            }
        }
        // Also re-add globally-enabled tools (server admin marked as active)
        for tool in availableTools where tool.isEnabled {
            selectedToolIds.insert(tool.id)
        }
    }

    /// Fetches the user's memory preference from the server.
    ///
    /// Calls `GET /api/v1/users/user/settings` and reads `ui.memory`.
    /// This is the same endpoint the web UI writes to when the user
    /// toggles memory in Settings → Personalization. Fire-and-forget
    /// — failure just leaves `memoryEnabled` at its last known value.
    func fetchMemorySettingFromServer() async {
        // Use session-level cache — avoids a redundant GET /api/v1/users/user/settings
        // on every model load/switch. Cache is cleared by ActiveChatStore.clear()
        // on logout or server switch, ensuring a fresh fetch each session.
        if let cached = activeChatStore?.cachedMemorySetting {
            memoryEnabled = cached
            logger.debug("Memory setting from cache: \(cached)")
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let settings = try await apiClient.getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let memory = ui["memory"] as? Bool {
                memoryEnabled = memory
                activeChatStore?.cachedMemorySetting = memory
                logger.debug("Memory setting fetched from server: \(memory)")
            }
        } catch {
            logger.debug("Failed to fetch memory setting: \(error.localizedDescription)")
        }
    }

    /// Persists the memory toggle state to the server user settings.
    ///
    /// Calls `POST /api/v1/users/user/settings/update` with `{"ui":{"memory":enabled}}`
    /// so the web UI and app stay in sync. Fire-and-forget — the toggle
    /// is already updated locally.
    func updateMemorySettingOnServer(enabled: Bool) {
        guard let apiClient = manager?.apiClient else { return }
        Task {
            do {
                try await apiClient.updateUserSettings(["ui": ["memory": enabled]])
                logger.debug("Memory setting saved to server: \(enabled)")
            } catch {
                logger.debug("Failed to save memory setting: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Pinned Models

    /// Fetches the user's pinned model IDs from the server.
    ///
    /// Reads `ui.pinnedModels` from `GET /api/v1/users/user/settings`.
    /// Uses session-level cache to avoid redundant fetches.
    func fetchPinnedModels() async {
        // Use session-level cache
        if let cached = activeChatStore?.cachedPinnedModelIds {
            pinnedModelIds = cached
            return
        }
        guard let apiClient = manager?.apiClient else { return }
        do {
            let settings = try await apiClient.getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let pinned = ui["pinnedModels"] as? [String] {
                pinnedModelIds = pinned
                activeChatStore?.cachedPinnedModelIds = pinned
                logger.debug("Pinned models fetched: \(pinned)")
            }
        } catch {
            logger.debug("Failed to fetch pinned models: \(error.localizedDescription)")
        }
    }

    /// Toggles a model's pinned state and syncs to the server.
    ///
    /// Calls `POST /api/v1/users/user/settings/update` with
    /// `{"ui": {"models": [...], "pinnedModels": [...]}}` matching the web UI format.
    func togglePinModel(_ modelId: String) {
        if pinnedModelIds.contains(modelId) {
            pinnedModelIds.removeAll { $0 == modelId }
        } else {
            pinnedModelIds.append(modelId)
        }
        // Update cache immediately
        activeChatStore?.cachedPinnedModelIds = pinnedModelIds

        // Sync to server (fire-and-forget)
        let currentPinned = pinnedModelIds
        guard let apiClient = manager?.apiClient else { return }
        Task {
            do {
                try await apiClient.updateUserSettings([
                    "ui": [
                        "models": currentPinned,
                        "pinnedModels": currentPinned
                    ]
                ])
                logger.debug("Pinned models saved to server: \(currentPinned)")
            } catch {
                logger.debug("Failed to save pinned models: \(error.localizedDescription)")
            }
        }
    }

    /// Builds chat features by merging user toggles with the model's admin-configured
    /// default features. Matches the OpenWebUI web client's `setDefaults()` + `getFeatures()`.
    ///
    /// Memory is based solely on the user's account setting (`memoryEnabled`), matching
    /// the web client which sends `features.memory` based on `$user.settings.ui.memory`
    /// without gating on per-model `builtinTools`. The server already knows which models
    /// support memory and ignores the flag for models that don't.
    private func buildChatFeatures() -> ChatCompletionRequest.ChatFeatures {
        var features = ChatCompletionRequest.ChatFeatures()

        // Use ONLY the current toggle state. Server defaults are already applied
        // to these toggles at init time via syncUIWithModelDefaults() — which runs
        // on model load, model switch, and new-conversation. By the time we build
        // the request, the toggle reflects either the server default OR the user's
        // explicit override. Checking server defaults again here would ignore the
        // user toggling a feature OFF mid-chat (the original bug).
        if webSearchEnabled {
            features.webSearch = true
        }
        if imageGenerationEnabled {
            features.imageGeneration = true
        }
        if codeInterpreterEnabled {
            features.codeInterpreter = true
        }
        // Memory: send based on account-level setting only (matches web client).
        // No gate on selectedModel?.supportsMemory — the server decides per-model
        // whether to inject the memory tool; we just relay the user's preference.
        if memoryEnabled {
            features.memory = true
        }

        return features
    }

    /// Builds API messages array, fetching image base64 from server for vision.
    /// Matches Flutter's `_buildMessagePayloadWithAttachments` which calls
    /// `api.getFileContent(fileId)` to get base64 data URLs for the LLM.
    /// Builds a lightweight `[{role, content}]` message array from the current
    /// conversation without fetching image data from the server.
    /// Used for `/api/chat/completed` so filter outlets receive the full
    /// conversation history and can run their post-processing logic.
    private func buildSimpleAPIMessages() -> [[String: Any]] {
        guard let conversation else { return [] }
        var msgs: [[String: Any]] = []
        if let sp = conversation.systemPrompt, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            msgs.append(["role": "system", "content": sp])
        }
        for msg in conversation.messages where !msg.isStreaming {
            msgs.append(["role": msg.role.rawValue, "content": msg.content])
        }
        return msgs
    }

    private func buildAPIMessagesAsync() async -> [[String: Any]] {
        guard let conversation else { return [] }
        var apiMessages: [[String: Any]] = []
        if let sp = conversation.systemPrompt, !sp.trimmingCharacters(in: .whitespaces).isEmpty {
            apiMessages.append(["role": "system", "content": sp])
        }
        for message in conversation.messages where !message.isStreaming {
            let imageFiles = message.files.filter { f in
                f.type == "image" || (f.contentType ?? "").hasPrefix("image/")
            }
            let nonImageFiles = message.files.filter { f in
                f.type != "image" && !(f.contentType ?? "").hasPrefix("image/")
            }

            if !imageFiles.isEmpty && message.role == .user {
                // Build multimodal content array (OpenAI vision format)
                // Fetch image base64 from server, matching Flutter behavior
                var contentArray: [[String: Any]] = []
                if !message.content.isEmpty {
                    contentArray.append(["type": "text", "text": message.content])
                }
                for imgFile in imageFiles {
                    if let fileId = imgFile.url, !fileId.isEmpty {
                        if fileId.hasPrefix("data:image/") {
                            // Already a data URL
                            contentArray.append([
                                "type": "image_url",
                                "image_url": ["url": fileId]
                            ])
                        } else {
                            // Fetch from server, downsample to ≤ 2 MP, then base64-encode.
                            // The server stores the original full-resolution file; without
                            // downsampling here, the base64 payload easily exceeds the
                            // vision API's 5 MB per-image limit.
                            if let apiClient = manager?.apiClient {
                                do {
                                    let (rawData, contentType) = try await apiClient.getFileContent(id: fileId)
                                    let data = FileAttachmentService.downsampleForUpload(data: rawData)
                                    let base64 = data.base64EncodedString()
                                    let mimeType = contentType.hasPrefix("image/") ? contentType : "image/jpeg"
                                    let dataUrl = "data:\(mimeType);base64,\(base64)"
                                    contentArray.append([
                                        "type": "image_url",
                                        "image_url": ["url": dataUrl]
                                    ])
                                } catch {
                                    logger.warning("Failed to fetch image content for \(fileId): \(error)")
                                    // Fallback: send file ID, server may resolve it
                                    contentArray.append([
                                        "type": "image_url",
                                        "image_url": ["url": fileId]
                                    ])
                                }
                            }
                        }
                    }
                }

                var msgDict: [String: Any] = [
                    "role": message.role.rawValue,
                    "content": contentArray
                ]

                if !nonImageFiles.isEmpty {
                    msgDict["files"] = nonImageFiles.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        return ["type": "file", "id": id, "url": id]
                    }
                }

                apiMessages.append(msgDict)
            } else {
                var msgDict: [String: Any] = [
                    "role": message.role.rawValue,
                    "content": message.content
                ]

                if !message.files.isEmpty {
                    msgDict["files"] = message.files.compactMap { f -> [String: Any]? in
                        guard let id = f.url else { return nil }
                        return ["type": f.type ?? "file", "id": id, "url": id]
                    }
                } else if !message.attachmentIds.isEmpty {
                    msgDict["files"] = message.attachmentIds.map { id -> [String: Any] in
                        ["type": "file", "id": id, "url": id]
                    }
                }

                apiMessages.append(msgDict)
            }
        }
        return apiMessages
    }

    private func parseStatusData(_ data: [String: Any]) -> ChatStatusUpdate {
        // Parse queries from various formats (array of strings, or single string)
        var queries: [String] = []
        if let qArray = data["queries"] as? [String] {
            queries = qArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else if let qStr = data["queries"] as? String, !qStr.isEmpty {
            queries = [qStr]
        }

        return ChatStatusUpdate(
            action: data["action"] as? String,
            description: data["description"] as? String,
            done: data["done"] as? Bool,
            hidden: data["hidden"] as? Bool,
            urls: (data["urls"] as? [String]) ?? [],
            occurredAt: .now,
            count: data["count"] as? Int ?? (data["count"] as? Double).map { Int($0) },
            query: data["query"] as? String,
            queries: queries
        )
    }

    /// Parses OpenWebUI source payloads into ChatSourceReference objects.
    /// Matches the Flutter `parseOpenWebUISourceList` logic which handles
    /// nested `source`, `document`, `metadata`, `distances` arrays.
    ///
    /// OpenWebUI sends sources as:
    /// ```json
    /// [{ "source": {...}, "document": ["...","..."],
    ///    "metadata": [{"source":"url1","name":"..."}, {"source":"url2",...}],
    ///    "distances": [0.5, 0.7] }]
    /// ```
    /// Each metadata item = one unique source reference. The Flutter parser
    /// groups by metadata.source key and creates one ChatSourceReference per
    /// unique URL.
    private func parseSources(_ array: [[String: Any]]) -> [ChatSourceReference]? {
        // Accumulate by unique key (URL or fallback index)
        var accumulated: [(key: String, url: String?, title: String?, snippet: String?, type: String?, meta: [String: String])] = []
        var seenKeys = Set<String>()
        var fallbackIdx = 0

        for entry in array {
            // Extract nested source object
            var baseSource = (entry["source"] as? [String: Any]) ?? [:]
            for key in ["id", "name", "title", "url", "link", "type"] {
                if let value = entry[key], baseSource[key] == nil {
                    baseSource[key] = value
                }
            }

            let documents = (entry["document"] as? [Any]) ?? []
            let metadataRaw = entry["metadata"]
            let metadataList: [[String: Any]]
            if let list = metadataRaw as? [[String: Any]] {
                metadataList = list
            } else if let single = metadataRaw as? [String: Any] {
                metadataList = [single]
            } else {
                metadataList = []
            }

            // Determine iteration count — max of documents, metadata, distances
            let loopCount = max(1, max(documents.count, metadataList.count))

            for i in 0..<loopCount {
                let meta = i < metadataList.count ? metadataList[i] : [:]
                let document = i < documents.count ? documents[i] : nil

                // Resolve unique key for this source (usually the URL)
                let idCandidate: String? = {
                    for k in ["source", "id"] {
                        if let v = meta[k] as? String, !v.isEmpty { return v }
                    }
                    if let v = baseSource["id"] as? String, !v.isEmpty { return v }
                    return nil
                }()

                let key = idCandidate ?? "__fallback_\(fallbackIdx)"
                if idCandidate == nil { fallbackIdx += 1 }

                // Skip duplicates with the same key
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)

                // Resolve URL
                let url: String? = {
                    for k in ["source", "url", "link"] {
                        if let v = meta[k] as? String, v.hasPrefix("http") { return v }
                    }
                    if let v = baseSource["url"] as? String, v.hasPrefix("http") { return v }
                    if let id = idCandidate, id.hasPrefix("http") { return id }
                    return nil
                }()

                // Resolve title
                let title: String? = {
                    if let n = meta["name"] as? String, !n.isEmpty { return n }
                    if let t = meta["title"] as? String, !t.isEmpty { return t }
                    if let n = baseSource["name"] as? String, !n.isEmpty { return n }
                    if let t = baseSource["title"] as? String, !t.isEmpty { return t }
                    if let id = idCandidate, !id.isEmpty { return id }
                    return nil
                }()

                // Extract snippet from document
                let snippet: String? = {
                    if let doc = document {
                        if let s = doc as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                            return String(s.trimmingCharacters(in: .whitespaces).prefix(200))
                        }
                    }
                    return nil
                }()

                let type = (baseSource["type"] as? String) ?? (meta["type"] as? String)

                // Build metadata dict
                var metaDict: [String: String] = [:]
                for (k, v) in meta {
                    if let s = v as? String { metaDict[k] = s }
                }

                accumulated.append((
                    key: key,
                    url: url,
                    title: title,
                    snippet: snippet,
                    type: type,
                    meta: metaDict
                ))
            }
        }

        let results = accumulated.map { item in
            ChatSourceReference(
                id: item.key.hasPrefix("__fallback_") ? nil : item.key,
                title: item.title,
                url: item.url,
                snippet: item.snippet,
                type: item.type,
                metadata: item.meta.isEmpty ? nil : item.meta
            )
        }

        return results.isEmpty ? nil : results
    }

    private func extractErrorContent(from data: [String: Any]) -> String {
        // Try multiple error formats used by OpenWebUI/LiteLLM
        if let err = data["error"] {
            if let errMap = err as? [String: Any] {
                if let content = errMap["content"] as? String, !content.isEmpty { return content }
                if let message = errMap["message"] as? String, !message.isEmpty { return message }
            }
            if let errStr = err as? String, !errStr.isEmpty { return errStr }
        }
        if let msg = data["message"] as? String, !msg.isEmpty { return msg }
        if let detail = data["detail"] as? String, !detail.isEmpty { return detail }
        // Try to extract from nested content
        if let content = data["content"] as? String, !content.isEmpty { return content }
        // Last resort: serialize entire payload for debugging
        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8), !jsonStr.isEmpty {
            return jsonStr
        }
        return "An unexpected error occurred"
    }

    private func updateAssistantMessage(
        id: String, content: String, isStreaming: Bool,
        sources: [ChatSourceReference]? = nil,
        statusHistory: [ChatStatusUpdate]? = nil,
        error: ChatMessageError? = nil
    ) {
        if isStreaming && streamingStore.streamingMessageId == id {
            // ── STREAMING PATH ──
            // Route content to the isolated StreamingContentStore.
            // This avoids mutating conversation.messages on every token,
            // which would invalidate ALL message views via @Observable.
            streamingStore.updateContent(content)
            if let sources { streamingStore.appendSources(sources) }
            if let statusHistory {
                for s in statusHistory { streamingStore.appendStatus(s) }
            }
            if let error { streamingStore.setError(error) }
        } else {
            // ── COMPLETION / ERROR PATH ──
            // Write final content back to conversation.messages ONCE.
            // If transitioning from streaming → done, also flush the store.
            guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }

            if !isStreaming && streamingStore.streamingMessageId == id {
                // Streaming just ended — flush store to conversation
                let result = streamingStore.endStreaming()
                let finalContent = content.isEmpty ? result.content : content
                conversation?.messages[index].content = finalContent
                conversation?.messages[index].isStreaming = false
                // Merge sources from store into message
                if !result.sources.isEmpty {
                    for source in result.sources {
                        if !conversation!.messages[index].sources.contains(where: {
                            ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
                        }) {
                            conversation?.messages[index].sources.append(source)
                        }
                    }
                }
                // Merge status history
                if !result.statusHistory.isEmpty {
                    conversation?.messages[index].statusHistory = result.statusHistory
                }
                if let storeError = result.error {
                    conversation?.messages[index].error = storeError
                }
            } else {
                // Normal non-streaming update (e.g., error before streaming started)
                conversation?.messages[index].content = content
                conversation?.messages[index].isStreaming = isStreaming
            }
            if let sources { conversation?.messages[index].sources = sources }
            if let statusHistory { conversation?.messages[index].statusHistory = statusHistory }
            if let error { conversation?.messages[index].error = error }
        }

        // Trigger streaming haptic feedback (throttled to ~10 Hz to avoid
        // overwhelming the Taptic Engine while still feeling responsive)
        if isStreaming && error == nil {
            triggerStreamingHaptic()
        }
    }

    /// Fires a subtle haptic pulse during token streaming, throttled via
    /// the centralized `Haptics` service to avoid excessive motor usage.
    /// Reads the preference live so toggling in Settings takes effect immediately.
    /// The read only happens at ~3 Hz (throttled inside `streamingTick`) so the
    /// UserDefaults overhead is negligible.
    private func triggerStreamingHaptic() {
        let enabled = UserDefaults.standard.object(forKey: "streamingHaptics") as? Bool ?? true
        guard enabled else { return }
        Haptics.streamingTick()
    }

    private func appendStatusUpdate(id: String, status: ChatStatusUpdate) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }

        // Deduplicate: update existing in-progress status with same action
        if let existingIdx = conversation?.messages[index].statusHistory.firstIndex(
            where: { $0.action == status.action && $0.done != true }
        ) {
            conversation?.messages[index].statusHistory[existingIdx] = status
        } else {
            // Don't add duplicate done statuses with the same action
            let isDuplicate = conversation?.messages[index].statusHistory.contains(where: {
                $0.action == status.action && $0.done == true && status.done == true
            }) ?? false
            if !isDuplicate {
                conversation?.messages[index].statusHistory.append(status)
            }
        }

        // Also write to the streaming store so the isolated streaming status
        // view sees the update in real-time (it reads from streamingStore,
        // not conversation.messages, during active streaming).
        if streamingStore.streamingMessageId == id && streamingStore.isActive {
            streamingStore.appendStatus(status)
        }
    }

    private func appendFollowUps(id: String, followUps: [String]) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        // Use direct in-place mutation. The @Observable macro on ChatViewModel
        // tracks mutations to `conversation` itself — mutating through the
        // optional chain works because `conversation` is a var on an @Observable
        // class. Avoid full `conversation = conv` reassignment which can cause
        // "setting value during update" crashes if a navigation event (e.g.,
        // new chat) fires concurrently.
        conversation?.messages[index].followUps = followUps
    }

    /// Refreshes conversation metadata (title, sources, follow-ups, files) from server.
    private func refreshConversationMetadata(chatId: String, assistantMessageId: String) async throws {
        guard let manager else { return }
        let refreshed = try await manager.fetchConversation(id: chatId)

        // Update title
        if !refreshed.title.isEmpty && refreshed.title != "New Chat" {
            conversation?.title = refreshed.title
        }

        // Update sources, follow-ups, and files from refreshed assistant message.
        // Match by EXACT message ID only — do NOT fall back to last assistant.
        // The fallback previously caused the "duplicate stream" bug: when the
        // first message's completion task was still running its delayed polls
        // while the second message was streaming, the fallback would pick up
        // the second message's content and write it into the first message.
        let serverAssistant = refreshed.messages.first(where: { $0.id == assistantMessageId })
        if let serverAssistant {
            if !serverAssistant.sources.isEmpty {
                appendSources(id: assistantMessageId, sources: serverAssistant.sources)
            }
            if !serverAssistant.followUps.isEmpty {
                appendFollowUps(id: assistantMessageId, followUps: serverAssistant.followUps)
            }
            // Copy files from server (tool-generated images etc.)
            if !serverAssistant.files.isEmpty {
                if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                    conversation?.messages[index].files = serverAssistant.files
                }
            }
            // Also update content if server has more (e.g., tool appended text)
            if let index = conversation?.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                let localContent = conversation?.messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let serverContent = serverAssistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !serverContent.isEmpty && serverContent.count > localContent.count {
                    conversation?.messages[index].content = serverAssistant.content
                }
                // Copy usage stats from server — the server stores them after
                // sendChatCompleted processes the chat. This is how app-sent
                // messages pick up usage data (the /api/chat/completed endpoint
                // doesn't return usage directly, but the stored message has it).
                if conversation?.messages[index].usage == nil,
                   let serverUsage = serverAssistant.usage, !serverUsage.isEmpty {
                    conversation?.messages[index].usage = serverUsage
                }
                // Copy embeds from server — never overwrite non-empty embeds
                if conversation?.messages[index].embeds.isEmpty == true,
                   !serverAssistant.embeds.isEmpty {
                    conversation?.messages[index].embeds = serverAssistant.embeds
                }
            }
        }
    }

    /// Ensures the assistant message has its file references populated.
    ///
    /// This is a safety net for when the server's `files` array is empty but
    /// the message content contains tool call results with file references
    /// (e.g., image generation tool returned a file ID). This can happen when:
    /// - The app was backgrounded during generation and missed socket events
    /// - Network issues prevented the server metadata refresh from completing
    /// - The server hasn't yet populated the files array on its side
    ///
    /// Uses `ToolCallParser.extractFileReferences` to scan the `<details>` blocks
    /// in the message content for file IDs, then adds them to `message.files`.
    private func populateFilesFromToolResults(messageId: String) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let message = conversation!.messages[index]

        // Only run if files array is empty — don't override server-provided files
        guard message.files.isEmpty else { return }

        // Only check assistant messages with content (tool results are embedded in content)
        guard message.role == .assistant,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let extractedFiles = ToolCallParser.extractFileReferences(from: message.content)
        if !extractedFiles.isEmpty {
            logger.info("Extracted \(extractedFiles.count) file(s) from tool results for message \(messageId)")
            conversation?.messages[index].files = extractedFiles
        }
    }

    private func appendSources(id: String, sources: [ChatSourceReference]) {
        guard let index = conversation?.messages.firstIndex(where: { $0.id == id }) else { return }
        for source in sources {
            if !conversation!.messages[index].sources.contains(where: {
                ($0.url != nil && $0.url == source.url) || ($0.id != nil && $0.id == source.id)
            }) {
                conversation?.messages[index].sources.append(source)
            }
        }
    }

    private func saveConversationToServer() async {
        guard let manager, let conversation else { return }
        // Skip server persistence for temporary chats
        guard !isTemporaryChat else { return }
        // Always sync messages to existing conversation — never create a new one.
        // The conversation is already created in sendMessage() when conversation == nil.
        // Calling createConversation again would produce a duplicate entry.
        do {
            try await manager.saveConversation(conversation)
        } catch {
            logger.error("Failed to save conversation: \(error.localizedDescription)")
        }

        // Notify history to refresh
        NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
    }
}

// MARK: - Content Accumulator

/// Thread-safe token accumulator with coalesced main-actor dispatch.
///
/// Uses a pending-flag + time-floor strategy to batch rapid token arrivals
/// into ~30fps UI updates, rather than creating a new Task per token.
final class ContentAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _content: String = ""
    private nonisolated(unsafe) var _onUpdate: (@MainActor @Sendable (_ content: String) -> Void)?
    /// Guards against flooding the main actor with redundant Tasks.
    /// When true, a Task is already queued and will read the latest content
    /// when it executes — no need to create another one.
    private nonisolated(unsafe) var _pendingUpdate: Bool = false

    /// OPT 5: Timestamp of the last dispatch. Enforces a minimum interval
    /// between MainActor dispatches to prevent rapid-fire updates when
    /// the system has low scheduling latency.
    private nonisolated(unsafe) var _lastDispatchTime: CFAbsoluteTime = 0

    /// Minimum interval between dispatches. 33ms ≈ 30fps max dispatch rate.
    /// Downstream StreamingMarkdownView throttles rendering further to ~15fps,
    /// so this just prevents unnecessary SwiftUI state mutations and view
    /// invalidations between those renders while ensuring tokens arrive
    /// fast enough for smooth typing feel.
    nonisolated private static let minDispatchInterval: CFAbsoluteTime = 0.033

    /// Callback invoked on the main actor with the latest accumulated
    /// content.  Set by the view model when socket handlers are registered.
    nonisolated var onUpdate: (@MainActor @Sendable (_ content: String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onUpdate
        }
        set {
            lock.lock()
            _onUpdate = newValue
            lock.unlock()
        }
    }

    nonisolated var content: String {
        lock.lock()
        let value = _content
        lock.unlock()
        return value
    }

    /// Clears the pending update flag and records dispatch time.
    /// Extracted into a synchronous nonisolated method so NSLock is never
    /// called from an async context (which triggers Swift 6 warnings).
    nonisolated private func clearPendingFlag() {
        lock.lock()
        _pendingUpdate = false
        _lastDispatchTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    nonisolated func append(_ text: String) {
        lock.lock()
        _content += text
        // OPT 5: Only dispatch if no pending update AND enough time has
        // elapsed since the last dispatch. This prevents rapid-fire updates
        // when MainActor scheduling latency is very low (e.g., idle UI).
        let now = CFAbsoluteTimeGetCurrent()
        let needsDispatch = !_pendingUpdate
            && (now - _lastDispatchTime >= Self.minDispatchInterval)
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        if needsDispatch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Read the LATEST content (tokens may have accumulated while
                // this Task waited for MainActor scheduling)
                let latest = self.content
                callback?(latest)

                // Clear the pending flag so the next append can dispatch.
                // Uses a synchronous helper to avoid NSLock in async context.
                self.clearPendingFlag()
            }
        }
    }

    nonisolated func replace(_ text: String) {
        lock.lock()
        _content = text
        let needsDispatch = !_pendingUpdate
        if needsDispatch { _pendingUpdate = true }
        let callback = _onUpdate
        lock.unlock()

        if needsDispatch {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let latest = self.content
                callback?(latest)

                self.clearPendingFlag()
            }
        }
    }
}
