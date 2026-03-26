import Foundation
import os.log

/// Provides shared data storage between the main app, widget extension,
/// and share extension using App Groups.
///
/// Uses ``UserDefaults(suiteName:)`` with the app group identifier
/// to share data across process boundaries.
final class SharedDataService: Sendable {

    /// Singleton instance.
    static let shared = SharedDataService()

    /// The App Group identifier. Must match the entitlements configuration.
    static let appGroupId = "group.com.openui.openui"

    private let logger = Logger(subsystem: "com.openui", category: "SharedData")
    private let defaults: UserDefaults?

    // Storage keys
    private enum Keys {
        static let recentConversations = "recent_conversations"
        static let recentNotes = "recent_notes"
        static let serverURL = "server_url"
        static let isAuthenticated = "is_authenticated"
        static let userName = "user_name"
        static let lastActiveConversationId = "last_active_conversation_id"
    }

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroupId)
        if defaults == nil {
            logger.warning("App Group UserDefaults unavailable. Widget data sharing will not work.")
        }
    }

    // MARK: - Recent Conversations

    /// Saves recent conversations for widget display.
    func saveRecentConversations(_ conversations: [RecentConversation]) {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        defaults?.set(data, forKey: Keys.recentConversations)
    }

    /// Reads recent conversations from shared storage.
    func loadRecentConversations() -> [RecentConversation] {
        guard let data = defaults?.data(forKey: Keys.recentConversations),
              let conversations = try? JSONDecoder().decode([RecentConversation].self, from: data) else {
            return []
        }
        return conversations
    }

    // MARK: - Recent Notes

    /// Saves recent notes for widget display.
    func saveRecentNotes(_ notes: [RecentNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        defaults?.set(data, forKey: Keys.recentNotes)
    }

    /// Reads recent notes from shared storage.
    func loadRecentNotes() -> [RecentNote] {
        guard let data = defaults?.data(forKey: Keys.recentNotes),
              let notes = try? JSONDecoder().decode([RecentNote].self, from: data) else {
            return []
        }
        return notes
    }

    // MARK: - Auth State

    /// Saves authentication state for widget conditional rendering.
    func saveAuthState(isAuthenticated: Bool, userName: String?, serverURL: String?) {
        defaults?.set(isAuthenticated, forKey: Keys.isAuthenticated)
        defaults?.set(userName, forKey: Keys.userName)
        defaults?.set(serverURL, forKey: Keys.serverURL)
    }

    var isAuthenticated: Bool {
        defaults?.bool(forKey: Keys.isAuthenticated) ?? false
    }

    var userName: String? {
        defaults?.string(forKey: Keys.userName)
    }

    var serverURL: String? {
        defaults?.string(forKey: Keys.serverURL)
    }

    // MARK: - Active Conversation

    /// Saves the last active conversation ID for "Continue Last Conversation" shortcut.
    func saveLastActiveConversationId(_ id: String?) {
        defaults?.set(id, forKey: Keys.lastActiveConversationId)
    }

    var lastActiveConversationId: String? {
        defaults?.string(forKey: Keys.lastActiveConversationId)
    }

    // MARK: - Shared Data Models

    /// Lightweight conversation data for widget display.
    struct RecentConversation: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let lastMessage: String
        let updatedAt: Date
        let modelName: String?
    }

    /// Lightweight note data for widget display.
    struct RecentNote: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let preview: String
        let updatedAt: Date
    }
}
