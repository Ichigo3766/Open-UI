import SwiftUI

/// Sheet for sharing a chat conversation.
///
/// **State 1 — First share:** Shows info message and "Copy Link" button.
/// Calls POST /api/v1/chats/{id}/share, fetches the share_id, builds the link, and copies to clipboard.
///
/// **State 2 — Already shared:** Shows "You have shared this chat before." message with
/// tappable "before" (opens shared chat in-app) and "delete this link" (revokes the link).
/// Button becomes "Update and Copy Link" which regenerates a new share link.
struct ShareChatSheet: View {
    let conversation: Conversation
    let apiClient: APIClient
    let serverBaseURL: String

    /// Called when the share_id is updated so the parent can update its local state.
    var onShareIdUpdated: ((String?) -> Void)?

    /// Called when the user clones the shared chat — parent should navigate to it.
    var onClone: ((Conversation) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    /// Current share ID — may be already set (conversation.shareId) or freshly generated.
    @State private var currentShareId: String?

    /// Whether the share API call is in progress.
    @State private var isLoading = false

    /// Whether the unshare (delete link) API call is in progress.
    @State private var isUnsharing = false

    /// Whether the "Copied!" toast is showing.
    @State private var showCopiedToast = false

    /// Whether to show the shared chat detail view in-app.
    @State private var showSharedChatDetail = false

    /// The fetched shared conversation (for in-app preview).
    @State private var sharedConversation: Conversation?

    /// Whether loading the shared chat detail is in progress.
    @State private var isLoadingSharedChat = false

    /// Error message if something goes wrong.
    @State private var errorMessage: String?

    private var isAlreadyShared: Bool {
        currentShareId != nil && !(currentShareId?.isEmpty ?? true)
    }

    private var shareURL: String? {
        guard let shareId = currentShareId, !shareId.isEmpty else { return nil }
        let base = serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/s/\(shareId)"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Message
                messageBody

                if let error = errorMessage {
                    Text(error)
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.error)
                        .padding(.top, -Spacing.sm)
                }

                Spacer()

                // Action button
                actionButton
            }
            .padding(Spacing.lg)
            .navigationTitle("Share Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay(alignment: .top) {
                if showCopiedToast { copiedToastView }
            }
        }
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .onAppear {
            currentShareId = conversation.shareId
        }
        .sheet(isPresented: $showSharedChatDetail) {
            sharedChatDetailSheet
        }
    }

    // MARK: - Message Body

    @ViewBuilder
    private var messageBody: some View {
        if isAlreadyShared {
            // "You have shared this chat before. Click here to delete this link and create a new shared link."
            alreadySharedMessage
        } else {
            // "Messages you send after creating your link won't be shared. ..."
            Text("Messages you send after creating your link won't be shared. Users with the URL will be able to view the shared chat.")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textSecondary)
                .lineSpacing(3)
        }
    }

    private var alreadySharedMessage: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Line 1: "You have shared this chat [before]."
            HStack(spacing: 0) {
                Text("You have shared this chat ")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textSecondary)
                Text("before")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.brandPrimary)
                    .underline()
                    .onTapGesture { openSharedChatInApp() }
                Text(".")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textSecondary)
            }

            // Line 2: "Click here to [delete this link] and create a new shared link."
            HStack(spacing: 0) {
                Text("Click here to ")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textSecondary)
                Text("delete this link")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.error)
                    .underline()
                    .onTapGesture { Task { await deleteLinkAction() } }
                Text(" and create a new shared link.")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button {
            Task { await copyLinkAction() }
        } label: {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.textInverse)
                } else {
                    Image(systemName: "link")
                }
                Text(isAlreadyShared ? "Update and Copy Link" : "Copy Link")
                    .scaledFont(size: 16, weight: .semibold)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(theme.textInverse)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm + 2)
            .background(
                isLoading
                    ? theme.textPrimary.opacity(0.5)
                    : theme.textPrimary
            )
            .clipShape(Capsule())
        }
        .disabled(isLoading || isUnsharing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Shared Chat Detail Sheet

    private var sharedChatDetailSheet: some View {
        NavigationStack {
            Group {
                if isLoadingSharedChat {
                    VStack(spacing: Spacing.md) {
                        ProgressView().controlSize(.large)
                        Text("Loading shared chat…")
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let conv = sharedConversation {
                    SharedChatReadOnlyView(
                        conversation: conv,
                        serverBaseURL: serverBaseURL,
                        apiClient: apiClient,
                        onClone: { cloned in
                            showSharedChatDetail = false
                            dismiss()
                            onClone?(cloned)
                        }
                    )
                } else {
                    VStack(spacing: Spacing.md) {
                        Image(systemName: "exclamationmark.triangle")
                            .scaledFont(size: 36)
                            .foregroundStyle(theme.error)
                        Text("Could not load the shared chat.")
                            .scaledFont(size: 15)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Shared Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showSharedChatDetail = false }
                }
            }
        }
        .themed()
    }

    // MARK: - Copied Toast

    private var copiedToastView: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill").scaledFont(size: 13)
            Text("Link copied!").scaledFont(size: 13, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
        .padding(.top, Spacing.md)
        .transition(.toastTransition)
        .animation(MicroAnimation.gentle, value: showCopiedToast)
    }

    // MARK: - Actions

    /// Calls POST share (deleting existing link first if updating), builds URL, copies to clipboard.
    private func copyLinkAction() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // If already shared, delete the existing link first so the server generates a fresh ID
            if isAlreadyShared {
                try await apiClient.unshareConversation(id: conversation.id)
            }

            // POST share → returns new share_id
            let shareId = try await apiClient.shareConversation(id: conversation.id)
            guard let shareId, !shareId.isEmpty else {
                // Fallback: fetch the chat to get the freshly assigned share_id
                let updated = try await apiClient.getConversation(id: conversation.id)
                guard let fetchedShareId = updated.shareId, !fetchedShareId.isEmpty else {
                    errorMessage = "Failed to get share link."
                    return
                }
                currentShareId = fetchedShareId
                onShareIdUpdated?(fetchedShareId)
                copyShareURL(fetchedShareId)
                return
            }

            currentShareId = shareId
            onShareIdUpdated?(shareId)
            copyShareURL(shareId)
        } catch {
            errorMessage = "Failed to create share link."
        }
    }

    /// Calls DELETE share to revoke the current link.
    private func deleteLinkAction() async {
        isUnsharing = true
        errorMessage = nil
        defer { isUnsharing = false }

        do {
            try await apiClient.unshareConversation(id: conversation.id)
            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                currentShareId = nil
            }
            onShareIdUpdated?(nil)
            Haptics.notify(.success)
        } catch {
            errorMessage = "Failed to delete share link."
        }
    }

    /// Opens the shared chat in-app using the share ID.
    private func openSharedChatInApp() {
        guard let shareId = currentShareId, !shareId.isEmpty else { return }
        isLoadingSharedChat = true
        showSharedChatDetail = true

        Task {
            do {
                let conv = try await apiClient.getSharedConversation(shareId: shareId)
                sharedConversation = conv
            } catch {
                // Leave sharedConversation nil — the sheet shows an error state
            }
            isLoadingSharedChat = false
        }
    }

    /// Copies the share URL to clipboard and shows the toast.
    private func copyShareURL(_ shareId: String) {
        let base = serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlString = "\(base)/s/\(shareId)"
        UIPasteboard.general.string = urlString
        Haptics.notify(.success)

        withAnimation(MicroAnimation.gentle) { showCopiedToast = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(MicroAnimation.gentle) { showCopiedToast = false }
        }
    }
}

// MARK: - Already Shared Tap Overlay

/// Invisible overlay that provides separate tap zones for "before" and "delete this link"
/// within the already-shared message text.
private struct AlreadySharedTapOverlay: View {
    let onBeforeTap: () -> Void
    let onDeleteTap: () -> Void

    var body: some View {
        // Rough horizontal split — left ~40% = "before", right ~40% = "delete this link"
        // This is a reasonable approximation given the text layout
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onBeforeTap() }
                .frame(maxWidth: .infinity)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDeleteTap() }
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Shared Chat Read-Only View

/// A read-only view of a shared chat, with a "Clone to My Chats" button.
/// Reuses the same rendering as AdminChatDetailView.
struct SharedChatReadOnlyView: View {
    let conversation: Conversation
    let serverBaseURL: String
    let apiClient: APIClient
    var onClone: ((Conversation) -> Void)?

    @Environment(\.theme) private var theme
    @State private var isCloning = false
    @State private var showCloneConfirmation = false
    @State private var showCopiedToast = false

    var body: some View {
        VStack(spacing: 0) {
            chatContent
        }
        .background(theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCloneConfirmation = true
                } label: {
                    if isCloning {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text("Clone")
                                .scaledFont(size: 14, weight: .medium)
                        }
                        .foregroundStyle(theme.brandPrimary)
                    }
                }
                .disabled(isCloning)
            }
        }
        .confirmationDialog(
            "Clone Chat",
            isPresented: $showCloneConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clone to My Chats") {
                Task { await cloneChat() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will create a copy of this chat in your own chat list.")
        }
        .overlay(alignment: .top) {
            if showCopiedToast { copiedToastView }
        }
    }

    private var chatContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Header
                chatInfoHeader

                // Messages
                ForEach(conversation.messages) { message in
                    messageRow(message: message)
                }
            }
            .padding(.bottom, Spacing.lg)
        }
    }

    private var chatInfoHeader: some View {
        HStack(spacing: Spacing.md) {
            infoPill(icon: "bubble.left.and.text.bubble.right",
                     text: "\(conversation.messages.count) messages")
            if let model = conversation.model {
                infoPill(icon: "cpu", text: modelShortName(model))
            }
            infoPill(icon: "calendar", text: conversation.createdAt.chatTimestamp)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, Spacing.md)
    }

    private func infoPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).scaledFont(size: 10, weight: .medium)
            Text(text).scaledFont(size: 11, weight: .medium)
        }
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func messageRow(message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 0) {
            if message.role == .assistant {
                HStack(spacing: Spacing.sm) {
                    ModelAvatar(size: 22, label: message.model ?? conversation.model)
                    Text(modelShortName(message.model ?? conversation.model ?? "Assistant"))
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, Spacing.sm)
                .padding(.bottom, 4)
            }

            ChatMessageBubble(
                role: message.role,
                showTimestamp: false,
                timestamp: message.timestamp
            ) {
                if message.role == .user {
                    Text(message.content)
                        .scaledFont(size: 16)
                        .lineSpacing(3)
                } else {
                    AssistantMessageContent(
                        content: message.content,
                        isStreaming: false
                    )
                }
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                    Haptics.notify(.success)
                    withAnimation(MicroAnimation.gentle) { showCopiedToast = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(MicroAnimation.gentle) { showCopiedToast = false }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if message.role == .assistant {
                Text(message.timestamp.chatTimestamp)
                    .scaledFont(size: 10)
                    .foregroundStyle(theme.textTertiary.opacity(0.6))
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.top, 2)
            }
        }
    }

    private var copiedToastView: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.on.doc.fill").scaledFont(size: 12)
            Text("Copied to clipboard").scaledFont(size: 12, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
        .padding(.top, Spacing.md)
        .transition(.toastTransition)
    }

    private func cloneChat() async {
        isCloning = true
        do {
            // Use the conversation's ID directly to clone
            let cloned = try await apiClient.cloneConversation(id: conversation.id)
            onClone?(cloned)
        } catch {
            // Silently fail — user stays on screen
        }
        isCloning = false
    }

    private func modelShortName(_ fullName: String) -> String {
        if let lastSlash = fullName.lastIndex(of: "/") {
            return String(fullName[fullName.index(after: lastSlash)...])
        }
        if let lastColon = fullName.lastIndex(of: ":") {
            return String(fullName[..<lastColon])
        }
        return fullName
    }
}
