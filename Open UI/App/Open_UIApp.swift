import SwiftUI
import WidgetKit
import BackgroundTasks
import UIKit

// MARK: - App Delegate + Scene Delegate (handles home screen Quick Actions)
//
// In a scene-based SwiftUI app (UIApplicationSceneManifest_Generation = YES),
// UIApplicationDelegate.performActionFor is NEVER called for shortcut items.
// iOS routes them to the UIWindowSceneDelegate instead:
//   • Cold launch  → scene(_:willConnectTo:options:)  (connectionOptions.shortcutItem)
//   • Warm launch  → windowScene(_:performActionFor:completionHandler:)

final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Pending shortcut action type string, set by the scene delegate.
    /// Consumed by the `scenePhase == .active` handler in `Open_UIApp`.
    static var pendingShortcutAction: String?

    /// Return a scene configuration that uses our custom SceneDelegate.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ShortcutSceneDelegate.self
        return config
    }
}

/// Scene delegate that intercepts shortcut items on both cold and warm launch.
final class ShortcutSceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// **Cold launch**: shortcut item arrives in connectionOptions.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem {
            AppDelegate.pendingShortcutAction = shortcutItem.type
        }
    }

    /// **Warm launch**: app already running / suspended when user taps a quick action.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        AppDelegate.pendingShortcutAction = shortcutItem.type
        completionHandler(true)
    }
}

@main
struct Open_UIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                    if newPhase == .active {
                        // Process pending actions after a short delay so that
                        // MainChatView / iPadMainChatView have time to mount
                        // their .onReceive handlers before we post notifications.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // 1. Quick Action from home screen long-press
                            if let action = AppDelegate.pendingShortcutAction {
                                AppDelegate.pendingShortcutAction = nil
                                handleShortcutAction(action)
                            }

                            // 2. Control Center widget action (cross-process via UserDefaults)
                            let defaults = UserDefaults(suiteName: SharedDataService.appGroupId)
                            if let ccAction = defaults?.string(forKey: "pendingControlCenterAction") {
                                defaults?.removeObject(forKey: "pendingControlCenterAction")
                                handleControlCenterAction(ccAction)
                            }
                        }
                    }
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
            // Widget "Ask Open Relay" bar → new chat with keyboard auto-focus.
            // Posts a notification that MainChatView/iPadMainChatView handle directly
            // (they own the activeConversationId state, not the router).
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            ShortcutDonationService.donateNewChat()

        case "voice-call":
            // Widget mic button → voice call. Posts a notification that
            // MainChatView/iPadMainChatView handle by creating a VoiceCallViewModel
            // and presenting it via router.presentVoiceCall(viewModel:).
            NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
            ShortcutDonationService.donateVoiceCall()

        case "new-note":
            router.navigate(to: .notesList)

        case "continue":
            if let conversationId = SharedDataService.shared.lastActiveConversationId {
                router.navigate(to: .chatDetail(conversationId: conversationId))
            }

        case "camera-chat":
            // Widget camera button → new chat + open camera immediately.
            // Posts newChatWithFocus first (MainChatView/iPadMainChatView handle
            // creating the new chat via local state), then after a delay posts
            // the camera notification which ChatDetailView handles.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUICameraChat, object: nil)
            }

        case "photos-chat":
            // Widget photos button → new chat + open photo picker immediately.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIPhotosChat, object: nil)
            }

        case "file-chat":
            // Widget files button → new chat + open file picker immediately.
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIFileChat, object: nil)
            }

        case "new-channel":
            // Signal the main view to open the create-channel sheet
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)
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

    // MARK: - Overlay Dismissal

    /// Dismisses all presented overlays (camera, file picker, voice call, sheets, etc.)
    /// before starting a new quick action so they don't stack on top of each other.
    /// Posts a broadcast notification that ChatDetailView, MainChatView, and
    /// iPadMainChatView each listen for to reset their local overlay booleans.
    private func dismissAllOverlays() {
        NotificationCenter.default.post(name: .openUIDismissOverlays, object: nil)
        router.dismissVoiceCall()
        router.dismissSheet()
    }

    // MARK: - Quick Action Handlers

    /// Maps a `UIApplicationShortcutItemType` string (from Info.plist) to the
    /// corresponding NotificationCenter post so MainChatView / iPadMainChatView
    /// can react. Called from the `scenePhase == .active` handler after a delay.
    private func handleShortcutAction(_ type: String) {
        // Dismiss any existing overlays first so new action doesn't stack
        dismissAllOverlays()

        // Short delay to let SwiftUI animate the dismissal before presenting new overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch type {
            case "com.openui.openui.new-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                ShortcutDonationService.donateNewChat()

            case "com.openui.openui.voice-call":
                NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
                ShortcutDonationService.donateVoiceCall()

            case "com.openui.openui.camera-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .openUICameraChat, object: nil)
                }

            case "com.openui.openui.new-channel":
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)

            default:
                break
            }
        }
    }

    /// Handles a pending action written to shared UserDefaults by the
    /// Control Center widget extension (runs in a separate process).
    private func handleControlCenterAction(_ action: String) {
        // Dismiss any existing overlays first so new action doesn't stack
        dismissAllOverlays()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            switch action {
            case "new-chat":
                NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
                ShortcutDonationService.donateNewChat()
            default:
                break
            }
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
