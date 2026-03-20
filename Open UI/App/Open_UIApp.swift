import SwiftUI
import WidgetKit
import BackgroundTasks

@main
struct Open_UIApp: App {
    @State private var dependencies = AppDependencyContainer()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // No-op: mlx-audio-swift handles model caching via HuggingFace Hub

        // Remove the default circular/pill-shaped backgrounds from navigation
        // bar toolbar buttons that iOS adds in dark mode (iOS 15+).
        let plainButtonAppearance = UIBarButtonItemAppearance(style: .plain)
        plainButtonAppearance.normal.titleTextAttributes = [:]
        plainButtonAppearance.highlighted.titleTextAttributes = [:]

        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        navBarAppearance.buttonAppearance = plainButtonAppearance
        navBarAppearance.doneButtonAppearance = plainButtonAppearance

        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(dependencies)
                .task {
                    // Wire the router into the dependency container so AuthViewModel
                    // can reset navigation on server switch (must be done after both
                    // objects are injected into the environment).
                    dependencies.router = router
                }
                .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .inactive || newPhase == .background {
                        // Stop MarvisTTS and unload model before backgrounding to prevent
                        // Metal GPU crash (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted).
                        // .inactive fires before .background, giving us time to release GPU resources.
                        dependencies.textToSpeechService.stop()
                        dependencies.textToSpeechService.marvisService.stopAndUnload()

                        // ASR background safety: pause on-device transcription on iOS < 26.
                        //
                        // iOS < 26: Metal GPU access is forbidden in the background. Calling
                        // pauseForBackground() cancels the in-flight MLX task and unloads the
                        // model BEFORE iOS revokes GPU access, preventing the uncatchable
                        // std::runtime_error crash. ChatViewModel catches .backgroundInterrupted
                        // and auto-restarts transcription when the app returns to foreground.
                        //
                        // iOS 26+: BGContinuedProcessingTask + Background GPU Access entitlement
                        // keeps the GPU alive in the background, so pauseForBackground() is a
                        // no-op and transcription continues uninterrupted for minutes.
                        dependencies.asrService.pauseForBackground()

                        // STORAGE FIX: Run routine cleanup when entering background.
                        // Cleans orphaned temp files, prunes upload cache, evicts
                        // oversized image cache. Zero user intervention needed.
                        StorageManager.shared.performRoutineCleanup()
                    }
                }
                .task {
                    // STORAGE FIX: Run cleanup on app launch to handle accumulated
                    // data from previous sessions (orphaned files, stale caches, etc.)
                    StorageManager.shared.performRoutineCleanup()
                    
                    // Evict profile image cache on startup so avatars refresh
                    // if the user changed them on the web UI since last launch.
                    await ImageCacheService.shared.evictProfileImages()

                    // Initialize notification service: registers categories and
                    // requests permission if not yet determined. Also acts as a
                    // fallback safety net in notifyGenerationComplete() in case
                    // the user hasn't been prompted yet.
                    await NotificationService.shared.setup()

                    // Wire notification tap to router
                    NotificationService.shared.onOpenChat = { conversationId in
                        router.navigate(to: .chatDetail(conversationId: conversationId))
                    }
                }
                .onOpenURL { url in
                    if url.isFileURL {
                        handleIncomingFileURL(url)
                    } else {
                        handleDeepLink(url)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openUINewChat)) { _ in
                    router.navigate(to: .newChat)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openUIVoiceCall)) { _ in
                    router.presentSheet(.voiceCall(startNewConversation: true))
                }
                .onReceive(NotificationCenter.default.publisher(for: .openUIContinueConversation)) { notification in
                    if let conversationId = notification.object as? String {
                        router.navigate(to: .chatDetail(conversationId: conversationId))
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openUICreateNote)) { notification in
                    // Navigate to notes and create a new note
                    router.navigate(to: .notesList)
                }
        }
    }

    /// Handles a file URL received via "Open In" / document import from another app.
    /// Reads the file data, creates a ChatAttachment, and navigates to a new chat
    /// with the file pre-attached in the input field.
    private func handleIncomingFileURL(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let imageExts = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp"]
        let isImage = imageExts.contains(ext)

        let thumbnail: Image? = isImage ? UIImage(data: data).map { Image(uiImage: $0) } : nil
        let attachment = ChatAttachment(
            type: isImage ? .image : .file,
            name: fileName,
            thumbnail: thumbnail,
            data: data
        )

        dependencies.pendingIncomingFile = attachment
        dependencies.pendingIncomingFileVersion += 1
        dependencies.activeChatStore.remove(nil)
        router.navigate(to: .newChat)
    }

    /// Handles deep links from widgets and external sources.
    private func handleDeepLink(_ url: URL) {
        guard let host = url.host() else { return }

        switch host {
        case "new-chat":
            router.navigate(to: .newChat)
            ShortcutDonationService.donateNewChat()

        case "voice-call":
            router.presentSheet(.voiceCall(startNewConversation: true))
            ShortcutDonationService.donateVoiceCall()

        case "new-note":
            router.navigate(to: .notesList)
            ShortcutDonationService.donateCreateNote()

        case "continue":
            if let conversationId = SharedDataService.shared.lastActiveConversationId {
                router.navigate(to: .chatDetail(conversationId: conversationId))
            }

        case "chat":
            // openui://chat/{conversationId}
            // FIX: Validate conversation ID format before navigating to prevent
            // malicious deep links from causing confusing UX.
            let conversationId = url.pathComponents.last ?? ""
            if !conversationId.isEmpty && conversationId != "/"
                && conversationId.count >= 8 && conversationId.count <= 128
                && conversationId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                router.navigate(to: .chatDetail(conversationId: conversationId))
            }

        case "note":
            // openui://note/{noteId}
            // FIX: Validate note ID format before navigating.
            let noteId = url.pathComponents.last ?? ""
            if !noteId.isEmpty && noteId != "/"
                && noteId.count >= 8 && noteId.count <= 128
                && noteId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                router.navigate(to: .noteEditor(noteId: noteId))
            }

        default:
            break
        }
    }
}

/// Root view that manages the full authentication flow using a phase-based state machine.
struct RootView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var hasAttemptedRestore = false

    private var viewModel: AuthViewModel {
        dependencies.authViewModel
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .serverConnection:
                ServerConnectionView(viewModel: viewModel)

            case .restoringSession:
                // Show a lightweight loading/retry screen while validating the saved token
                sessionRestoringView

            case .authMethodSelection:
                NavigationStack {
                    AuthMethodSelectionView(viewModel: viewModel)
                }

            case .credentialLogin:
                NavigationStack {
                    LoginView(viewModel: viewModel)
                }

            case .signUp:
                NavigationStack {
                    SignUpView(viewModel: viewModel)
                }

            case .pendingApproval:
                PendingApprovalView(viewModel: viewModel)

            case .ldapLogin:
                NavigationStack {
                    LDAPLoginView(viewModel: viewModel)
                }

            case .ssoLogin:
                NavigationStack {
                    SSOAuthView(viewModel: viewModel)
                }

            case .authenticated:
                authenticatedContent

            case .serverSwitcher:
                NavigationStack {
                    ScrollView {
                        SavedServersView(viewModel: viewModel, showAddServerButton: true)
                    }
                    .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                    .navigationTitle("Switch Server")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.phase)
        .task {
            guard !hasAttemptedRestore else { return }
            hasAttemptedRestore = true

            guard dependencies.serverConfigStore.activeServer != nil else { return }

            switch viewModel.phase {
            case .authenticated:
                // Optimistic auth — user is already seeing the chat screen.
                // Validate the token silently in the background.
                await viewModel.validateSessionInBackground()
            case .restoringSession:
                // Have token but no cached user — must validate before showing chat.
                await viewModel.restoreSession()
            case .authMethodSelection:
                // Signed out but server is saved — fetch backend config so that
                // login/SSO options are populated correctly without requiring a reconnect.
                await viewModel.fetchBackendConfigIfNeeded()
            default:
                break
            }
        }
    }

    /// Loading / retry view shown while restoring a saved session.
    ///
    /// When `AuthViewModel.restoreSession()` fails due to a transient error
    /// (network down, 502, etc.) it stays in `.restoringSession` phase and
    /// sets `errorMessage`. This view shows a retry button so the user can
    /// try again without re-entering credentials.
    private var sessionRestoringView: some View {
        VStack(spacing: 20) {
            if let error = viewModel.errorMessage {
                // Connection failed — show error + retry
                Image(systemName: "wifi.exclamationmark")
                    .scaledFont(size: 44)
                    .foregroundStyle(.secondary)

                Text("Connection Issue")
                    .font(.title3.weight(.semibold))

                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    Task {
                        await viewModel.retrySessionRestore()
                    }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.body.weight(.medium))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button("Sign in with different account") {
                    viewModel.errorMessage = nil
                    viewModel.phase = .authMethodSelection
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            } else {
                // Normal loading state
                ProgressView()
                    .controlSize(.large)
                Text("Connecting...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var authenticatedContent: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadMainChatView()
            } else {
                MainChatView()
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(
                    userName: viewModel.currentUser?.displayName ?? "there"
                ) {
                    viewModel.markOnboardingSeen()
                }
            }
            .onAppear {
                // Show onboarding for first-time users
                if !viewModel.hasShownOnboarding {
                    showOnboarding = true
                }

                // Update widget data
                WidgetCenter.shared.reloadAllTimelines()

                // Update shared auth state
                SharedDataService.shared.saveAuthState(
                    isAuthenticated: true,
                    userName: viewModel.currentUser?.displayName,
                    serverURL: dependencies.serverConfigStore.activeServer?.url
                )
            }
    }
}
