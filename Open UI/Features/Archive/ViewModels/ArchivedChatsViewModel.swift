import Foundation
import SwiftUI
import os.log

/// Manages the archived chats list — pagination, search, restore, and delete.
@MainActor @Observable
final class ArchivedChatsViewModel {

    // MARK: - State

    var conversations: [Conversation] = []
    var isLoading = false
    var isLoadingMore = false
    var searchText = ""
    var errorMessage: String?
    var hasMorePages = true
    var currentPage = 1

    /// IDs currently being restored (shows spinner on row, prevents double-tap).
    var restoringIds: Set<String> = []

    /// IDs currently being deleted (shows spinner on row).
    var deletingIds: Set<String> = []

    /// Controls the "Unarchive All" confirmation dialog.
    var showUnarchiveAllConfirmation = false

    /// Inline toast message (success/failure feedback).
    var toastMessage: String?
    var showToast = false

    // MARK: - View State

    enum ViewState {
        case loading
        case empty
        case emptySearch
        case error(String)
        case content
    }

    var viewState: ViewState {
        if isLoading && conversations.isEmpty { return .loading }
        if let error = errorMessage, conversations.isEmpty { return .error(error) }
        if conversations.isEmpty && !searchText.isEmpty { return .emptySearch }
        if conversations.isEmpty { return .empty }
        return .content
    }

    // MARK: - Private

    private var apiClient: APIClient?
    private var searchTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.openui", category: "ArchivedChatsVM")

    // MARK: - Setup

    func configure(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Load

    /// Loads the first page of archived chats. Resets all pagination state.
    func loadArchivedChats() {
        searchTask?.cancel()
        paginationTask?.cancel()

        isLoading = true
        errorMessage = nil
        currentPage = 1
        hasMorePages = true

        Task {
            do {
                guard let apiClient else { return }
                let query = searchText.count >= 2 ? searchText : nil
                let results = try await apiClient.getArchivedChats(page: 1, query: query)
                conversations = results
                hasMorePages = !results.isEmpty
                errorMessage = nil
            } catch {
                logger.error("Failed to load archived chats: \(error.localizedDescription)")
                errorMessage = errorDescription(for: error)
            }
            isLoading = false
        }
    }

    /// Loads the next page of archived chats (infinite scroll trigger).
    func loadNextPage() {
        guard hasMorePages, !isLoadingMore, !isLoading else { return }

        paginationTask?.cancel()
        paginationTask = Task {
            isLoadingMore = true
            let nextPage = currentPage + 1
            do {
                guard let apiClient else { return }
                let query = searchText.count >= 2 ? searchText : nil
                let results = try await apiClient.getArchivedChats(page: nextPage, query: query)
                if results.isEmpty {
                    hasMorePages = false
                } else {
                    let newItems = results.filter { newConv in
                        !conversations.contains(where: { $0.id == newConv.id })
                    }
                    conversations.append(contentsOf: newItems)
                    currentPage = nextPage
                    hasMorePages = !results.isEmpty
                }
            } catch {
                logger.error("Failed to load page \(nextPage): \(error.localizedDescription)")
            }
            isLoadingMore = false
        }
    }

    // MARK: - Search

    /// Triggers a debounced server-side search. Minimum 2 characters.
    func triggerSearch() {
        searchTask?.cancel()
        paginationTask?.cancel()

        if searchText.isEmpty {
            loadArchivedChats()
            return
        }
        guard searchText.count >= 2 else { return }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isLoading = true
            currentPage = 1
            hasMorePages = true
            do {
                guard let apiClient else { return }
                let results = try await apiClient.getArchivedChats(page: 1, query: searchText)
                conversations = results
                hasMorePages = !results.isEmpty
                errorMessage = nil
            } catch {
                if !Task.isCancelled {
                    logger.error("Search failed: \(error.localizedDescription)")
                }
            }
            if !Task.isCancelled {
                isLoading = false
            }
        }
    }

    // MARK: - Restore (Unarchive)

    /// Optimistically restores a single conversation — removes from list, calls API, reverts on failure.
    func restoreConversation(_ conv: Conversation) {
        guard !restoringIds.contains(conv.id) else { return }
        restoringIds.insert(conv.id)

        let originalIndex = conversations.firstIndex(where: { $0.id == conv.id })
        withAnimation(.easeInOut(duration: 0.25)) {
            conversations.removeAll { $0.id == conv.id }
        }

        Task {
            do {
                try await apiClient?.archiveConversation(id: conv.id, archived: false)
                restoringIds.remove(conv.id)
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                Haptics.notify(.success)
                showTemporaryToast("Chat restored")
            } catch {
                // Rollback — re-insert at original position
                restoringIds.remove(conv.id)
                withAnimation(.easeInOut(duration: 0.25)) {
                    if let idx = originalIndex, idx <= conversations.count {
                        conversations.insert(conv, at: idx)
                    } else {
                        conversations.insert(conv, at: 0)
                    }
                }
                Haptics.notify(.error)
                showTemporaryToast("Failed to restore chat")
                logger.error("Failed to restore conversation \(conv.id): \(error.localizedDescription)")
            }
        }
    }

    /// Unarchives all archived conversations.
    func unarchiveAll() {
        guard let apiClient else { return }
        isLoading = true
        let previous = conversations
        withAnimation { conversations.removeAll() }

        Task {
            do {
                try await apiClient.unarchiveAllConversations()
                isLoading = false
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                Haptics.notify(.success)
                showTemporaryToast("All chats restored")
            } catch {
                isLoading = false
                withAnimation { conversations = previous }
                Haptics.notify(.error)
                showTemporaryToast("Failed to restore all chats")
                logger.error("Failed to unarchive all: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Delete

    /// Permanently deletes a single archived conversation.
    func deleteConversation(_ conv: Conversation) {
        guard !deletingIds.contains(conv.id) else { return }
        deletingIds.insert(conv.id)

        let originalIndex = conversations.firstIndex(where: { $0.id == conv.id })
        withAnimation(.easeInOut(duration: 0.25)) {
            conversations.removeAll { $0.id == conv.id }
        }

        Task {
            do {
                try await apiClient?.deleteConversation(id: conv.id)
                deletingIds.remove(conv.id)
                Haptics.notify(.success)
            } catch {
                deletingIds.remove(conv.id)
                withAnimation(.easeInOut(duration: 0.25)) {
                    if let idx = originalIndex, idx <= conversations.count {
                        conversations.insert(conv, at: idx)
                    } else {
                        conversations.insert(conv, at: 0)
                    }
                }
                Haptics.notify(.error)
                showTemporaryToast("Failed to delete chat")
                logger.error("Failed to delete archived conversation \(conv.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Toast

    private func showTemporaryToast(_ message: String) {
        toastMessage = message
        withAnimation(.easeInOut(duration: 0.2)) { showToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.2)) { showToast = false }
        }
    }

    // MARK: - Error Helpers

    private func errorDescription(for error: Error) -> String {
        let apiError = APIError.from(error)
        switch apiError {
        case .networkError:
            return "Unable to connect. Check your internet connection."
        case .unauthorized, .tokenExpired:
            return "Your session has expired. Please sign in again."
        case .httpError(let code, _, _) where code >= 500:
            return "The server is experiencing issues. Please try again later."
        case .httpError(_, let msg, _):
            return msg ?? "Server error. Please try again."
        default:
            return "Failed to load archived chats. Please try again."
        }
    }
}
