import Foundation
import os.log

/// Wraps `APIClient` calls for conversation lifecycle operations.
final class ConversationManager: @unchecked Sendable {
    let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "ConversationManager")

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch

    func fetchConversations(limit: Int? = nil, skip: Int? = nil) async throws -> [Conversation] {
        try await apiClient.getConversations(limit: limit, skip: skip)
    }

    /// Fetches a single page of conversations by 1-based page number.
    /// Returns an empty array when no more pages exist.
    func fetchConversationsPage(page: Int, pinnedIds: Set<String>? = nil) async throws -> [Conversation] {
        try await apiClient.getConversationsPage(page: page, pinnedIds: pinnedIds)
    }

    func fetchConversation(id: String) async throws -> Conversation {
        try await apiClient.getConversation(id: id)
    }

    func searchConversations(query: String) async throws -> [Conversation] {
        try await apiClient.searchConversations(query: query)
    }

    // MARK: - Create

    func createConversation(
        title: String,
        messages: [ChatMessage] = [],
        model: String? = nil,
        systemPrompt: String? = nil,
        folderId: String? = nil
    ) async throws -> Conversation {
        try await apiClient.createConversation(
            title: title,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            folderId: folderId
        )
    }

    // MARK: - Update

    func renameConversation(id: String, title: String) async throws {
        try await apiClient.updateConversation(id: id, title: title)
    }

    func updateSystemPrompt(id: String, systemPrompt: String) async throws {
        try await apiClient.updateConversation(id: id, systemPrompt: systemPrompt)
    }

    func saveConversation(_ conversation: Conversation) async throws {
        try await apiClient.syncConversationMessages(
            id: conversation.id,
            messages: conversation.messages,
            model: conversation.model,
            systemPrompt: conversation.systemPrompt,
            title: conversation.title
        )
    }

    // MARK: - Delete

    func deleteConversation(id: String) async throws {
        try await apiClient.deleteConversation(id: id)
    }

    func deleteAllConversations() async throws {
        try await apiClient.deleteAllConversations()
    }

    // MARK: - Pin / Archive

    func pinConversation(id: String, pinned: Bool) async throws {
        try await apiClient.pinConversation(id: id, pinned: pinned)
    }

    func archiveConversation(id: String, archived: Bool) async throws {
        try await apiClient.archiveConversation(id: id, archived: archived)
    }

    // MARK: - Share / Clone

    func shareConversation(id: String) async throws -> String? {
        try await apiClient.shareConversation(id: id)
    }

    func cloneConversation(id: String) async throws -> Conversation {
        try await apiClient.cloneConversation(id: id)
    }

    // MARK: - Models

    func fetchModels() async throws -> [AIModel] {
        try await apiClient.getModels()
    }

    func fetchDefaultModel() async -> String? {
        await apiClient.getDefaultModel()
    }

    // MARK: - Tools & Terminals

    func fetchTerminalServers() async throws -> [TerminalServer] {
        try await apiClient.listTerminalServers()
    }

    func fetchTools() async throws -> [ToolItem] {
        let rawTools = try await apiClient.getTools()
        return rawTools.compactMap { raw -> ToolItem? in
            guard let id = raw["id"] as? String else { return nil }
            let name = raw["name"] as? String ?? id.replacingOccurrences(of: "_", with: " ").capitalized
            let meta = raw["meta"] as? [String: Any]
            let description = meta?["description"] as? String ?? raw["description"] as? String
            let isActive = raw["is_active"] as? Bool ?? meta?["enabled"] as? Bool ?? false
            return ToolItem(id: id, name: name, description: description, isEnabled: isActive)
        }
    }

    // MARK: - Chat Completion

    func sendMessageStreaming(request: ChatCompletionRequest) async throws -> SSEStream {
        try await apiClient.sendMessageStreaming(request: request)
    }

    func sendMessageHTTP(request: ChatCompletionRequest) async throws -> [String: Any] {
        try await apiClient.sendMessageHTTP(request: request)
    }

    func syncConversationMessages(
        id: String,
        messages: [ChatMessage],
        model: String?,
        systemPrompt: String? = nil,
        title: String? = nil
    ) async throws {
        try await apiClient.syncConversationMessages(
            id: id,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt,
            title: title
        )
    }

    func sendChatCompleted(
        chatId: String,
        messageId: String,
        model: String,
        sessionId: String,
        messages: [[String: Any]] = [],
        filterIds: [String] = []
    ) async {
        await apiClient.sendChatCompleted(
            chatId: chatId,
            messageId: messageId,
            model: model,
            sessionId: sessionId,
            messages: messages,
            filterIds: filterIds
        )
    }

    // MARK: - Files

    func uploadFile(data: Data, fileName: String, onUploaded: ((String) -> Void)? = nil) async throws -> String {
        try await apiClient.uploadFile(data: data, fileName: fileName, onUploaded: onUploaded)
    }

    // MARK: - Knowledge

    func fetchKnowledgeItems() async throws -> [KnowledgeItem] {
        try await apiClient.getKnowledgeItems()
    }

    func fetchKnowledgeFileItems() async throws -> [KnowledgeItem] {
        try await apiClient.getKnowledgeFileItems()
    }

    func fetchFolderItems() async throws -> [KnowledgeItem] {
        try await apiClient.getFolderItems()
    }

    var baseURL: String { apiClient.baseURL }
}
