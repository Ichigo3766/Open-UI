import Foundation
import UIKit
import SwiftUI

/// Protocol defining all app-level service dependencies.
///
/// Note: `Sendable` conformance was removed because the concrete
/// `AppDependencyContainer` is `@Observable` (implicitly MainActor-bound)
/// and holds mutable state that cannot be safely sent across actors.
protocol ServiceContainer {
    var serverConfigStore: ServerConfigStore { get }
}

// MARK: - Active Chat Store

/// Stores active ``ChatViewModel`` instances so they survive navigation
/// transitions.  When a user leaves a chat that is still streaming,
/// the view model persists here and continues processing.
@MainActor @Observable
final class ActiveChatStore {
    /// Cached view models keyed by conversation ID (or `__new__` for new chats).
    /// @ObservationIgnored because this is internal storage — SwiftUI views
    /// don't directly observe this dictionary; they observe the returned VMs.
    /// Without this, inserting a new VM during body evaluation triggers an
    /// AttributeGraph cycle (mutation during render → re-render → mutation…).
    @ObservationIgnored private var viewModels: [String: ChatViewModel] = [:]

    /// Max cached VMs to prevent unbounded memory growth. Each VM holds a full Conversation.
    private let maxCachedViewModels = 5

    /// Access order tracking for LRU eviction.
    /// Marked @ObservationIgnored because this is internal bookkeeping —
    /// mutating it during viewModel(for:) must NOT trigger SwiftUI re-renders
    /// or it causes an AttributeGraph cycle (mutation during body evaluation).
    @ObservationIgnored private var accessOrder: [String] = []

    // MARK: - Shared Model/Tools Cache

    /// Shared model list so new VMs don't need a network fetch.
    /// Updated by the first VM that loads models.
    var cachedModels: [AIModel] = []

    /// The last-selected model ID, carried forward to new chats.
    var cachedSelectedModelId: String?

    /// Server task config shared with all ChatViewModels.
    /// Updated by AppDependencyContainer.fetchTaskConfig().
    var serverTaskConfig: TaskConfig = .default

    /// Session-level cache for the user's memory setting (`ui.memory`).
    /// Populated by the first ChatViewModel that fetches it, then reused by
    /// all subsequent VMs so `GET /api/v1/users/user/settings` is called at
    /// most once per session (rather than on every model load/switch).
    /// Cleared by `clear()` on logout or server switch so the next session
    /// always fetches a fresh value.
    var cachedMemorySetting: Bool? = nil

    /// Session-level cache for pinned model IDs from `ui.pinnedModels`.
    /// Populated by the first ChatViewModel that fetches user settings,
    /// then reused by all subsequent VMs. Cleared on logout/server switch.
    var cachedPinnedModelIds: [String]? = nil

    /// Returns an existing view model or creates a new one for the given
    /// conversation ID.  Pass `nil` for a brand-new conversation.
    ///
    /// New VMs are pre-populated with `cachedModels` and `cachedSelectedModelId`
    /// so the model selector is instant — no network fetch needed.
    func viewModel(for conversationId: String?) -> ChatViewModel {
        let key = conversationId ?? "__new__"
        if let existing = viewModels[key] {
            accessOrder.removeAll { $0 == key }
            accessOrder.append(key)
            return existing
        }
        let vm: ChatViewModel
        if let conversationId {
            vm = ChatViewModel(conversationId: conversationId)
        } else {
            vm = ChatViewModel()
        }
        // Pre-populate from shared cache so UI is instant
        if !cachedModels.isEmpty {
            vm.availableModels = cachedModels
            vm.selectedModelId = cachedSelectedModelId ?? cachedModels.first?.id
        }
        viewModels[key] = vm
        accessOrder.append(key)

        evictIfNeeded()

        return vm
    }

    /// Evicts least-recently-used VMs when over the limit.
    /// Never evicts a VM that is streaming or has active transcriptions.
    /// Guarded against infinite loops.
    private func evictIfNeeded() {
        var iterations = 0
        let maxIterations = accessOrder.count + 1
        while viewModels.count > maxCachedViewModels && !accessOrder.isEmpty && iterations < maxIterations {
            iterations += 1
            let oldest = accessOrder.removeFirst()
            // Don't evict VMs that are actively streaming or transcribing
            if let vm = viewModels[oldest], vm.isStreaming || vm.hasActiveTranscriptions {
                accessOrder.append(oldest) // Move to end, try next
                continue
            }
            viewModels.removeValue(forKey: oldest)
        }
    }

    /// Updates the shared cache. Called by VMs after a successful model fetch.
    func updateModelCache(models: [AIModel], selectedId: String?) {
        cachedModels = models
        if let selectedId { cachedSelectedModelId = selectedId }
    }

    /// Removes the cached view model for a conversation that has finished.
    func remove(_ conversationId: String?) {
        viewModels.removeValue(forKey: conversationId ?? "__new__")
    }

    /// Replaces the new-chat placeholder key with the real conversation ID
    /// once the server assigns one.
    func promoteNewChat(to conversationId: String) {
        guard let vm = viewModels.removeValue(forKey: "__new__") else { return }
        viewModels[conversationId] = vm
    }

    /// Removes all cached view models and model cache (e.g. on server switch or logout).
    func clear() {
        viewModels.removeAll()
        accessOrder.removeAll()
        cachedModels = []
        cachedSelectedModelId = nil
        cachedMemorySetting = nil
        cachedPinnedModelIds = nil
    }
}

/// The live dependency container used in the production app.
@Observable
final class AppDependencyContainer: ServiceContainer {
    let serverConfigStore: ServerConfigStore
    let appearanceManager: AppearanceManager
    let accessibilityManager: AccessibilityManager

    /// The shared auth view model.
    private(set) var authViewModel: AuthViewModel

    /// Weak reference to the app router so services can reset navigation on server switch.
    weak var router: AppRouter?

    /// The current API client, scoped to the active server.
    private(set) var apiClient: APIClient?

    /// The current Socket.IO service, scoped to the active server.
    private(set) var socketService: SocketIOService?

    /// The conversation manager, scoped to the active server.
    private(set) var conversationManager: ConversationManager?

    /// The notes manager for local note storage and server sync.
    private(set) var notesManager: NotesManager?

    /// The folder manager for organising conversations into folders.
    private(set) var folderManager: FolderManager?

    /// The prompt manager for workspace prompt CRUD.
    private(set) var promptManager: PromptManager?

    /// The knowledge manager for workspace knowledge base CRUD.
    private(set) var knowledgeManager: KnowledgeManager?

    /// The skills manager for workspace skills CRUD.
    private(set) var skillsManager: SkillsManager?

    /// The tools manager for workspace tools CRUD.
    private(set) var toolsManager: ToolsManager?

    /// The functions manager for admin functions CRUD.
    private(set) var functionsManager: FunctionsManager?

    /// The model manager for workspace models CRUD.
    private(set) var modelManager: ModelManager?

    /// Persistent store for active chat view models.
    let activeChatStore = ActiveChatStore()

    // MARK: - Voice Call Services

    /// Notification service for local notifications.
    let notificationService = NotificationService.shared

    /// Speech recognition service (Apple on-device).
    let speechRecognitionService = SpeechRecognitionService()

    /// Server-side speech recognition service (records mic → uploads to /api/v1/audio/transcriptions).
    let serverSpeechRecognitionService = ServerSpeechRecognitionService()

    /// Text-to-speech service.
    let textToSpeechService = TextToSpeechService()

    /// CallKit manager for native call UI.
    let callKitManager = CallKitManager()

    /// Audio recording service for voice notes.
    let audioRecordingService = AudioRecordingService()

    /// File attachment service for managing chat/note attachments.
    let fileAttachmentService = FileAttachmentService()

    /// On-device ASR service — Parakeet TDT 1.7B.
    let asrService = OnDeviceASRService()

    /// Server-side task configuration (title gen, follow-ups, autocomplete, etc.).
    /// Cached on login/server connect and used to respect admin settings.
    private(set) var taskConfig: TaskConfig = .default

    /// Whether the server is currently reachable (updated by connection monitor).
    var isServerReachable: Bool = true

    /// Whether the socket is connected (mirrors `socketService.connectionState`).
    var socketConnectionState: SocketConnectionState = .disconnected

    /// A file received from another app via "Open In" / iOS share sheet,
    /// waiting to be injected into the chat input by ``ChatDetailView``.
    /// Set by ``handleIncomingFileURL`` in ``Open_UIApp``, consumed once by the view.
    var pendingIncomingFile: ChatAttachment?

    /// Incremented each time a new incoming file arrives.
    /// ``ChatDetailView`` observes this via `onChange` to pick up files
    /// even when the view is already visible.
    var pendingIncomingFileVersion: Int = 0

    init() {
        self.serverConfigStore = ServerConfigStore()
        self.appearanceManager = AppearanceManager()
        self.accessibilityManager = AccessibilityManager()
        // Create AuthViewModel once with all dependencies to avoid
        // wasted work from double-initialization.
        self.authViewModel = AuthViewModel(
            serverConfigStore: serverConfigStore,
            dependencies: nil // Set below after self is available
        )
        configureServicesForActiveServer()
        // Now that `self` is fully initialized, wire the dependency reference.
        // This avoids creating a second AuthViewModel (which would discard
        // the first one's optimistic auth state).
        authViewModel.dependencies = self
        // Models load on-demand when first needed — no startup preloading
        startConnectionMonitor()
    }

    /// Rebuilds the API client and socket service for the currently
    /// active server configuration.
    /// - Parameter isServerSwitch: Pass `true` when explicitly switching servers
    ///   or logging out. When `false` (default, used during init), caches are
    ///   preserved so the user doesn't lose their session on app launch.
    func configureServicesForActiveServer(isServerSwitch: Bool = false) {
        // Clear active chat view models on server switch
        activeChatStore.clear()

        // Only clear user data caches on explicit server switch or logout,
        // not on every app launch (which would nuke the saved session).
        if isServerSwitch {
            StorageManager.shared.clearAllUserData()
            // Clear cached model avatars so stale images from the previous
            // server/account don't persist into the new session.
            Task { await ImageCacheService.shared.clearAll() }
        }

        guard let config = serverConfigStore.activeServer else {
            apiClient = nil
            socketService?.dispose()
            socketService = nil
            conversationManager = nil
            notesManager = NotesManager()
            textToSpeechService.configureServerTTS(apiClient: nil)
            return
        }

        apiClient = APIClient(serverConfig: config)
        textToSpeechService.configureServerTTS(apiClient: apiClient)
        serverSpeechRecognitionService.configure(apiClient: apiClient)
        conversationManager = apiClient.map { ConversationManager(apiClient: $0) }
        folderManager = apiClient.map { FolderManager(apiClient: $0) }
        notesManager = NotesManager(apiClient: apiClient)
        promptManager = apiClient.map { PromptManager(apiClient: $0) }
        knowledgeManager = apiClient.map { KnowledgeManager(apiClient: $0) }
        skillsManager = apiClient.map { SkillsManager(apiClient: $0) }
        toolsManager = apiClient.map { ToolsManager(apiClient: $0) }
        functionsManager = apiClient.map { FunctionsManager(apiClient: $0) }
        modelManager = apiClient.map { ModelManager(apiClient: $0) }

        let serverHost = URL(string: config.url)?.host

        // Configure ImageCacheService with CF headers so model avatar images
        // are fetched with the correct User-Agent (Cloudflare ties cf_clearance
        // to the UA that solved the challenge).
        if config.isCloudflareBotProtected {
            Task {
                await ImageCacheService.shared.configureCFHeaders(
                    customHeaders: config.customHeaders,
                    serverHost: serverHost
                )
            }
        } else {
            Task {
                await ImageCacheService.shared.configureCFHeaders(
                    customHeaders: nil,
                    serverHost: nil
                )
            }
        }

        // Configure ImageCacheService with self-signed cert support so avatar images
        // load on servers that use self-signed TLS certificates.
        // Without this, URLSession.shared rejects the SSL handshake and the shimmer
        // placeholder spins forever (issue #4).
        Task {
            await ImageCacheService.shared.configureSelfSignedCertSupport(
                allowed: config.allowSelfSignedCertificates,
                serverHost: config.allowSelfSignedCertificates ? serverHost : nil
            )
        }

        // Configure file attachment service
        if let manager = conversationManager {
            fileAttachmentService.configure(with: manager)
        }

        // Set up 401 callback for automatic re-auth
        apiClient?.onAuthTokenInvalid = { [weak self] in
            Task { @MainActor in
                self?.authViewModel.currentUser = nil
                self?.authViewModel.phase = .authMethodSelection
                self?.authViewModel.errorMessage = "Your session has expired. Please sign in again."
            }
        }

        // Dispose previous socket before creating new one
        socketService?.dispose()

        let token = KeychainService.shared.getToken(forServer: config.url)
        socketService = SocketIOService(serverConfig: config, authToken: token)

        // Wire socket state to the dependency container's observable property
        wireSocketStateTracking()

        // Update shared data for widget
        SharedDataService.shared.saveAuthState(
            isAuthenticated: true,
            userName: authViewModel.currentUser?.displayName,
            serverURL: config.url
        )
    }

    /// Convenience: refreshes services after server config changes.
    /// Treats this as a server switch (clears user data caches).
    func refreshServices() {
        configureServicesForActiveServer(isServerSwitch: true)
    }

    /// Creates a configured VoiceCallViewModel ready for use.
    /// Picks the live STT service based on the user's `sttEngine` preference:
    /// - "server" → `ServerSpeechRecognitionService` (records mic → uploads to server)
    /// - anything else → `SpeechRecognitionService` (Apple on-device)
    func makeVoiceCallViewModel() -> VoiceCallViewModel {
        let useServerSTT = UserDefaults.standard.string(forKey: "sttEngine") == "server"
            && serverSpeechRecognitionService.isAvailable

        if useServerSTT {
            return VoiceCallViewModel(
                serverSpeechService: serverSpeechRecognitionService,
                ttsService: textToSpeechService,
                callKitManager: callKitManager
            )
        } else {
            return VoiceCallViewModel(
                speechService: speechRecognitionService,
                ttsService: textToSpeechService,
                callKitManager: callKitManager
            )
        }
    }

    /// Processes any pending shared content from the Share Extension.
    func processPendingSharedContent() -> SharedContent? {
        let defaults = UserDefaults(suiteName: SharedDataService.appGroupId)
        guard let data = defaults?.data(forKey: "pending_shared_content"),
              let content = try? JSONDecoder().decode(SharedContent.self, from: data) else {
            return nil
        }
        // Clear pending content
        defaults?.removeObject(forKey: "pending_shared_content")
        return content
    }

    /// Updates widget data with current conversations.
    func updateWidgetData(conversations: [Conversation]) {
        let recent = conversations.prefix(5).map { conv in
            SharedDataService.RecentConversation(
                id: conv.id,
                title: conv.title,
                lastMessage: conv.messages.last?.content ?? "",
                updatedAt: conv.updatedAt,
                modelName: conv.model
            )
        }
        SharedDataService.shared.saveRecentConversations(Array(recent))
    }

    // MARK: - Connection Health Monitor

    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    /// Starts monitoring connection health.
    /// - Observes `willEnterForeground` to run a health check and reconnect socket if needed.
    /// - Observes `didEnterBackground` to unload all MLX GPU models before iOS suspends
    ///   the process — Metal command buffer execution is not permitted from the background
    ///   and causes an unrecoverable crash (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`).
    /// - Wires up the socket's `onConnectionStateChange` to update `socketConnectionState`.
    private func startConnectionMonitor() {
        // Listen for foreground transitions
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.performForegroundHealthCheck()
            }
        }

        // Unload all MLX GPU models before iOS suspends the app.
        // MLX uses Metal under the hood — any in-flight GPU work submitted from
        // a suspended process is immediately aborted with a fatal error.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.unloadMLXModelsForBackground()
            }
        }

        // Wire up socket state changes
        wireSocketStateTracking()
    }

    /// Unloads all in-memory MLX models so Metal GPU resources are released before
    /// the app is suspended. Models reload automatically on next use.
    private func unloadMLXModelsForBackground() {
        // ASR — unload regardless of state (ready or mid-transcription)
        switch asrService.state {
        case .ready, .transcribing: asrService.unloadModel()
        default: break
        }
        // Marvis TTS — stop playback and unload GPU model
        textToSpeechService.unloadMarvisModel()
    }

    /// Called whenever a new `socketService` is created, wires its state to
    /// the dependency container's observable `socketConnectionState`.
    private func wireSocketStateTracking() {
        socketService?.onConnectionStateChange = { [weak self] state in
            Task { @MainActor in
                self?.socketConnectionState = state
            }
        }
    }

    /// Runs a lightweight health check when the app enters the foreground.
    /// If the server is reachable but the socket is dead, reconnects it.
    private func performForegroundHealthCheck() async {
        guard let client = apiClient else { return }
        guard authViewModel.isAuthenticated else { return }

        let healthy = await client.checkHealth()
        isServerReachable = healthy

        if healthy {
            // Server is up — make sure socket is connected
            if let socket = socketService, !socket.isConnected {
                let _ = await socket.ensureConnected(timeout: 5.0)
            }
        }
    }

    // MARK: - Task Configuration

    /// Fetches and caches the server-side task configuration.
    ///
    /// Called after authentication succeeds and periodically on foreground
    /// return. The config controls which background tasks (title gen,
    /// follow-ups, tags, autocomplete) the admin has enabled globally.
    func fetchTaskConfig() async {
        guard let client = apiClient else { return }
        do {
            taskConfig = try await client.getTaskConfig()
            // Push to ActiveChatStore so ChatViewModels can read it
            activeChatStore.serverTaskConfig = taskConfig
        } catch {
            // Non-critical — keep using default (all enabled)
        }
    }
}
