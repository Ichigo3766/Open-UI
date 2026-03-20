import Foundation
import os.log

/// Manages folder lifecycle operations against the OpenWebUI server.
///
/// All methods are `async` and designed to be called from `@Observable`
/// view models on the main actor. Expand/collapse sync is debounced
/// (500 ms) and fire-and-forget — UI state is never blocked by it.
final class FolderManager: @unchecked Sendable {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "FolderManager")

    /// Tracks pending expand-sync tasks keyed by folder ID so we can
    /// cancel the previous debounce before scheduling a new one.
    private var expandSyncTasks: [String: Task<Void, Never>] = [:]

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch

    /// Fetches all folders from the server.
    ///
    /// Returns `(folders, featureEnabled)`.  When the server returns 403
    /// (folder feature disabled or insufficient permissions) the tuple
    /// contains an empty array and `featureEnabled = false`.
    func fetchFolders() async throws -> (folders: [ChatFolder], enabled: Bool) {
        let (rawFolders, enabled) = try await apiClient.getFolders()
        guard enabled else { return ([], false) }
        let folders = rawFolders.compactMap { ChatFolder(json: $0) }
        return (folders, true)
    }

    /// Fetches full folder details by ID, including data and meta fields.
    func fetchFolderById(id: String) async throws -> ChatFolder {
        let raw = try await apiClient.getFolderById(id: id)
        guard let folder = ChatFolder(json: raw) else {
            throw FolderError.invalidResponse
        }
        return folder
    }

    /// Fetches the conversations inside a specific folder (page 1).
    func fetchChatsInFolder(folderId: String) async throws -> [Conversation] {
        try await apiClient.getChatsInFolder(folderId: folderId)
    }

    // MARK: - Create

    /// Creates a new folder with the given name and returns the persisted model.
    func createFolder(
        name: String,
        parentId: String? = nil,
        data: FolderData? = nil,
        meta: FolderMeta? = nil
    ) async throws -> ChatFolder {
        let raw = try await apiClient.createFolder(
            name: name,
            parentId: parentId,
            data: data?.toJSON(),
            meta: meta?.toJSON()
        )
        guard let folder = ChatFolder(json: raw) else {
            throw FolderError.invalidResponse
        }
        return folder
    }

    // MARK: - Update (Full)

    /// Full update: name, data (system prompt, models, knowledge), and meta (background image).
    func updateFolder(
        id: String,
        name: String? = nil,
        data: FolderData? = nil,
        meta: FolderMeta? = nil
    ) async throws -> ChatFolder {
        let raw = try await apiClient.updateFolder(
            id: id,
            name: name,
            data: data?.toJSON(),
            meta: meta?.toJSON()
        )
        guard let folder = ChatFolder(json: raw) else {
            throw FolderError.invalidResponse
        }
        return folder
    }

    // MARK: - Rename (convenience)

    /// Renames a folder, returning the updated model.
    func renameFolder(id: String, name: String) async throws -> ChatFolder {
        return try await updateFolder(id: id, name: name)
    }

    // MARK: - Delete

    /// Deletes a folder by ID.
    /// When `deleteContents` is true, also deletes all chats inside the folder.
    func deleteFolder(id: String, deleteContents: Bool = false) async throws {
        try await apiClient.deleteFolder(id: id, deleteContents: deleteContents)
    }

    // MARK: - Move Chat

    /// Moves a conversation into a folder (or removes it from any folder
    /// when `folderId` is `nil`).
    func moveChat(conversationId: String, to folderId: String?) async throws {
        try await apiClient.moveConversationToFolder(
            conversationId: conversationId,
            folderId: folderId
        )
    }

    // MARK: - Move Folder (reparent)

    /// Moves a folder under a new parent (or to root when `parentId` is nil).
    func moveFolderParent(id: String, parentId: String?) async throws {
        try await apiClient.moveFolderParent(id: id, parentId: parentId)
    }

    // MARK: - Expand / Collapse (debounced)

    /// Tracks the last synced expanded state per folder to avoid redundant calls.
    private var lastSyncedExpanded: [String: Bool] = [:]

    /// Schedules a debounced server sync for the expanded state of a folder.
    /// Skips the API call entirely if the state hasn't actually changed from
    /// the last successfully synced value.
    @discardableResult
    func syncExpanded(folderId: String, expanded: Bool) -> Bool {
        // Cancel any pending sync for this folder
        expandSyncTasks[folderId]?.cancel()

        // Schedule a debounced fire-and-forget sync (1 second debounce to avoid spam)
        expandSyncTasks[folderId] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            // Skip if the state hasn't changed since last sync
            if self.lastSyncedExpanded[folderId] == expanded { return }

            do {
                try await self.apiClient.setFolderExpanded(id: folderId, expanded: expanded)
                self.lastSyncedExpanded[folderId] = expanded
            } catch {
                // Non-critical — local UI state is already correct
            }
        }

        return expanded
    }
}

// MARK: - Errors

enum FolderError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unexpected response for the folder operation."
        }
    }
}
