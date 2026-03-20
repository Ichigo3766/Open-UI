import SwiftUI

/// Main view displaying the list of chat conversations.
///
/// Shows a **Folders** section at the top (collapsible, drag-and-drop),
/// pinned conversations in a dedicated section, and groups
/// unpinned conversations by recency.
///
/// Supports search, rename, delete, pin/unpin, archive, multi-select
/// bulk delete, and drag-and-drop to move chats between folders.
struct ChatListView: View {
    @State private var viewModel = ChatListViewModel()
    @Environment(AppRouter.self) private var router
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme

    // Folder sheet / rename state
    @State private var showCreateFolderSheet = false
    @State private var folderToRename: ChatFolder?

    // Share sheet state
    @State private var sharingConversation: Conversation?

    // Tracks whether the "Chats" header drop zone is highlighted
    @State private var chatsDropTargetActive: Bool = false

    var body: some View {
        @Bindable var router = router
        let folderVM = viewModel.folderViewModel
        let isEmpty = viewModel.conversations.isEmpty && folderVM.folders.isEmpty

        NavigationStack(path: $router.path) {
            Group {
                if viewModel.isLoading && viewModel.conversations.isEmpty {
                    loadingView
                } else if isEmpty && viewModel.errorMessage == nil {
                    emptyStateView
                } else if let error = viewModel.errorMessage, viewModel.conversations.isEmpty {
                    errorView(error)
                } else {
                    conversationList
                }
            }
            .navigationTitle(viewModel.isSelectionMode
                ? String(localized: "\(viewModel.selectedCount) Selected")
                : String(localized: "Chats")
            )
            .searchable(
                text: $viewModel.searchText,
                prompt: String(localized: "Search conversations")
            )
            .onChange(of: viewModel.searchText) { _, newValue in
                if newValue.count >= 2 {
                    viewModel.triggerSearch()
                }
            }
            .toolbar { toolbarContent }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .chatDetail(let conversationId):
                    ChatDetailView(
                        conversationId: conversationId,
                        viewModel: dependencies.activeChatStore.viewModel(for: conversationId)
                    )
                case .newChat:
                    ChatDetailView(
                        viewModel: dependencies.activeChatStore.viewModel(for: nil)
                    )
                case .notesList:
                    NotesListView()
                case .noteEditor(let noteId):
                    NoteEditorView(noteId: noteId)
                default:
                    EmptyView()
                }
            }
            .sheet(item: $router.presentedSheet) { route in
                switch route {
                case .settings:
                    SettingsView(
                        viewModel: dependencies.authViewModel,
                        appearanceManager: dependencies.appearanceManager
                    )
                case .voiceCall(let startNew):
                    VoiceCallView(
                        viewModel: dependencies.makeVoiceCallViewModel(),
                        startNewConversation: startNew
                    )
                default:
                    EmptyView()
                }
            }
            // Create folder sheet
            .sheet(isPresented: $showCreateFolderSheet) {
                createFolderSheet
            }
            // Rename folder sheet
            .sheet(item: $folderToRename) { folder in
                CreateFolderSheet(existingName: folder.name, onRename: { newName in
                    viewModel.folderViewModel.renameText = newName
                    Task { await viewModel.folderViewModel.commitRename() }
                })
            }
            // Share chat sheet
            .sheet(item: $sharingConversation) { conversation in
                if let apiClient = dependencies.apiClient {
                    ShareChatSheet(
                        conversation: conversation,
                        apiClient: apiClient,
                        serverBaseURL: apiClient.baseURL,
                        onShareIdUpdated: { shareId in
                            viewModel.updateShareId(for: conversation.id, shareId: shareId)
                        },
                        onClone: { cloned in
                            router.navigate(to: .chatDetail(conversationId: cloned.id))
                        }
                    )
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                }
            }
            .refreshable {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await viewModel.refreshConversations() }
                    group.addTask { await folderVM.loadFolders() }
                }
            }
            .task {
                if let manager = dependencies.conversationManager {
                    viewModel.configure(with: manager)
                }
                if let folderManager = dependencies.folderManager {
                    folderVM.configure(with: folderManager)
                }

                // Load conversations and folders in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await viewModel.loadConversations() }
                    group.addTask { await folderVM.loadFolders() }
                }

                dependencies.updateWidgetData(conversations: viewModel.conversations)
                ShortcutDonationService.donateContinueConversation()
            }
            // Rename conversation alert
            .alert(
                String(localized: "Rename Conversation"),
                isPresented: .init(
                    get: { viewModel.renamingConversation != nil },
                    set: { if !$0 { viewModel.renamingConversation = nil } }
                )
            ) {
                TextField(String(localized: "Title"), text: $viewModel.renameText)
                Button(String(localized: "Cancel"), role: .cancel) {
                    viewModel.renamingConversation = nil
                }
                Button(String(localized: "Save")) {
                    Task { await viewModel.commitRename() }
                }
            } message: {
                Text("Enter a new name for this conversation.")
            }
            // Rename folder alert (via FolderListViewModel)
            .alert(
                String(localized: "Rename Folder"),
                isPresented: .init(
                    get: { viewModel.folderViewModel.renamingFolder != nil },
                    set: { if !$0 { viewModel.folderViewModel.renamingFolder = nil } }
                )
            ) {
                TextField(
                    String(localized: "Folder Name"),
                    text: Bindable(viewModel.folderViewModel).renameText
                )
                Button(String(localized: "Cancel"), role: .cancel) {
                    viewModel.folderViewModel.renamingFolder = nil
                }
                Button(String(localized: "Rename")) {
                    Task { await viewModel.folderViewModel.commitRename() }
                }
            }
            // Single delete confirmation
            .destructiveConfirmation(
                isPresented: .init(
                    get: { viewModel.deletingConversation != nil },
                    set: { if !$0 { viewModel.deletingConversation = nil } }
                ),
                title: String(localized: "Delete Conversation"),
                message: String(localized: "This action cannot be undone."),
                destructiveTitle: String(localized: "Delete")
            ) {
                if let conversation = viewModel.deletingConversation {
                    Task { await viewModel.deleteConversation(id: conversation.id) }
                }
            }
            // Delete all confirmation
            .destructiveConfirmation(
                isPresented: $viewModel.showDeleteAllConfirmation,
                title: String(localized: "Delete All Chats"),
                message: String(localized: "This will permanently delete all your conversations. This action cannot be undone."),
                destructiveTitle: String(localized: "Delete All")
            ) {
                Task { await viewModel.deleteAllConversations() }
            }
            // Archive all confirmation
            .destructiveConfirmation(
                isPresented: $viewModel.showArchiveAllConfirmation,
                title: String(localized: "Archive All Chats"),
                message: String(localized: "This will archive all your conversations. You can unarchive them later from the web interface."),
                destructiveTitle: String(localized: "Archive All")
            ) {
                Task { await viewModel.archiveAllConversations() }
            }
            // Delete selected confirmation
            .destructiveConfirmation(
                isPresented: $viewModel.showDeleteSelectedConfirmation,
                title: String(localized: "Delete Selected Chats"),
                message: String(localized: "This will permanently delete \(viewModel.selectedCount) selected conversation(s). This action cannot be undone."),
                destructiveTitle: String(localized: "Delete")
            ) {
                Task { await viewModel.deleteSelectedConversations() }
            }
            // Bulk delete progress overlay
            .overlay {
                if viewModel.isDeletingBulk {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            ProgressView().controlSize(.large)
                            Text("Deleting…")
                                .scaledFont(size: 16)
                                .foregroundStyle(theme.textPrimary)
                        }
                        .padding(Spacing.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: AnimDuration.fast), value: viewModel.isDeletingBulk)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading
        ToolbarItem(placement: .topBarLeading) {
            if viewModel.isSelectionMode {
                Button { viewModel.exitSelectionMode() } label: {
                    Text("Cancel")
                }
                .accessibilityLabel(Text("Exit selection mode"))
            } else {
                Menu {
                    Button {
                        router.presentSheet(.settings)
                    } label: {
                        SwiftUI.Label(String(localized: "Settings"), systemImage: "gearshape")
                    }

                    Button {
                        router.navigate(to: .notesList)
                    } label: {
                        SwiftUI.Label(String(localized: "Notes"), systemImage: "note.text")
                    }

                    Divider()

                    if !viewModel.conversations.isEmpty {
                        Button { viewModel.toggleSelectionMode() } label: {
                            SwiftUI.Label(String(localized: "Select Chats"), systemImage: "checkmark.circle")
                        }
                    }

                    if !viewModel.conversations.isEmpty {
                        Button {
                            viewModel.showArchiveAllConfirmation = true
                        } label: {
                            SwiftUI.Label(String(localized: "Archive All Chats"), systemImage: "archivebox")
                        }

                        Button(role: .destructive) {
                            viewModel.showDeleteAllConfirmation = true
                        } label: {
                            SwiftUI.Label(String(localized: "Delete All Chats"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel(Text("Menu"))
            }
        }

        // Trailing
        ToolbarItemGroup(placement: .topBarTrailing) {
            if viewModel.isSelectionMode {
                Button {
                    if viewModel.selectedCount == viewModel.filteredConversations.count {
                        viewModel.selectedConversationIds.removeAll()
                    } else {
                        viewModel.selectAll()
                    }
                } label: {
                    Text(viewModel.selectedCount == viewModel.filteredConversations.count
                        ? String(localized: "Deselect All")
                        : String(localized: "Select All")
                    )
                }

                Button(role: .destructive) {
                    viewModel.showDeleteSelectedConfirmation = true
                } label: {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .disabled(viewModel.selectedCount == 0)
            } else {
                // New Folder button
                Button {
                    showCreateFolderSheet = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel(Text("New Folder"))
                .accessibilityHint(Text("Create a new folder to organise chats"))

                Button {
                    router.presentSheet(.voiceCall())
                } label: {
                    Image(systemName: "phone.fill")
                }
                .accessibilityLabel(Text("Voice Call"))

                Button {
                    router.navigate(to: .newChat)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel(Text("New Chat"))
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: Spacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonListItem(showAvatar: false)
            }
        }
        .padding(.top, Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityLabel(Text("Loading conversations"))
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView {
            SwiftUI.Label(
                String(localized: "No Conversations"),
                systemImage: "bubble.left.and.text.bubble.right"
            )
        } description: {
            Text("Start a new chat to begin.")
        } actions: {
            HStack(spacing: Spacing.md) {
                Button {
                    router.navigate(to: .newChat)
                } label: {
                    SwiftUI.Label(String(localized: "New Chat"), systemImage: "plus.bubble")
                }
                .buttonStyle(.borderedProminent)
                .pressEffect()

                Button {
                    router.presentSheet(.voiceCall(startNewConversation: true))
                } label: {
                    SwiftUI.Label(String(localized: "Voice Call"), systemImage: "phone.fill")
                }
                .buttonStyle(.bordered)
                .pressEffect()
            }
        }
    }

    // MARK: - Create Folder Sheet (extracted to help type-checker)

    private var createFolderSheet: some View {
        CreateFolderSheet(apiClient: dependencies.apiClient) { name, data, meta in
            let folderVM = viewModel.folderViewModel
            Task { await folderVM.createFolder(name: name, parentId: nil, data: data, meta: meta) }
        }
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        ErrorStateView(
            message: String(localized: "Something Went Wrong"),
            detail: message,
            onRetry: { Task { await viewModel.loadConversations() } }
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        let folderVM = viewModel.folderViewModel

        return List {
            // ── FOLDERS SECTION ─────────────────────────────────────
            FolderSectionView(
                folderVM: folderVM,
                allConversations: viewModel.conversations,
                onNavigateToChat: { id in
                    router.navigate(to: .chatDetail(conversationId: id))
                    SharedDataService.shared.saveLastActiveConversationId(id)
                },
                onMoveChat: { conversation, targetFolderId in
                    Task {
                        // Update folderId locally in the conversations array
                        if let idx = viewModel.conversations.firstIndex(where: { $0.id == conversation.id }) {
                            viewModel.conversations[idx].folderId = targetFolderId
                        }
                        await folderVM.moveChat(conversation: conversation, to: targetFolderId)
                    }
                },
                onDeleteChat: { chatId in
                    Task {
                        await viewModel.deleteConversation(id: chatId)
                        // Also remove from the folder's local chat list
                        for idx in folderVM.folders.indices {
                            folderVM.folders[idx].chats.removeAll { $0.id == chatId }
                        }
                    }
                },
                onTogglePin: { conversation in
                    Task { await viewModel.togglePin(conversation: conversation) }
                }
            )

            // ── CHATS SECTION HEADER (acts as a drop zone to remove from folder) ─
            if !viewModel.filteredConversations.isEmpty || !viewModel.pinnedConversations.isEmpty {
                Section {
                    EmptyView()
                } header: {
                    chatsDropHeader(folderVM: folderVM)
                }
                .listRowInsets(.init())
                .frame(height: 0)
            }

            // ── PINNED SECTION ───────────────────────────────────────
            if !viewModel.pinnedConversations.isEmpty {
                Section {
                    ForEach(viewModel.pinnedConversations) { conversation in
                        conversationRow(conversation, isPinned: true)
                    }
                } header: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "pin.fill").scaledFont(size: 10)
                        Text("Pinned")
                    }
                    .foregroundStyle(theme.brandPrimary)
                    .accessibilityAddTraits(.isHeader)
                }
            }

            // ── TIME-GROUPED SECTIONS ────────────────────────────────
            ForEach(viewModel.groupedConversations, id: \.0) { section, conversations in
                Section(section) {
                    ForEach(conversations) { conversation in
                        conversationRow(conversation, isPinned: false)
                    }
                }
                .accessibilityAddTraits(.isHeader)
            }

            // Background fetch indicator — shown while remaining pages load
            if viewModel.isFetchingAllPages {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small).padding(.vertical, Spacing.md)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .accessibilityLabel(Text("Loading all conversations"))
            }
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut(duration: AnimDuration.medium), value: viewModel.conversations.map(\.id))
        .animation(.easeInOut(duration: AnimDuration.medium), value: folderVM.folders.map(\.id))
        .environment(\.editMode, .constant(viewModel.isSelectionMode ? .active : .inactive))
    }

    // MARK: - Chats Drop Header

    /// A sticky header above the Chats section that acts as a drop zone.
    /// Dropping a chat here removes it from its current folder.
    private func chatsDropHeader(folderVM: FolderListViewModel) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .scaledFont(size: 10, weight: .medium)
            Text("Chats")
                .scaledFont(size: 12, weight: .medium)
                .fontWeight(.semibold)

            if chatsDropTargetActive {
                Text("Drop to remove from folder")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(chatsDropTargetActive ? theme.brandPrimary : theme.textSecondary)
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(
            chatsDropTargetActive
                ? theme.brandPrimary.opacity(0.1)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .textCase(nil)
        .animation(.easeInOut(duration: AnimDuration.fast), value: chatsDropTargetActive)
        .dropDestination(for: DraggableChat.self) { items, _ in
            guard let item = items.first,
                  item.currentFolderId != nil else { return false }
            let conversation = folderVM.folders.flatMap(\.chats)
                .first { $0.id == item.conversationId }
                ?? viewModel.conversations.first { $0.id == item.conversationId }
            guard let conversation else { return false }

            withAnimation {
                chatsDropTargetActive = false
                folderVM.dragCompleted()
            }
            // Update folderId locally
            if let idx = viewModel.conversations.firstIndex(where: { $0.id == conversation.id }) {
                viewModel.conversations[idx].folderId = nil
            }
            Task { await folderVM.moveChat(conversation: conversation, to: nil) }
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                chatsDropTargetActive = isTargeted
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Conversation Row

    private func conversationRow(_ conversation: Conversation, isPinned: Bool) -> some View {
        let folderVM = viewModel.folderViewModel

        return Group {
            if viewModel.isSelectionMode {
                Button {
                    viewModel.toggleSelection(for: conversation.id)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: viewModel.isSelected(conversation.id)
                            ? "checkmark.circle.fill" : "circle"
                        )
                        .scaledFont(size: 22)
                        .foregroundStyle(
                            viewModel.isSelected(conversation.id)
                                ? theme.brandPrimary : theme.textTertiary
                        )
                        .animation(.easeInOut(duration: AnimDuration.fast), value: viewModel.isSelected(conversation.id))

                        ConversationRow(conversation: conversation)
                    }
                }
                .listRowBackground(
                    viewModel.isSelected(conversation.id)
                        ? theme.brandPrimary.opacity(0.08) : Color.clear
                )
                .accessibilityLabel(Text("\(conversation.title), \(viewModel.isSelected(conversation.id) ? "selected" : "not selected")"))
            } else {
                Button {
                    router.navigate(to: .chatDetail(conversationId: conversation.id))
                    SharedDataService.shared.saveLastActiveConversationId(conversation.id)
                } label: {
                    ConversationRow(conversation: conversation)
                }
                // Make draggable into a folder
                .draggable(DraggableChat(
                    conversationId: conversation.id,
                    currentFolderId: conversation.folderId
                )) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "bubble.left").scaledFont(size: 13)
                        Text(conversation.title)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        viewModel.deletingConversation = conversation
                    } label: {
                        SwiftUI.Label(String(localized: "Delete"), systemImage: "trash")
                    }

                    Button {
                        Task { await viewModel.toggleArchive(conversation: conversation) }
                    } label: {
                        SwiftUI.Label(
                            conversation.archived ? String(localized: "Unarchive") : String(localized: "Archive"),
                            systemImage: "archivebox"
                        )
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await viewModel.togglePin(conversation: conversation) }
                    } label: {
                        SwiftUI.Label(
                            isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                            systemImage: isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .tint(theme.brandPrimary)
                }
                .contextMenu {
                    ConversationContextMenu(
                        onRename: { viewModel.beginRename(conversation: conversation) },
                        onPin: { Task { await viewModel.togglePin(conversation: conversation) } },
                        isPinned: conversation.pinned,
                        onArchive: { Task { await viewModel.toggleArchive(conversation: conversation) } },
                        onShare: {
                            sharingConversation = conversation
                        },
                        onUnshare: {
                            Task { await viewModel.unshareConversation(conversation) }
                        },
                        isShared: conversation.shareId != nil && !(conversation.shareId?.isEmpty ?? true),
                        onDelete: { viewModel.deletingConversation = conversation },
                        folders: folderVM.folders,
                        currentFolderId: conversation.folderId,
                        onMoveToFolder: { folderId in
                            let conv = conversation
                            Task {
                                if let idx = viewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                    viewModel.conversations[idx].folderId = folderId
                                }
                                await folderVM.moveChat(conversation: conv, to: folderId)
                            }
                        }
                    )
                }
                .accessibilityLabel(Text(conversation.title))
                .accessibilityHint(Text("Double tap to open. Long press for options. Drag to move to a folder."))
            }
        }
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(conversation.title)
                    .scaledFont(size: 16, weight: .medium, context: .list)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(conversation.updatedAt.chatTimestamp)
                    .scaledFont(size: 12, weight: .medium, context: .ui)
                    .foregroundStyle(theme.textTertiary)
            }

            if let lastMessage = conversation.messages.last {
                Text(lastMessage.content)
                    .scaledFont(size: 14, context: .list)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            if !conversation.tags.isEmpty {
                HStack(spacing: Spacing.xs) {
                    ForEach(conversation.tags, id: \.self) { tag in
                        Text(tag)
                            .scaledFont(size: 12, weight: .medium)
                            .pillStyle(
                                background: theme.brandPrimary.opacity(OpacityLevel.subtle),
                                foreground: theme.brandPrimary
                            )
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
    }
}
