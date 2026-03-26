import SwiftUI

/// Full-screen sheet showing the user's archived conversations.
/// Supports search, restore (single & bulk), permanent delete, pull-to-refresh,
/// and infinite scroll pagination.
struct ArchivedChatsView: View {
    @State private var viewModel = ArchivedChatsViewModel()
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    // Chat preview state
    @State private var previewConversation: Conversation?
    @State private var isLoadingPreview = false
    @State private var previewError: String?
    @State private var showPreview = false

    // Confirmation dialogs
    @State private var deletingConversation: Conversation?

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
            .navigationTitle("Archived Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Unarchive all confirmation
            .confirmationDialog(
                "Restore All Chats",
                isPresented: $viewModel.showUnarchiveAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore All") {
                    viewModel.unarchiveAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will restore all \(viewModel.conversations.count) archived chats to your main list.")
            }
            // Delete single confirmation
            .confirmationDialog(
                "Delete \"\(deletingConversation?.title ?? "")\"?",
                isPresented: .init(
                    get: { deletingConversation != nil },
                    set: { if !$0 { deletingConversation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Permanently", role: .destructive) {
                    if let conv = deletingConversation {
                        deletingConversation = nil
                        viewModel.deleteConversation(conv)
                    }
                }
                Button("Cancel", role: .cancel) { deletingConversation = nil }
            } message: {
                Text("This will permanently delete this chat. This action cannot be undone.")
            }
            // Chat preview sheet
            .sheet(isPresented: $showPreview) {
                chatPreviewSheet
            }
            .task {
                if let apiClient = dependencies.apiClient {
                    viewModel.configure(apiClient: apiClient)
                }
                viewModel.loadArchivedChats()
            }
            .onChange(of: viewModel.searchText) { viewModel.triggerSearch() }
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
        case .emptySearch:
            emptySearchState
        case .error(let msg):
            ErrorStateView(
                message: "Failed to Load",
                detail: msg,
                onRetry: { viewModel.loadArchivedChats() }
            )
        case .content:
            chatList
        }
    }

    // MARK: - Chat List

    private var chatList: some View {
        List {
            ForEach(viewModel.conversations) { conversation in
                ArchivedChatRow(
                    conversation: conversation,
                    isRestoring: viewModel.restoringIds.contains(conversation.id),
                    isDeleting: viewModel.deletingIds.contains(conversation.id),
                    onRestore: { viewModel.restoreConversation(conversation) },
                    onDelete: { deletingConversation = conversation },
                    onTap: { openPreview(for: conversation) }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(theme.background)
                .listRowSeparator(.visible)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        viewModel.restoreConversation(conversation)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward.circle.fill")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingConversation = conversation
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        openPreview(for: conversation)
                    } label: {
                        Label("Open", systemImage: "eye")
                    }
                    Button {
                        viewModel.restoreConversation(conversation)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deletingConversation = conversation
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
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
                .accessibilityLabel("Loading more archived chats")
            }
        }
        .listStyle(.plain)
        .searchable(text: $viewModel.searchText, prompt: "Search archived chats")
        .refreshable {
            viewModel.loadArchivedChats()
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.conversations.isEmpty && !viewModel.isLoading {
                unarchiveAllBar
            }
        }
    }

    // MARK: - Unarchive All Bottom Bar

    private var unarchiveAllBar: some View {
        Button {
            viewModel.showUnarchiveAllConfirmation = true
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .scaledFont(size: 15, weight: .medium)
                Text("Restore All (\(viewModel.conversations.count))")
                    .scaledFont(size: 15, weight: .medium)
            }
            .foregroundStyle(theme.brandPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm + 2)
            .background(.ultraThinMaterial)
            .overlay(
                Rectangle()
                    .fill(theme.divider)
                    .frame(height: 0.5),
                alignment: .top
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restore all archived chats")
    }

    // MARK: - Skeleton Loading

    private var skeletonList: some View {
        List {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    SkeletonLoader(height: 16)
                    SkeletonLoader(width: 140, height: 13)
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
        .accessibilityLabel("Loading archived chats")
    }

    // MARK: - Empty States

    private var emptyState: some View {
        EmptyStateView(
            icon: "archivebox",
            title: "No Archived Chats",
            description: "Chats you archive will appear here. Archive a chat from its context menu in your chat list."
        )
        .searchable(text: $viewModel.searchText, prompt: "Search archived chats")
    }

    private var emptySearchState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 40, weight: .light)
                .foregroundStyle(theme.textTertiary.opacity(0.6))
            VStack(spacing: Spacing.sm) {
                Text("No Results")
                    .scaledFont(size: 20, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text("No archived chats match \"\(viewModel.searchText)\".")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $viewModel.searchText, prompt: "Search archived chats")
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
        isLoadingPreview = true
        previewError = nil
        showPreview = true
        Task {
            do {
                guard let apiClient = dependencies.apiClient else { return }
                previewConversation = try await apiClient.getConversation(id: conversation.id)
            } catch {
                previewError = "Could not load this chat. It may have been deleted."
            }
            isLoadingPreview = false
        }
    }
}
