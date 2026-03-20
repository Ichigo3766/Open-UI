import SwiftUI

// MARK: - iPad Main Chat View
//
// Purpose-built split-column layout for iPad using NavigationSplitView.
// - Sidebar (Column 1, ~300pt): Persistent conversation list + folders — always visible.
// - Detail (Column 2): ChatDetailView — fills remaining space with max reading width.
// - Optional trailing column: TerminalBrowserView when terminal is active.
//
// iPhone uses MainChatView (unchanged). This view is only shown when
// horizontalSizeClass == .regular (iPad, or iPhone in landscape with a keyboard
// connected if it reports regular).

struct iPadMainChatView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    // MARK: State

    /// The conversation currently being viewed. `nil` = new chat.
    @State private var activeConversationId: String?

    /// Monotonically increasing counter to force new-chat view recreation.
    @State private var newChatGeneration: Int = 0

    /// Conversation list view model (shared with sidebar).
    @State private var listViewModel = ChatListViewModel()

    /// Whether the "create folder" sheet is visible.
    @State private var showCreateFolderSheet = false

    /// Whether the settings sheet is visible.
    @State private var showSettings = false

    /// Whether the notes sheet is visible.
    @State private var showNotes = false

    /// Controls column visibility for the NavigationSplitView.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Whether socket reconnect handler has been registered.
    @State private var hasRegisteredSocketHandlers = false

    /// The channel currently being viewed. When set, replaces detail with ChannelDetailView.
    @State private var activeChannelId: String?

    /// Channel list view model for sidebar display.
    @State private var channelListVM = ChannelListViewModel()

    /// Whether the "create channel" sheet is visible.
    @State private var showCreateChannel = false

    /// Rename conversation state.
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""
    @State private var isGeneratingTitle = false

    /// Export state.
    @State private var exportFileURL: URL?
    @State private var showExportShareSheet = false
    @State private var isExporting = false
    @State private var exportError: String?

    /// Deletion confirmation dialogs.
    @State private var showDeleteAllConfirmation = false
    @State private var showDeleteSelectedConfirmation = false

    /// Terminal file browser (trailing column).
    @State private var terminalBrowserVM = TerminalBrowserViewModel()

    // MARK: - Body

    var body: some View {
        @Bindable var bindableRouter = router
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            detailContent(voiceCallBinding: $bindableRouter.isVoiceCallPresented)
        }
        .navigationSplitViewStyle(.balanced)
        .applySheets(
            showSettings: $showSettings,
            showNotes: $showNotes,
            showCreateFolderSheet: $showCreateFolderSheet,
            renamingConversation: $renamingConversation,
            renameText: $renameText,
            isGeneratingTitle: $isGeneratingTitle,
            exportFileURL: $exportFileURL,
            showExportShareSheet: $showExportShareSheet,
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            showDeleteSelectedConfirmation: $showDeleteSelectedConfirmation,
            listViewModel: listViewModel,
            activeConversationId: $activeConversationId,
            voiceCallBinding: $bindableRouter.isVoiceCallPresented,
            systemColorScheme: systemColorScheme,
            dependencies: dependencies,
            router: router,
            onExport: { conv, format in Task { await exportChat(conv, format: format) } },
            onGenerateTitle: { conv in Task { await generateTitleForRename(conv) } }
        )
        .applyAlerts(
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            showDeleteSelectedConfirmation: $showDeleteSelectedConfirmation,
            exportError: $exportError,
            listViewModel: listViewModel,
            activeConversationId: $activeConversationId
        )
        .applyLifecycle(
            listViewModel: listViewModel,
            dependencies: dependencies,
            scenePhase: scenePhase,
            activeConversationId: $activeConversationId,
            hasRegisteredSocketHandlers: $hasRegisteredSocketHandlers,
            onSocketSetup: { registerSocketReconnectHandler() }
        )
        // Channel-specific lifecycle wiring
        .task {
            // Configure and load channels — must pass currentUserId for DM participant filtering
            if let apiClient = dependencies.apiClient {
                var userId = dependencies.authViewModel.currentUser?.id
                if userId == nil || userId?.isEmpty == true {
                    userId = try? await apiClient.getCurrentUser().id
                }
                channelListVM.configure(apiClient: apiClient, socket: dependencies.socketService, currentUserId: userId)
            }
            await channelListVM.loadChannels()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToChannel)) { notification in
            if let channelId = notification.object as? String {
                activeChannelId = channelId
                activeConversationId = nil
                Haptics.play(.light)
            }
        }
        .onChange(of: activeChannelId) { _, newId in
            // When entering a channel, the server marks it as read via GET /channels/{id}.
            // Refresh the channel list after a short delay to clear the unread badge.
            if newId != nil {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    await channelListVM.refreshChannels()
                }
            }
        }
        .sheet(isPresented: $showCreateChannel) {
            CreateChannelSheet(
                onCreate: { name, description, type, isPrivate, memberIds in
                    Task {
                        let channelName = name.isEmpty ? "new-channel" : name
                        if let channel = await channelListVM.createChannel(
                            name: channelName, description: description, type: type,
                            isPrivate: type == .dm ? true : isPrivate
                        ) {
                            if !memberIds.isEmpty {
                                try? await dependencies.apiClient?.addChannelMembers(
                                    id: channel.id, userIds: memberIds
                                )
                            }
                            activeChannelId = channel.id
                            activeConversationId = nil
                        }
                    }
                },
                apiClient: dependencies.apiClient,
                allUsers: channelListVM.allServerUsers
            )
        }
        .overlay {
            if isExporting {
                exportingOverlay
            }
            if listViewModel.isDeletingBulk {
                deletingOverlay
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        iPadSidebarContent(
            listViewModel: listViewModel,
            channelListVM: channelListVM,
            activeConversationId: $activeConversationId,
            activeChannelId: $activeChannelId,
            showCreateFolderSheet: $showCreateFolderSheet,
            showCreateChannel: $showCreateChannel,
            showSettings: $showSettings,
            showNotes: $showNotes,
            showDeleteAllConfirmation: $showDeleteAllConfirmation,
            showDeleteSelectedConfirmation: $showDeleteSelectedConfirmation,
            renamingConversation: $renamingConversation,
            renameText: $renameText,
            dependencies: dependencies,
            onNewChat: { startNewChat() },
            onExport: { conv, format in Task { await exportChat(conv, format: format) } }
        )
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailContent(voiceCallBinding: Binding<Bool>) -> some View {
        if isTerminalActiveInCurrentChat {
            // Three-column layout: chat + terminal browser side by side
            HStack(spacing: 0) {
                chatDetailContent
                    .frame(maxWidth: .infinity)

                Divider()

                TerminalBrowserView(
                    viewModel: terminalBrowserVM,
                    onDismiss: {
                        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
                        vm.toggleTerminal()
                    }
                )
                .frame(width: 340)
                .background(theme.background)
                .onAppear {
                    configureTerminalBrowserIfNeeded()
                    terminalBrowserVM.refresh()
                }
            }
            // ChatDetailView handles its own keyboard via KeyboardTracker.
            // TerminalBrowserView is a fixed side column — no keyboard adjustment needed.
            .ignoresSafeArea(.keyboard)
        } else {
            chatDetailContent
        }
    }

    @ViewBuilder
    private var chatDetailContent: some View {
        if let channelId = activeChannelId {
            // Show channel detail inline (same as how chats work)
            ChannelDetailView(channelId: channelId)
                .id("channel-\(channelId)")
                .transition(.opacity)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            startNewChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New Chat")
                    }
                }
        } else if let conversationId = activeConversationId {
            ChatDetailView(
                conversationId: conversationId,
                viewModel: dependencies.activeChatStore.viewModel(for: conversationId)
            )
            .id(conversationId)
            .transition(.opacity)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Chat")
                }
            }
        } else {
            ChatDetailView(
                viewModel: dependencies.activeChatStore.viewModel(for: nil)
            )
            .id("new-chat-\(newChatGeneration)")
            .transition(.opacity)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New Chat")
                }
            }
        }
    }

    // MARK: - Overlays

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Preparing export…")
                    .scaledFont(size: 16)
                    .foregroundStyle(.white)
            }
            .padding(Spacing.xl)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }

    private var deletingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: Spacing.md) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Deleting…")
                    .scaledFont(size: 16)
                    .foregroundStyle(.white)
            }
            .padding(Spacing.xl)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .transition(.opacity)
    }

    // MARK: - Computed Helpers

    private var isTerminalActiveInCurrentChat: Bool {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        return vm.terminalEnabled && vm.selectedTerminalServer != nil
    }

    // MARK: - Terminal Configuration

    /// Configures the terminal browser VM with the active chat's terminal server credentials.
    /// Must be called before the TerminalBrowserView column is shown, otherwise loadDirectory()
    /// returns early because apiClient and serverId are empty.
    private func configureTerminalBrowserIfNeeded() {
        guard let apiClient = dependencies.apiClient else { return }
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        guard vm.terminalEnabled, let server = vm.selectedTerminalServer else { return }
        terminalBrowserVM.configure(apiClient: apiClient, serverId: server.id)
    }

    // MARK: - Actions

    private func startNewChat() {
        dependencies.activeChatStore.remove(nil)
        activeConversationId = nil
        activeChannelId = nil
        newChatGeneration += 1
        terminalBrowserVM.reset()
        Haptics.play(.light)
    }

    private func generateTitleForRename(_ conversation: Conversation) async {
        guard let api = dependencies.apiClient,
              let manager = dependencies.conversationManager else { return }
        isGeneratingTitle = true
        do {
            let fullConv = try await manager.fetchConversation(id: conversation.id)
            let messages: [[String: Any]] = fullConv.messages.map { msg in
                ["role": msg.role.rawValue, "content": msg.content]
            }
            let model = fullConv.model ?? dependencies.activeChatStore.cachedSelectedModelId ?? ""
            if let title = try await api.generateTitle(model: model, messages: messages, chatId: conversation.id) {
                renameText = title
            }
        } catch {}
        isGeneratingTitle = false
    }

    enum ExportFormat { case json, txt, pdf }

    private func exportChat(_ conversation: Conversation, format: ExportFormat) async {
        guard let manager = dependencies.conversationManager else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let fullConversation = try await manager.fetchConversation(id: conversation.id)
            let title = fullConversation.title
            let messages = fullConversation.messages
            let tmpDir = FileManager.default.temporaryDirectory

            switch format {
            case .json:
                let payload: [[String: Any]] = messages.map { msg in
                    ["role": msg.role.rawValue, "content": msg.content, "timestamp": msg.timestamp.timeIntervalSince1970]
                }
                let wrapper: [String: Any] = ["title": title, "messages": payload]
                let data = try JSONSerialization.data(withJSONObject: wrapper, options: .prettyPrinted)
                let url = tmpDir.appendingPathComponent("\(title).json")
                try data.write(to: url)
                exportFileURL = url
                showExportShareSheet = true
            case .txt:
                var text = "# \(title)\n\n"
                for msg in messages {
                    let role = msg.role == .user ? "User" : (msg.role == .assistant ? "Assistant" : msg.role.rawValue)
                    text += "[\(role)]\n\(msg.content)\n\n"
                }
                let url = tmpDir.appendingPathComponent("\(title).txt")
                try text.write(to: url, atomically: true, encoding: .utf8)
                exportFileURL = url
                showExportShareSheet = true
            case .pdf:
                guard let api = dependencies.apiClient else { return }
                let pdfData = try await api.downloadChatAsPDF(chatId: fullConversation.id)
                let url = tmpDir.appendingPathComponent("\(title).pdf")
                try pdfData.write(to: url)
                exportFileURL = url
                showExportShareSheet = true
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func registerSocketReconnectHandler() {
        guard !hasRegisteredSocketHandlers else { return }
        hasRegisteredSocketHandlers = true

        dependencies.socketService?.onReconnect = { [self] in
            Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    group.addTask { await channelListVM.refreshChannels() }
                }
                if let activeId = activeConversationId {
                    let vm = dependencies.activeChatStore.viewModel(for: activeId)
                    if !vm.isStreaming { await vm.syncWithServer() }
                }
            }
        }

        dependencies.socketService?.onConnect = { [self] in
            Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    group.addTask { await channelListVM.refreshChannels() }
                }
            }
        }
    }
}

// MARK: - iPad Sidebar Content

struct iPadSidebarContent: View {
    @Bindable var listViewModel: ChatListViewModel
    var channelListVM: ChannelListViewModel
    @Binding var activeConversationId: String?
    @Binding var activeChannelId: String?
    @Binding var showCreateFolderSheet: Bool
    @Binding var showCreateChannel: Bool
    @Binding var showSettings: Bool
    @Binding var showNotes: Bool
    @Binding var showDeleteAllConfirmation: Bool
    @Binding var showDeleteSelectedConfirmation: Bool
    @Binding var renamingConversation: Conversation?
    @Binding var renameText: String
    let dependencies: AppDependencyContainer
    let onNewChat: () -> Void
    let onExport: (Conversation, iPadMainChatView.ExportFormat) -> Void

    @Environment(\.theme) private var theme
    @State private var drawerChatsDropActive = false

    var body: some View {
        VStack(spacing: 0) {
            // Search / selection header
            if listViewModel.isSelectionMode {
                selectionModeHeader
            } else {
                sidebarSearchBar
            }

            // Conversation list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let folderVM = listViewModel.folderViewModel

                    // Folders section
                    if !folderVM.featureDisabled {
                        foldersSection(folderVM: folderVM)
                    }

                    // Divider between folders and channels
                    if !folderVM.folders.isEmpty || !channelListVM.channels.isEmpty {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.12))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // Channels section
                    channelsSection

                    // Divider between channels and chats
                    if !channelListVM.channels.isEmpty {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.12))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // Chats section
                    let hasAnyChats = !listViewModel.pinnedConversations.isEmpty
                        || !listViewModel.groupedConversations.isEmpty

                    if hasAnyChats || !folderVM.folders.isEmpty {
                        chatsSection(folderVM: folderVM)
                    }
                }
                .padding(.bottom, Spacing.md)
            }

            Spacer(minLength: 0)

            if listViewModel.isSelectionMode {
                selectionBottomBar
            } else {
                sidebarBottomBar
            }
        }
        .background(theme.background)
        // Sidebar has no text inputs that need keyboard avoidance — ignore
        // keyboard safe area so the sidebar layout doesn't shift when a
        // floating keyboard appears/disappears or changes size on iPad.
        .ignoresSafeArea(.keyboard)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if listViewModel.isSelectionMode {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            listViewModel.exitSelectionMode()
                        }
                    } label: {
                        Text("Cancel").foregroundStyle(theme.brandPrimary)
                    }
                } else {
                    Menu {
                        if !listViewModel.conversations.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    listViewModel.toggleSelectionMode()
                                }
                            } label: {
                                Label("Select Chats", systemImage: "checkmark.circle")
                            }
                            Button {
                                listViewModel.showArchiveAllConfirmation = true
                            } label: {
                                Label("Archive All", systemImage: "archivebox")
                            }
                            Button(role: .destructive) {
                                showDeleteAllConfirmation = true
                            } label: {
                                Label("Delete All", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Chat")
            }
        }
    }

    // MARK: - Search Bar

    private var sidebarSearchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 13)
                .foregroundStyle(theme.textTertiary)

            TextField("Search conversations…", text: $listViewModel.searchText)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textPrimary)

            if !listViewModel.searchText.isEmpty {
                Button {
                    listViewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 9)
        .background(theme.surfaceContainer.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Selection Mode Header

    private var selectionModeHeader: some View {
        HStack(spacing: Spacing.sm) {
            Spacer()
            Text("\(listViewModel.selectedCount) selected")
                .scaledFont(size: 14, weight: .medium)
                .fontWeight(.semibold)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Button {
                if listViewModel.selectedCount == listViewModel.filteredConversations.count {
                    listViewModel.selectedConversationIds.removeAll()
                } else {
                    listViewModel.selectAll()
                }
            } label: {
                Text(listViewModel.selectedCount == listViewModel.filteredConversations.count ? "Deselect All" : "Select All")
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(0.4))
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Folders Section

    @ViewBuilder
    private func foldersSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                Text("Folders")
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.bold)
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Button { showCreateFolderSheet = true } label: {
                    Image(systemName: "folder.badge.plus")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xs)

            ForEach(folderVM.folders) { folder in
                DrawerFolderRow(
                    folder: folder,
                    folderVM: folderVM,
                    allConversations: listViewModel.conversations,
                    activeConversationId: activeConversationId,
                    onSelectChat: { chatId in
                        activeConversationId = chatId
                        SharedDataService.shared.saveLastActiveConversationId(chatId)
                        // No drawer to close on iPad — sidebar stays visible
                    },
                    onChatMoved: { chatId, targetFolderId in
                        if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                            listViewModel.conversations[idx].folderId = targetFolderId
                        } else if targetFolderId == nil {
                            let folderChats = folderVM.folders.flatMap(\.chats)
                            if var conv = folderChats.first(where: { $0.id == chatId }) {
                                conv.folderId = nil
                                listViewModel.conversations.insert(conv, at: 0)
                            }
                        }
                    },
                    onDeleteChat: { chatId in
                        Task {
                            await listViewModel.deleteConversation(id: chatId)
                            if let fIdx = folderVM.folders.firstIndex(where: { $0.id == folder.id }) {
                                folderVM.folders[fIdx].chats.removeAll { $0.id == chatId }
                            }
                            if activeConversationId == chatId { activeConversationId = nil }
                        }
                    },
                    onTogglePin: { conversation in
                        Task { await listViewModel.togglePin(conversation: conversation) }
                    }
                )
                .padding(.horizontal, Spacing.sm)
            }
        }
        .animation(.easeInOut(duration: AnimDuration.medium), value: folderVM.folders.map(\.id))
    }

    // MARK: - Channels Section

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                Text("Channels")
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.bold)
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()

                // Create new channel
                Button {
                    showCreateChannel = true
                } label: {
                    Image(systemName: "plus.bubble")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            if channelListVM.channels.isEmpty {
                Text("No channels yet")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 4)
            } else {
                ForEach(channelListVM.channels) { channel in
                    Button {
                        activeChannelId = channel.id
                        activeConversationId = nil
                    } label: {
                        HStack(spacing: 6) {
                            // DM: show participant avatar; others: show icon
                            if channel.type == .dm, let participant = channel.dmParticipants.first {
                                UserAvatar(
                                    size: 22,
                                    imageURL: participant.resolveAvatarURL(serverBaseURL: dependencies.apiClient?.baseURL ?? ""),
                                    name: participant.displayName,
                                    authToken: dependencies.apiClient?.network.authToken
                                )
                            } else {
                                Image(systemName: channel.sidebarIcon)
                                    .scaledFont(size: 11)
                                    .foregroundStyle(activeChannelId == channel.id ? theme.brandPrimary : theme.textTertiary)
                            }
                            Text(channel.displayName)
                                .scaledFont(size: 14)
                                .fontWeight(activeChannelId == channel.id || channel.unreadCount > 0 ? .semibold : .regular)
                                .foregroundStyle(activeChannelId == channel.id ? theme.textPrimary : theme.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            if activeChannelId == channel.id {
                                Circle()
                                    .fill(theme.brandPrimary)
                                    .frame(width: 6, height: 6)
                            } else if channel.unreadCount > 0 {
                                Text("\(channel.unreadCount)")
                                    .scaledFont(size: 11, weight: .bold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.brandPrimary)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 7)
                        .background(
                            activeChannelId == channel.id
                                ? theme.brandPrimary.opacity(0.1)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Chats Section

    @ViewBuilder
    private func chatsSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                Text("Chats")
                    .scaledFont(size: 12, weight: .medium)
                    .fontWeight(.bold)
                    .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if drawerChatsDropActive {
                    Text("Drop here")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                        .transition(.opacity)
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xs)

            // Pinned
            if !listViewModel.pinnedConversations.isEmpty {
                CollapsibleDrawerSection(title: "Pinned") {
                    ForEach(listViewModel.pinnedConversations) { conversation in
                        conversationRow(conversation)
                    }
                }
            }

            // Time-grouped
            ForEach(listViewModel.groupedConversations, id: \.0) { group in
                CollapsibleDrawerSection(title: group.0, count: group.1.count) {
                    ForEach(group.1) { conversation in
                        conversationRow(conversation)
                    }
                }
            }
        }
        .background(
            drawerChatsDropActive ? theme.brandPrimary.opacity(0.05) : Color.clear
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(theme.brandPrimary, lineWidth: drawerChatsDropActive ? 1.5 : 0)
                .padding(.horizontal, 2)
        )
        .animation(.easeInOut(duration: AnimDuration.fast), value: drawerChatsDropActive)
        .dropDestination(for: DraggableChat.self) { items, _ in
            guard let item = items.first, item.currentFolderId != nil else { return false }
            let chatId = item.conversationId
            let folderChats = folderVM.folders.flatMap(\.chats)
            let conversation = folderChats.first(where: { $0.id == chatId })
                ?? listViewModel.conversations.first(where: { $0.id == chatId })
            guard let conversation else { return false }
            withAnimation { drawerChatsDropActive = false; folderVM.dragCompleted() }
            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                listViewModel.conversations[idx].folderId = nil
            } else {
                var conv = conversation; conv.folderId = nil
                listViewModel.conversations.insert(conv, at: 0)
            }
            Task { await folderVM.moveChat(conversation: conversation, to: nil) }
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: AnimDuration.fast)) { drawerChatsDropActive = isTargeted }
        }
    }

    // MARK: - Conversation Row

    private func conversationRow(_ conversation: Conversation) -> some View {
        Group {
            if listViewModel.isSelectionMode {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        listViewModel.toggleSelection(for: conversation.id)
                    }
                    Haptics.play(.light)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: listViewModel.isSelected(conversation.id)
                            ? "checkmark.circle.fill" : "circle")
                            .scaledFont(size: 18)
                            .foregroundStyle(listViewModel.isSelected(conversation.id)
                                ? theme.brandPrimary : theme.textTertiary)
                        Text(conversation.title)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                    .background(listViewModel.isSelected(conversation.id)
                        ? theme.brandPrimary.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    activeConversationId = conversation.id
                    activeChannelId = nil  // Clear channel when opening a chat
                    SharedDataService.shared.saveLastActiveConversationId(conversation.id)
                    // Sidebar stays open on iPad — no dismissal needed
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .scaledFont(size: 14)
                                .fontWeight(activeConversationId == conversation.id ? .semibold : .regular)
                                .foregroundStyle(activeConversationId == conversation.id
                                    ? theme.textPrimary : theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        // Active indicator dot
                        if activeConversationId == conversation.id {
                            Circle()
                                .fill(theme.brandPrimary)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 8)
                    .background(
                        activeConversationId == conversation.id
                            ? theme.brandPrimary.opacity(0.1)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .draggable(DraggableChat(
                    conversationId: conversation.id,
                    currentFolderId: conversation.folderId
                )) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "bubble.left").scaledFont(size: 12)
                        Text(conversation.title)
                            .scaledFont(size: 12, weight: .medium)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .contextMenu {
                    iPadConversationContextMenu(
                        conversation: conversation,
                        listViewModel: listViewModel,
                        dependencies: dependencies,
                        activeConversationId: $activeConversationId,
                        renamingConversation: $renamingConversation,
                        renameText: $renameText,
                        onExport: onExport
                    )
                }
            }
        }
    }

    // MARK: - Bottom Bars

    private var selectionBottomBar: some View {
        Button(role: .destructive) {
            showDeleteSelectedConfirmation = true
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "trash")
                Text("Delete (\(listViewModel.selectedCount))")
            }
            .scaledFont(size: 14, weight: .medium)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(listViewModel.selectedCount > 0 ? Color.red : Color.red.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .disabled(listViewModel.selectedCount == 0)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .background(theme.surfaceContainer.opacity(0.3))
    }

    private var sidebarBottomBar: some View {
        HStack(spacing: Spacing.md) {
            // User avatar
            Button {
                showSettings = true
            } label: {
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(theme.brandPrimary.opacity(0.15))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Text(String((dependencies.authViewModel.currentUser?.displayName ?? "U").prefix(1)).uppercased())
                                .scaledFont(size: 13, weight: .bold)
                                .foregroundStyle(theme.brandPrimary)
                        )
                    Text(dependencies.authViewModel.currentUser?.displayName ?? "User")
                        .scaledFont(size: 12, weight: .medium)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Notes
            Button { showNotes = true } label: {
                Image(systemName: "note.text")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }

            // Settings
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
            theme.surfaceContainer.opacity(0.25)
                .overlay(
                    Rectangle()
                        .fill(theme.textTertiary.opacity(0.1))
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
    }
}

// MARK: - Context Menu (iPad Sidebar)

private struct iPadConversationContextMenu: View {
    let conversation: Conversation
    let listViewModel: ChatListViewModel
    let dependencies: AppDependencyContainer
    @Binding var activeConversationId: String?
    @Binding var renamingConversation: Conversation?
    @Binding var renameText: String
    let onExport: (Conversation, iPadMainChatView.ExportFormat) -> Void

    var body: some View {
        Button { onExport(conversation, .json) } label: {
            Label("Export as JSON", systemImage: "doc")
        }
        Button { onExport(conversation, .txt) } label: {
            Label("Export as Text", systemImage: "doc.plaintext")
        }
        Button { onExport(conversation, .pdf) } label: {
            Label("Export as PDF", systemImage: "doc.richtext")
        }

        Divider()

        Button {
            renamingConversation = conversation
            renameText = conversation.title
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            Task { await listViewModel.togglePin(conversation: conversation) }
        } label: {
            Label(conversation.pinned ? "Unpin" : "Pin",
                  systemImage: conversation.pinned ? "pin.slash" : "pin")
        }

        Button {
            Task {
                await listViewModel.toggleArchive(conversation: conversation)
                if !conversation.archived && activeConversationId == conversation.id {
                    activeConversationId = nil
                }
            }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }

        let folders = listViewModel.folderViewModel.folders
        if !folders.isEmpty {
            Menu("Move to Folder") {
                ForEach(folders) { folder in
                    Button {
                        let conv = conversation
                        Task {
                            await listViewModel.folderViewModel.moveChat(conversation: conv, to: folder.id)
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                listViewModel.conversations[idx].folderId = folder.id
                            }
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                    .disabled(folder.id == conversation.folderId)
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            let deletedId = conversation.id
            Task {
                await listViewModel.deleteConversation(id: deletedId)
                if activeConversationId == deletedId { activeConversationId = nil }
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - View Modifier Helpers

private extension View {
    func applySheets(
        showSettings: Binding<Bool>,
        showNotes: Binding<Bool>,
        showCreateFolderSheet: Binding<Bool>,
        renamingConversation: Binding<Conversation?>,
        renameText: Binding<String>,
        isGeneratingTitle: Binding<Bool>,
        exportFileURL: Binding<URL?>,
        showExportShareSheet: Binding<Bool>,
        showDeleteAllConfirmation: Binding<Bool>,
        showDeleteSelectedConfirmation: Binding<Bool>,
        listViewModel: ChatListViewModel,
        activeConversationId: Binding<String?>,
        voiceCallBinding: Binding<Bool>,
        systemColorScheme: ColorScheme,
        dependencies: AppDependencyContainer,
        router: AppRouter,
        onExport: @escaping (Conversation, iPadMainChatView.ExportFormat) -> Void,
        onGenerateTitle: @escaping (Conversation) -> Void
    ) -> some View {
        self
            .sheet(isPresented: showSettings) {
                SettingsView(
                    viewModel: dependencies.authViewModel,
                    appearanceManager: dependencies.appearanceManager
                )
                .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme ?? systemColorScheme)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                .presentationCornerRadius(20)
            }
            .sheet(isPresented: showNotes) {
                NavigationStack {
                    NotesListView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showNotes.wrappedValue = false }
                            }
                        }
                }
                .presentationCornerRadius(20)
            }
            .sheet(isPresented: voiceCallBinding) {
                if let voiceCallVM = router.voiceCallViewModel {
                    VoiceCallView(viewModel: voiceCallVM)
                        .environment(dependencies)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.hidden)
                        .presentationCornerRadius(24)
                        .presentationBackground(.ultraThinMaterial)
                        .interactiveDismissDisabled(false)
                }
            }
            .onChange(of: router.isVoiceCallPresented) { _, isPresented in
                if !isPresented { router.voiceCallViewModel = nil }
            }
            .sheet(isPresented: showCreateFolderSheet) {
                CreateFolderSheet(apiClient: dependencies.apiClient) { name, data, meta in
                    let parentId = listViewModel.folderViewModel.createSubfolderParentId
                    listViewModel.folderViewModel.createSubfolderParentId = nil
                    Task {
                        await listViewModel.folderViewModel.createFolder(
                            name: name, parentId: parentId, data: data, meta: meta
                        )
                    }
                }
            }
            .alert("Rename Folder", isPresented: .init(
                get: { listViewModel.folderViewModel.renamingFolder != nil },
                set: { if !$0 { listViewModel.folderViewModel.renamingFolder = nil } }
            )) {
                TextField("Folder Name", text: Bindable(listViewModel.folderViewModel).renameText)
                Button("Cancel", role: .cancel) { listViewModel.folderViewModel.renamingFolder = nil }
                Button("Rename") { Task { await listViewModel.folderViewModel.commitRename() } }
            }
            .sheet(item: renamingConversation) { conv in
                iPadRenameSheet(
                    conversation: conv,
                    renameText: renameText,
                    isGeneratingTitle: isGeneratingTitle,
                    listViewModel: listViewModel,
                    activeConversationId: activeConversationId,
                    onGenerateTitle: onGenerateTitle
                )
            }
            .sheet(isPresented: showExportShareSheet, onDismiss: {
                if let url = exportFileURL.wrappedValue {
                    try? FileManager.default.removeItem(at: url)
                    exportFileURL.wrappedValue = nil
                }
            }) {
                if let url = exportFileURL.wrappedValue {
                    ShareSheet(items: [url])
                }
            }
    }

    func applyAlerts(
        showDeleteAllConfirmation: Binding<Bool>,
        showDeleteSelectedConfirmation: Binding<Bool>,
        exportError: Binding<String?>,
        listViewModel: ChatListViewModel,
        activeConversationId: Binding<String?>
    ) -> some View {
        self
            .confirmationDialog("Archive All Chats",
                isPresented: .constant(listViewModel.showArchiveAllConfirmation),
                titleVisibility: .visible) {
                Button("Archive All", role: .destructive) {
                    Task {
                        await listViewModel.archiveAllConversations()
                        activeConversationId.wrappedValue = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete All Chats",
                isPresented: showDeleteAllConfirmation,
                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    Task {
                        await listViewModel.deleteAllConversations()
                        activeConversationId.wrappedValue = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all your conversations. This action cannot be undone.")
            }
            .confirmationDialog("Delete Selected Chats",
                isPresented: showDeleteSelectedConfirmation,
                titleVisibility: .visible) {
                Button("Delete \(listViewModel.selectedCount) Chat\(listViewModel.selectedCount == 1 ? "" : "s")", role: .destructive) {
                    if let activeId = activeConversationId.wrappedValue,
                       listViewModel.selectedConversationIds.contains(activeId) {
                        activeConversationId.wrappedValue = nil
                    }
                    Task { await listViewModel.deleteSelectedConversations() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Export Failed",
                   isPresented: .init(get: { exportError.wrappedValue != nil },
                                      set: { if !$0 { exportError.wrappedValue = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError.wrappedValue ?? "") }
    }

    func applyLifecycle(
        listViewModel: ChatListViewModel,
        dependencies: AppDependencyContainer,
        scenePhase: ScenePhase,
        activeConversationId: Binding<String?>,
        hasRegisteredSocketHandlers: Binding<Bool>,
        onSocketSetup: @escaping () -> Void
    ) -> some View {
        self
            .task {
                if let manager = dependencies.conversationManager {
                    listViewModel.configure(with: manager)
                }
                if let folderManager = dependencies.folderManager {
                    listViewModel.folderViewModel.configure(with: folderManager)
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.loadConversations() }
                    group.addTask { await listViewModel.folderViewModel.loadFolders() }
                    group.addTask { await dependencies.fetchTaskConfig() }
                }
                onSocketSetup()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active && oldPhase != .active {
                    Task {
                        if let socket = dependencies.socketService,
                           !socket.isConnected, !socket.isConnecting {
                            socket.connect()
                        }
                        await withTaskGroup(of: Void.self) { group in
                            group.addTask { await listViewModel.refreshIfStale() }
                            group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                        }
                        dependencies.updateWidgetData(conversations: listViewModel.conversations)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationTitleUpdated)) { notification in
                guard let userInfo = notification.userInfo,
                      let conversationId = userInfo["conversationId"] as? String,
                      let title = userInfo["title"] as? String else { return }
                listViewModel.updateTitle(for: conversationId, title: title)
                let folderVM = listViewModel.folderViewModel
                for idx in folderVM.folders.indices {
                    if let chatIdx = folderVM.folders[idx].chats.firstIndex(where: { $0.id == conversationId }) {
                        folderVM.folders[idx].chats[chatIdx].title = title
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationListNeedsRefresh)) { _ in
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await listViewModel.refreshConversations() }
                        group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .adminClonedChat)) { notification in
                if let conversationId = notification.object as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        activeConversationId.wrappedValue = conversationId
                        SharedDataService.shared.saveLastActiveConversationId(conversationId)
                    }
                }
            }
    }
}

// MARK: - Rename Sheet (iPad)

private struct iPadRenameSheet: View {
    let conversation: Conversation
    @Binding var renameText: String
    @Binding var isGeneratingTitle: Bool
    let listViewModel: ChatListViewModel
    @Binding var activeConversationId: String?
    let onGenerateTitle: (Conversation) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                TextField("Chat title", text: $renameText)
                    .scaledFont(size: 16)
                    .padding(Spacing.md)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                Button {
                    onGenerateTitle(conversation)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isGeneratingTitle {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGeneratingTitle ? "Generating…" : "Generate Title")
                    }
                    .scaledFont(size: 14, weight: .medium)
                    .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(theme.brandPrimary)
                .disabled(isGeneratingTitle)

                Spacer()
            }
            .padding(Spacing.lg)
            .navigationTitle("Rename Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !newTitle.isEmpty else { return }
                        listViewModel.renamingConversation = conversation
                        listViewModel.renameText = newTitle
                        Task { await listViewModel.commitRename() }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }
}
