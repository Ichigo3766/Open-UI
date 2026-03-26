import AppIntents
import Foundation

// MARK: - New Chat Intent

/// Siri shortcut / Shortcuts app: start a new chat with keyboard focus.
/// Mirrors the widget "Ask Open Relay" bar and the home-screen quick action.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Start a new chat conversation with the AI assistant.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
        }
        return .result()
    }
}

// MARK: - Voice Call Intent

/// Siri shortcut / Shortcuts app: start a voice call with the AI assistant.
/// Mirrors the widget mic button and the home-screen "Voice Call" quick action.
struct VoiceCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Voice Call"
    static var description = IntentDescription("Start a voice call with the AI assistant.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUIWidgetVoiceCall, object: nil)
        }
        return .result()
    }
}

// MARK: - Camera Chat Intent

/// Siri shortcut / Shortcuts app: open a new chat and immediately launch the camera.
/// Mirrors the widget camera button and the home-screen "Camera Chat" quick action.
struct CameraChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Camera Chat"
    static var description = IntentDescription("Start a new chat and open the camera to attach a photo.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUICameraChat, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - Photos Chat Intent

/// Siri shortcut / Shortcuts app: open a new chat and immediately launch the photo picker.
/// Mirrors the widget photos button.
struct PhotosChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Photos Chat"
    static var description = IntentDescription("Start a new chat and open Photos to attach an image.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIPhotosChat, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - File Chat Intent

/// Siri shortcut / Shortcuts app: open a new chat and immediately launch the file picker.
/// Mirrors the widget file/paperclip button.
struct FileChatIntent: AppIntent {
    static var title: LocalizedStringResource = "File Chat"
    static var description = IntentDescription("Start a new chat and open Files to attach a document.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .openUINewChatWithFocus, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .openUIFileChat, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - New Channel Intent

/// Siri shortcut / Shortcuts app: open the create-channel sheet.
/// Mirrors the widget channel button and the home-screen "New Channel" quick action.
struct NewChannelIntent: AppIntent {
    static var title: LocalizedStringResource = "New Channel"
    static var description = IntentDescription("Open the create-channel sheet in Open Relay.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .openUINewChannel, object: nil)
            }
        }
        return .result()
    }
}

// MARK: - App Shortcuts Provider

/// Provides the app's shortcuts to the Shortcuts app and Siri.
/// All shortcuts mirror the widget quick-action buttons exactly.
struct OpenUIShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "Start a new chat in \(.applicationName)",
                "New conversation in \(.applicationName)",
                "Chat with \(.applicationName)",
                "Ask \(.applicationName) something"
            ],
            shortTitle: "New Chat",
            systemImageName: "bubble.left.and.text.bubble.right"
        )

        AppShortcut(
            intent: VoiceCallIntent(),
            phrases: [
                "Call \(.applicationName)",
                "Voice call with \(.applicationName)",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Voice Call",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: CameraChatIntent(),
            phrases: [
                "Camera chat with \(.applicationName)",
                "Take a photo for \(.applicationName)",
                "Open camera in \(.applicationName)"
            ],
            shortTitle: "Camera Chat",
            systemImageName: "camera.fill"
        )

        AppShortcut(
            intent: PhotosChatIntent(),
            phrases: [
                "Send a photo to \(.applicationName)",
                "Photos chat in \(.applicationName)",
                "Attach a photo in \(.applicationName)"
            ],
            shortTitle: "Photos Chat",
            systemImageName: "photo.fill"
        )

        AppShortcut(
            intent: FileChatIntent(),
            phrases: [
                "Send a file to \(.applicationName)",
                "File chat in \(.applicationName)",
                "Attach a document in \(.applicationName)"
            ],
            shortTitle: "File Chat",
            systemImageName: "paperclip"
        )

        AppShortcut(
            intent: NewChannelIntent(),
            phrases: [
                "New channel in \(.applicationName)",
                "Create a channel in \(.applicationName)"
            ],
            shortTitle: "New Channel",
            systemImageName: "number"
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    // Widget deep links — trigger attachment pickers directly on new chat open
    static let openUICameraChat  = Notification.Name("com.openui.widget.cameraChat")
    static let openUIPhotosChat  = Notification.Name("com.openui.widget.photosChat")
    static let openUIFileChat    = Notification.Name("com.openui.widget.fileChat")
    // Widget deep link — open create-channel sheet
    static let openUINewChannel  = Notification.Name("com.openui.widget.newChannel")
    // Widget deep link — start a new chat AND auto-focus the input field (show keyboard)
    static let openUINewChatWithFocus    = Notification.Name("com.openui.widget.newChatWithFocus")
    // Widget deep link — start a voice call from widget mic button
    static let openUIWidgetVoiceCall     = Notification.Name("com.openui.widget.voiceCall")
    // Internal relay: MainChatView → ChatInputField to request keyboard focus
    static let chatInputFieldRequestFocus = Notification.Name("com.openui.input.requestFocus")
    // Broadcast: dismiss all presented overlays (camera, file picker, voice call, sheets)
    // before starting a new quick action to prevent stacking.
    static let openUIDismissOverlays = Notification.Name("com.openui.dismissOverlays")
}

// MARK: - Shortcut Donation Helper

/// Donates app intents to Siri to improve suggestion relevance.
enum ShortcutDonationService {

    /// Donates the "New Chat" shortcut after the user creates a chat.
    static func donateNewChat() {
        let intent = NewChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "Voice Call" shortcut after the user makes a call.
    static func donateVoiceCall() {
        let intent = VoiceCallIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "Camera Chat" shortcut when the user uses the camera.
    static func donateCameraChat() {
        let intent = CameraChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "Photos Chat" shortcut when the user attaches photos.
    static func donatePhotosChat() {
        let intent = PhotosChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "File Chat" shortcut when the user attaches files.
    static func donateFileChat() {
        let intent = FileChatIntent()
        Task {
            try? await intent.donate()
        }
    }

    /// Donates the "New Channel" shortcut when the user creates a channel.
    static func donateNewChannel() {
        let intent = NewChannelIntent()
        Task {
            try? await intent.donate()
        }
    }
}
