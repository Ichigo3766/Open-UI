import SwiftUI

/// Full-screen sheet showing all of the user's currently shared conversations.
/// Supports copy link, revoke (single), pull-to-refresh, and infinite scroll pagination.
struct SharedChatsView: View {
    @State private var viewModel = SharedChatsViewModel()
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    // Chat preview state
    @State private var previewConversation: Conversation?
    @State private var isLoadingPreview = false
    @State private var previewError: String?
    @State private var showPreview = false

    var body: some View {
        NavigationStack {
            ZStack {
                mainContent
                    .background(theme.background)

                // Toast overlay
                if viewModel.showToast, let msg = viewModel.toastMessage {
                    VStack {
                        Spacer()
                        toastView(msg)
                            .padding(.bottom, Spacing.xl)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .navigationTitle("Shared Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Revoke confirmation dialog
            .confirmationDialog(
                "Revoke Share Link",
                isPresented: .init(
                    get: { viewModel.confirmingUnshareConversation != nil },
                    set: { if !$0 { viewModel.confirmingUnshareConversation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Revoke Link", role: .destructive) {
                    if let conv = viewModel.confirmingUnshareConversation {
                        viewModel.unshareConversation(conv)
                    }
                }
                Button("Cancel", role: .cancel) {
                    viewModel.confirmingUnshareConversation = nil
                }
            } message: {
                Text("Anyone with the link will no longer be able to view \"\(viewModel.confirmingUnshareConversation?.title ?? "this chat")\".")
            }
            // Chat preview sheet
            .sheet(isPresented: $showPreview) {
                chatPreviewSheet
            }
            .task {
                if let apiClient = dependencies.apiClient {
                    viewModel.configure(apiClient: apiClient)
                }
                viewModel.loadSharedChats()
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch viewModel.viewState {
        case .loading:
            skeletonList
        case .empty:
            emptyState
        case .error(let msg):
            ErrorStateView(
                message: "Failed to Load",
                detail: msg,
                onRetry: { viewModel.loadSharedChats() }
            )
        case .content:
            chatList
        }
    }

    // MARK: - Chat List

    private var chatList: some View {
        List {
            ForEach(viewModel.conversations) { conversation in
                SharedChatRow(
                    conversation: conversation,
                    serverBaseURL: dependencies.apiClient?.baseURL ?? "",
                    isUnsharing: viewModel.unsharingIds.contains(conversation.id),
                    onCopyLink: {
                        viewModel.copyShareLink(
                            for: conversation,
                            serverBaseURL: dependencies.apiClient?.baseURL ?? ""
                        )
                    },
                    onRevoke: {
                        viewModel.confirmingUnshareConversation = conversation
                    },
                    onTap: { openPreview(for: conversation) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(theme.background)
                .listRowSeparator(.visible)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        viewModel.confirmingUnshareConversation = conversation
                    } label: {
                        Label("Revoke", systemImage: "link.badge.minus")
                    }
                    .tint(theme.error)
                }
                .contextMenu {
                    Button {
                        openPreview(for: conversation)
                    } label: {
                        Label("Open Preview", systemImage: "eye")
                    }
                    Button {
                        viewModel.copyShareLink(
                            for: conversation,
                            serverBaseURL: dependencies.apiClient?.baseURL ?? ""
                        )
                    } label: {
                        Label("Copy Share Link", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        viewModel.confirmingUnshareConversation = conversation
                    } label: {
                        Label("Revoke Share Link", systemImage: "link.badge.minus")
                    }
                }
                .onAppear {
                    // Infinite scroll: trigger next page when last item appears
                    if conversation.id == viewModel.conversations.last?.id {
                        Task { viewModel.loadNextPage() }
                    }
                }
            }

            // Pagination footer
            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .listRowBackground(theme.background)
                .listRowSeparator(.hidden)
                .padding(.vertical, Spacing.sm)
                .accessibilityLabel("Loading more shared chats")
            }
        }
        .listStyle(.plain)
        .refreshable {
            viewModel.loadSharedChats()
        }
    }

    // MARK: - Skeleton Loading

    private var skeletonList: some View {
        List {
            ForEach(0..<5, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    SkeletonLoader(height: 16)
                    SkeletonLoader(width: 160, height: 13)
                    HStack(spacing: Spacing.sm) {
                        SkeletonLoader(width: 88, height: 28, cornerRadius: CornerRadius.pill)
                        SkeletonLoader(width: 72, height: 28, cornerRadius: CornerRadius.pill)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.vertical, Spacing.sm + 2)
                .listRowInsets(EdgeInsets())
                .listRowBackground(theme.background)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading shared chats")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "link.circle",
            title: "No Shared Chats",
            description: "Chats you share will appear here. Share a chat from the context menu in your chat list."
        )
    }

    // MARK: - Chat Preview Sheet

    private var chatPreviewSheet: some View {
        NavigationStack {
            Group {
                if isLoadingPreview {
                    VStack(spacing: Spacing.md) {
                        ProgressView().controlSize(.large)
                        Text("Loading chat…")
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = previewError {
                    ErrorStateView(
                        message: "Couldn't Load Chat",
                        detail: error,
                        onRetry: nil
                    )
                } else if let conv = previewConversation {
                    if let apiClient = dependencies.apiClient {
                        SharedChatReadOnlyView(
                            conversation: conv,
                            serverBaseURL: apiClient.baseURL,
                            apiClient: apiClient
                        )
                    }
                }
            }
            .background(theme.background)
            .navigationTitle(previewConversation?.title ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showPreview = false }
                }
                // Quick copy link from preview
                if let conv = previewConversation,
                   let apiClient = dependencies.apiClient {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.copyShareLink(
                                for: conv,
                                serverBaseURL: apiClient.baseURL
                            )
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .scaledFont(size: 14, weight: .medium)
                        }
                        .accessibilityLabel("Copy share link")
                    }
                }
            }
        }
        .themed()
    }

    // MARK: - Toast

    private func toastView(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 13)
            Text(message)
                .scaledFont(size: 13, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
    }

    // MARK: - Helpers

    private func openPreview(for conversation: Conversation) {
        guard let shareId = conversation.shareId, !shareId.isEmpty else {
            // Fallback: fetch the full conversation directly
            openPreviewDirect(for: conversation)
            return
        }
        isLoadingPreview = true
        previewError = nil
        showPreview = true
        Task {
            do {
                guard let apiClient = dependencies.apiClient else { return }
                previewConversation = try await apiClient.getSharedConversation(shareId: shareId)
            } catch {
                previewError = "Could not load the shared chat. The link may be broken."
            }
            isLoadingPreview = false
        }
    }

    private func openPreviewDirect(for conversation: Conversation) {
        isLoadingPreview = true
        previewError = nil
        showPreview = true
        Task {
            do {
                guard let apiClient = dependencies.apiClient else { return }
                previewConversation = try await apiClient.getConversation(id: conversation.id)
            } catch {
                previewError = "Could not load this chat."
            }
            isLoadingPreview = false
        }
    }
}
