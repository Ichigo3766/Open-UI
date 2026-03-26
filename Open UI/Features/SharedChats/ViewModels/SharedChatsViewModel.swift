import Foundation
import SwiftUI
import UIKit
import os.log

/// Manages the shared chats list — pagination, unshare (revoke), and link copying.
@MainActor @Observable
final class SharedChatsViewModel {

    // MARK: - State

    var conversations: [Conversation] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var hasMorePages = true
    var currentPage = 1

    /// ID pending unshare confirmation (drives the confirmation dialog).
    var confirmingUnshareConversation: Conversation?

    /// IDs currently being unshared (shows spinner on row).
    var unsharingIds: Set<String> = []

    /// Inline toast message.
    var toastMessage: String?
    var showToast = false

    // MARK: - View State

    enum ViewState {
        case loading
        case empty
        case error(String)
        case content
    }

    var viewState: ViewState {
        if isLoading && conversations.isEmpty { return .loading }
        if let error = errorMessage, conversations.isEmpty { return .error(error) }
        if conversations.isEmpty { return .empty }
        return .content
    }

    // MARK: - Private

    private var apiClient: APIClient?
    private var paginationTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.openui", category: "SharedChatsVM")

    // MARK: - Setup

    func configure(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Load

    /// Loads the first page of shared chats. Resets all pagination state.
    func loadSharedChats() {
        paginationTask?.cancel()
        isLoading = true
        errorMessage = nil
        currentPage = 1
        hasMorePages = true

        Task {
            do {
                guard let apiClient else { return }
                let results = try await apiClient.getSharedChats(page: 1)
                conversations = results
                hasMorePages = !results.isEmpty
                errorMessage = nil
            } catch {
                logger.error("Failed to load shared chats: \(error.localizedDescription)")
                errorMessage = errorDescription(for: error)
            }
            isLoading = false
        }
    }

    /// Loads the next page of shared chats (infinite scroll trigger).
    func loadNextPage() {
        guard hasMorePages, !isLoadingMore, !isLoading else { return }

        paginationTask?.cancel()
        paginationTask = Task {
            isLoadingMore = true
            let nextPage = currentPage + 1
            do {
                guard let apiClient else { return }
                let results = try await apiClient.getSharedChats(page: nextPage)
                if results.isEmpty {
                    hasMorePages = false
                } else {
                    let newItems = results.filter { newConv in
                        !conversations.contains(where: { $0.id == newConv.id })
                    }
                    conversations.append(contentsOf: newItems)
                    currentPage = nextPage
                }
            } catch {
                logger.error("Failed to load shared chats page \(nextPage): \(error.localizedDescription)")
            }
            isLoadingMore = false
        }
    }

    // MARK: - Unshare (Revoke)

    /// Optimistically revokes the share link — removes from list, calls API, reverts on failure.
    func unshareConversation(_ conv: Conversation) {
        guard !unsharingIds.contains(conv.id) else { return }
        confirmingUnshareConversation = nil
        unsharingIds.insert(conv.id)

        let originalIndex = conversations.firstIndex(where: { $0.id == conv.id })
        withAnimation(.easeInOut(duration: 0.25)) {
            conversations.removeAll { $0.id == conv.id }
        }

        Task {
            do {
                try await apiClient?.unshareConversation(id: conv.id)
                unsharingIds.remove(conv.id)
                // Notify main chat list so the shareId is cleared there too
                NotificationCenter.default.post(name: .conversationListNeedsRefresh, object: nil)
                Haptics.notify(.success)
                showTemporaryToast("Share link revoked")
            } catch {
                // Rollback
                unsharingIds.remove(conv.id)
                withAnimation(.easeInOut(duration: 0.25)) {
                    if let idx = originalIndex, idx <= conversations.count {
                        conversations.insert(conv, at: idx)
                    } else {
                        conversations.insert(conv, at: 0)
                    }
                }
                Haptics.notify(.error)
                showTemporaryToast("Failed to revoke share link")
                logger.error("Failed to unshare conversation \(conv.id): \(error.localizedDescription)")
            }
        }
    }

    /// Builds the share URL for a conversation.
    func shareURL(for conv: Conversation, serverBaseURL: String) -> String? {
        guard let shareId = conv.shareId, !shareId.isEmpty else { return nil }
        let base = serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/s/\(shareId)"
    }

    /// Copies the share link to the clipboard and shows a toast.
    func copyShareLink(for conv: Conversation, serverBaseURL: String) {
        guard let urlString = shareURL(for: conv, serverBaseURL: serverBaseURL) else { return }
        UIPasteboard.general.string = urlString
        Haptics.notify(.success)
        showTemporaryToast("Link copied!")
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
            return "Failed to load shared chats. Please try again."
        }
    }
}
