import SwiftUI

/// The primary authenticated view that shows the chat screen as the
/// landing page, with a slide-out drawer for conversation history,
/// settings, and notes — matching the Flutter app's layout.
///
/// ## Performance
/// - The drawer is **always in the view tree** (offset-based, not `if/else`),
///   so toggling it never destroys/recreates its view hierarchy.
/// - The main content is **never** `.disabled()` — the dimming overlay
///   intercepts taps instead, avoiding a full re-render of the chat stack.
/// - Haptic feedback uses the pre-prepared `Haptics` service.
struct MainChatView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// Controls the drawer visibility.
    @State private var showDrawer = false

    /// Controls the settings sheet presentation.
    @State private var showSettings = false

    /// Controls the notes sheet presentation.
    @State private var showNotes = false

    /// Controls the workspace sheet presentation.
    @State private var showWorkspace = false

    /// Controls the memories sheet presentation.
    @State private var showMemories = false

    /// Controls the channels list sheet presentation.
    @State private var showChannels = false
    
    /// Controls the create channel sheet presentation.
    @State private var showCreateChannel = false

    /// Controls the archived chats sheet presentation.
    @State private var showArchivedChats = false

    /// Controls the shared chats sheet presentation.
    @State private var showSharedChats = false

    /// Channel list VM for sidebar display.
    @State private var channelListVM = ChannelListViewModel()

    /// The conversation currently being viewed. `nil` = new chat.
    @State private var activeConversationId: String?

    /// The channel currently being viewed. When set, replaces main content with ChannelDetailView.
    @State private var activeChannelId: String?

    /// Monotonically increasing counter to force new-chat view recreation.
    @State private var newChatGeneration: Int = 0

    /// Conversation list view model (shared with drawer).
    @State private var listViewModel = ChatListViewModel()

    /// Controls the "delete all" confirmation dialog.
    @State private var showDeleteAllConfirmation = false

    /// Controls the "delete selected" confirmation dialog.
    @State private var showDeleteSelectedConfirmation = false

    /// Single-conversation delete confirmation (from drawer context menu).
    @State private var deletingConversation: Conversation?

    /// Channel delete confirmation (from drawer context menu).
    @State private var deletingChannelId: String?

    /// Whether the "create folder" sheet is visible.
    @State private var showCreateFolderSheet = false

    /// When set, the main content area shows a folder workspace view
    /// (folder icon + name centered, chat input below). Any new chat
    /// started will be assigned to this folder with its system prompt.
    @State private var activeFolderWorkspaceId: String?

    /// Tracks whether socket reconnect handler has been registered.
    @State private var hasRegisteredSocketHandlers = false

    /// Whether the drawer "Chats" header is being targeted by a drag.
    @State private var drawerChatsDropActive: Bool = false

    /// Top-level section collapse states (persisted across launches).
    @AppStorage("sidebar_folders_expanded") private var foldersExpanded: Bool = true
    @AppStorage("sidebar_channels_expanded") private var channelsExpanded: Bool = true
    @AppStorage("sidebar_chats_expanded") private var chatsExpanded: Bool = true

    /// Cached container width from GeometryReader (avoids deprecated UIScreen.main).
    @State private var containerWidth: CGFloat = 360

    /// Live drag offset for interactive drawer sliding.
    @State private var dragOffset: CGFloat = 0

    /// Whether a drawer drag is in progress (prevents animation fighting).
    @State private var isDraggingDrawer = false

    // MARK: Terminal file browser (right-side panel)
    @State private var showFileBrowser = false
    @State private var fileBrowserDragOffset: CGFloat = 0
    @State private var isDraggingFileBrowser = false
    @State private var terminalBrowserVM = TerminalBrowserViewModel()

    /// Rename conversation state.
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""

    /// Share sheet state.
    @State private var sharingConversation: Conversation?

    /// Export file URL for share sheet.
    @State private var exportFileURL: URL?
    @State private var showExportShareSheet = false

    /// Whether title is being AI-generated.
    @State private var isGeneratingTitle = false

    /// Whether a chat export is in progress (shows loading overlay).
    @State private var isExporting = false
    @State private var exportError: String?

    /// Drawer width as a fraction of container width, capped.
    private var drawerWidth: CGFloat {
        min(containerWidth * 0.82, 360)
    }

    var body: some View {
        @Bindable var bindableRouter = router
        mainContent(voiceCallBinding: $bindableRouter.isVoiceCallPresented)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if abs(containerWidth - newWidth) > 1 {
                    containerWidth = newWidth
                }
            }
    }

    /// Computes the effective drawer X offset (0 = fully open, -drawerWidth = fully closed).
    /// Combines the base `showDrawer` state with the live `dragOffset` during a gesture.
    private var effectiveDrawerX: CGFloat {
        let base: CGFloat = showDrawer ? 0 : -drawerWidth
        let combined = base + dragOffset
        return min(0, max(-drawerWidth, combined))
    }

    /// Drawer open fraction (0 = fully closed, 1 = fully open) — drives dimming opacity.
    private var drawerFraction: CGFloat {
        let fraction = (effectiveDrawerX + drawerWidth) / drawerWidth
        return min(1, max(0, fraction))
    }

    // MARK: File Browser Computed Properties (right-side panel, mirrors drawer)

    /// File browser panel width.
    private var fileBrowserWidth: CGFloat {
        min(containerWidth * 0.85, 380)
    }

    /// Effective X offset for the file browser (containerWidth = off-screen right,
    /// containerWidth - fileBrowserWidth = fully visible).
    private var effectiveFileBrowserX: CGFloat {
        let base: CGFloat = showFileBrowser ? (containerWidth - fileBrowserWidth) : containerWidth
        let combined = base + fileBrowserDragOffset
        return max(containerWidth - fileBrowserWidth, min(containerWidth, combined))
    }

    /// File browser open fraction (0 = closed, 1 = fully open).
    private var fileBrowserFraction: CGFloat {
        let fraction = (containerWidth - effectiveFileBrowserX) / fileBrowserWidth
        return min(1, max(0, fraction))
    }

    /// Whether the current active chat has terminal enabled with a server selected.
    private var isTerminalActiveInCurrentChat: Bool {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        return vm.terminalEnabled && vm.selectedTerminalServer != nil
    }

    // MARK: - Main Content Pipeline
    // Split into distinct sub-methods so the Swift type checker can resolve
    // each modifier group independently (fixes "unable to type-check" error).

    private func mainContent(voiceCallBinding: Binding<Bool>) -> some View {
        applyOverlays(
            content: applyLifecycleHandlers(
                content: applyDialogsAndAlerts(
                    content: applySheets(
                        content: mainZStack(voiceCallBinding: voiceCallBinding),
                        voiceCallBinding: voiceCallBinding
                    )
                )
            )
        )
    }

    // MARK: - Main ZStack (Core Layout)

    @ViewBuilder
    private func mainZStack(voiceCallBinding: Binding<Bool>) -> some View {
        ZStack(alignment: .leading) {
            // MARK: Main chat content
            NavigationStack {
                chatContent
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                toggleDrawer()
                            } label: {
                                Image(systemName: "line.3.horizontal")
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Menu")
                        }

                        ToolbarItem(placement: .principal) {
                            if activeChannelId == nil {
                                modelSelector
                            }
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            if activeChannelId == nil {
                                Button {
                                    startNewChat()
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                        .scaledFont(size: 14, weight: .medium)
                                        .foregroundStyle(theme.textSecondary)
                                        .frame(width: 34, height: 34)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("New Chat")
                            }
                        }
                    }
            }
            .allowsHitTesting(drawerFraction < 0.01 && !isDraggingDrawer && !isDraggingFileBrowser)

            // MARK: Dimming overlay
            Color.black
                .opacity(0.4 * drawerFraction)
                .ignoresSafeArea()
                .allowsHitTesting(drawerFraction > 0.01)
                .onTapGesture {
                    closeDrawerAnimated()
                }
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal < 0 else { return }
                            isDraggingDrawer = true
                            dragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingDrawer else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingDrawer = false
                            if horizontal < -(drawerWidth * 0.3) || velocity < -500 {
                                closeDrawerAnimated()
                            } else {
                                openDrawerAnimated()
                            }
                        }
                )

            // MARK: Drawer
            drawerContent
                .frame(width: drawerWidth)
                .offset(x: effectiveDrawerX)
                .accessibilityHidden(drawerFraction < 0.01)
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal < 0 else { return }
                            isDraggingDrawer = true
                            dragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingDrawer else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingDrawer = false
                            if horizontal < -(drawerWidth * 0.3) || velocity < -500 {
                                closeDrawerAnimated()
                            } else {
                                openDrawerAnimated()
                            }
                        }
                )

            // MARK: File browser dimming overlay (right side — only when terminal is active)
            if isTerminalActiveInCurrentChat {
            Color.black
                .opacity(0.4 * fileBrowserFraction)
                .ignoresSafeArea()
                .allowsHitTesting(fileBrowserFraction > 0.01)
                .onTapGesture {
                    closeFileBrowserAnimated()
                }
                .gesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            let horizontal = value.translation.width
                            guard horizontal > 0 else { return }
                            isDraggingFileBrowser = true
                            fileBrowserDragOffset = horizontal
                        }
                        .onEnded { value in
                            guard isDraggingFileBrowser else { return }
                            let horizontal = value.translation.width
                            let velocity = value.velocity.width
                            isDraggingFileBrowser = false
                            if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                                closeFileBrowserAnimated()
                            } else {
                                openFileBrowserAnimated()
                            }
                        }
                )

            // MARK: File browser panel (right side)
            TerminalBrowserView(
                viewModel: terminalBrowserVM,
                onDismiss: { closeFileBrowserAnimated() }
            )
            .frame(width: fileBrowserWidth)
            .background(theme.background)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .shadow(color: .black.opacity(0.2), radius: 16, x: -4)
            .offset(x: effectiveFileBrowserX)
            .accessibilityHidden(fileBrowserFraction < 0.01)
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        let horizontal = value.translation.width
                        guard horizontal > 0 else { return }
                        isDraggingFileBrowser = true
                        fileBrowserDragOffset = horizontal
                    }
                    .onEnded { value in
                        guard isDraggingFileBrowser else { return }
                        let horizontal = value.translation.width
                        let velocity = value.velocity.width
                        isDraggingFileBrowser = false
                        if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                            closeFileBrowserAnimated()
                        } else {
                            openFileBrowserAnimated()
                        }
                    }
            )
            } // end if isTerminalActiveInCurrentChat

            // MARK: Left edge overlay — exclusively captures left-edge swipe to open drawer.
            // Sits on top of the NavigationStack so it intercepts touches before they
            // reach background content. Uses .gesture() (not .simultaneousGesture) so
            // background taps/scrolls cannot fire during the drag.
            if !showDrawer {
                Color.clear
                    .frame(width: 20)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .local)
                            .onChanged { value in
                                let horizontal = value.translation.width
                                let vertical = abs(value.translation.height)
                                guard horizontal > vertical else { return }
                                if !isDraggingDrawer {
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                                isDraggingDrawer = true
                                dragOffset = horizontal
                            }
                            .onEnded { value in
                                guard isDraggingDrawer else { return }
                                let horizontal = value.translation.width
                                let velocity = value.velocity.width
                                isDraggingDrawer = false
                                if horizontal > drawerWidth * 0.4 || velocity > 500 {
                                    openDrawerAnimated()
                                } else {
                                    closeDrawerAnimated()
                                }
                            }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // MARK: Right edge overlay — exclusively captures right-edge swipe to open file browser.
            // Only shown when terminal is active and file browser is closed.
            if isTerminalActiveInCurrentChat && !showFileBrowser && !showDrawer {
                Color.clear
                    .frame(width: 40)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .local)
                            .onChanged { value in
                                let horizontal = value.translation.width
                                let vertical = abs(value.translation.height)
                                guard abs(horizontal) > vertical, horizontal < 0 else { return }
                                if !isDraggingFileBrowser {
                                    configureTerminalBrowserIfNeeded()
                                    UIApplication.shared.sendAction(
                                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }
                                isDraggingFileBrowser = true
                                fileBrowserDragOffset = horizontal
                            }
                            .onEnded { value in
                                guard isDraggingFileBrowser else { return }
                                let horizontal = abs(value.translation.width)
                                let velocity = abs(value.velocity.width)
                                isDraggingFileBrowser = false
                                if horizontal > fileBrowserWidth * 0.3 || velocity > 500 {
                                    openFileBrowserAnimated()
                                } else {
                                    closeFileBrowserAnimated()
                                }
                            }
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Sheets (Settings, Notes, Voice Call, Folders, Rename, Export)

    private func applySheets<Content: View>(content: Content, voiceCallBinding: Binding<Bool>) -> some View {
        content
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    viewModel: dependencies.authViewModel,
                    appearanceManager: dependencies.appearanceManager
                )
                .preferredColorScheme(dependencies.appearanceManager.resolvedColorScheme ?? systemColorScheme)
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
            .sheet(isPresented: $showNotes) {
                NavigationStack {
                    NotesListView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showNotes = false }
                            }
                        }
                }
            }
            .fullScreenCover(isPresented: $showChannels) {
                NavigationStack {
                    ChannelsListView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showChannels = false }
                            }
                        }
                }
                .environment(dependencies)
                .environment(router)
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
                if !isPresented {
                    router.voiceCallViewModel = nil
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
            // Create folder — shows full settings sheet (name + system prompt + knowledge)
            .sheet(isPresented: $showCreateFolderSheet) {
                CreateFolderSheet(apiClient: dependencies.apiClient) { name, data, meta in
                    let parentId = listViewModel.folderViewModel.createSubfolderParentId
                    listViewModel.folderViewModel.createSubfolderParentId = nil
                    Task {
                        await listViewModel.folderViewModel.createFolder(
                            name: name,
                            parentId: parentId,
                            data: data,
                            meta: meta
                        )
                    }
                }
            }
            // Create folder from folderVM.showCreateSheet (triggered by context menu "Create Folder")
            .onChange(of: listViewModel.folderViewModel.showCreateSheet) { _, show in
                if show {
                    listViewModel.folderViewModel.showCreateSheet = false
                    showCreateFolderSheet = true
                }
            }
            // Edit folder sheet — passes apiClient so it can load knowledge independently
            .sheet(item: Binding(
                get: { listViewModel.folderViewModel.editingFolder },
                set: { listViewModel.folderViewModel.editingFolder = $0 }
            )) { folder in
                EditFolderSheet(
                    folder: folder,
                    apiClient: dependencies.apiClient
                ) { name, data, meta in
                    Task {
                        await listViewModel.folderViewModel.updateFolderSettings(
                            id: folder.id,
                            name: name,
                            data: data,
                            meta: meta
                        )
                    }
                }
            }
            .alert(
                "Rename Folder",
                isPresented: .init(
                    get: { listViewModel.folderViewModel.renamingFolder != nil },
                    set: { if !$0 { listViewModel.folderViewModel.renamingFolder = nil } }
                )
            ) {
                TextField(
                    "Folder Name",
                    text: Bindable(listViewModel.folderViewModel).renameText
                )
                Button("Cancel", role: .cancel) {
                    listViewModel.folderViewModel.renamingFolder = nil
                }
                Button("Rename") {
                    Task { await listViewModel.folderViewModel.commitRename() }
                }
            }
            .sheet(item: $renamingConversation) { conv in
                renameConversationSheet(conv)
            }
            .sheet(isPresented: $showExportShareSheet, onDismiss: {
                if let url = exportFileURL {
                    try? FileManager.default.removeItem(at: url)
                    exportFileURL = nil
                }
            }) {
                if let url = exportFileURL {
                    ShareSheet(items: [url])
                }
            }
            // Share chat sheet
            .sheet(item: $sharingConversation) { conversation in
                if let apiClient = dependencies.apiClient {
                    ShareChatSheet(
                        conversation: conversation,
                        apiClient: apiClient,
                        serverBaseURL: apiClient.baseURL,
                        onShareIdUpdated: { shareId in
                            listViewModel.updateShareId(for: conversation.id, shareId: shareId)
                        },
                        onClone: { cloned in
                            activeConversationId = cloned.id
                            SharedDataService.shared.saveLastActiveConversationId(cloned.id)
                            closeDrawer()
                        }
                    )
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
                }
            }
            // Archived chats sheet
            .sheet(isPresented: $showArchivedChats) {
                ArchivedChatsView()
                    .environment(dependencies)
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
            // Shared chats sheet
            .sheet(isPresented: $showSharedChats) {
                SharedChatsView()
                    .environment(dependencies)
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
            // Workspace sheet
            .sheet(isPresented: $showWorkspace) {
                WorkspaceView()
                    .environment(dependencies)
                    .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
            // Memories sheet
            .sheet(isPresented: $showMemories) {
                NavigationStack {
                    MemoriesView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showMemories = false }
                            }
                        }
                }
                .themed(with: dependencies.appearanceManager, accessibility: dependencies.accessibilityManager)
            }
    }

    // MARK: - Rename Conversation Sheet (extracted for readability)

    @ViewBuilder
    private func renameConversationSheet(_ conv: Conversation) -> some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                TextField("Chat title", text: $renameText)
                    .scaledFont(size: 16)
                    .padding(Spacing.md)
                    .background(theme.surfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

                Button {
                    Task { await generateTitleForRename(conv) }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isGeneratingTitle {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGeneratingTitle ? "Generating…" : "Generate")
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
                    Button("Cancel") { renamingConversation = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !newTitle.isEmpty else { return }
                        listViewModel.renamingConversation = conv
                        listViewModel.renameText = newTitle
                        Task { await listViewModel.commitRename() }
                        renamingConversation = nil
                    }
                    .fontWeight(.semibold)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Confirmation Dialogs & Alerts

    private func applyDialogsAndAlerts<Content: View>(content: Content) -> some View {
        content
            // Archive all confirmation
            .confirmationDialog(
                "Archive All Chats",
                isPresented: $listViewModel.showArchiveAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Archive All", role: .destructive) {
                    Task {
                        await listViewModel.archiveAllConversations()
                        activeConversationId = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will archive all your conversations. You can unarchive them later from the web interface.")
            }
            // Delete all confirmation
            .confirmationDialog(
                "Delete All Chats",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    Task {
                        await listViewModel.deleteAllConversations()
                        activeConversationId = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all your conversations. This action cannot be undone.")
            }
            // Delete selected confirmation
            .confirmationDialog(
                "Delete Selected Chats",
                isPresented: $showDeleteSelectedConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(listViewModel.selectedCount) Chat\(listViewModel.selectedCount == 1 ? "" : "s")", role: .destructive) {
                    if let activeId = activeConversationId,
                       listViewModel.selectedConversationIds.contains(activeId) {
                        activeConversationId = nil
                    }
                    Task { await listViewModel.deleteSelectedConversations() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete \(listViewModel.selectedCount) selected conversation\(listViewModel.selectedCount == 1 ? "" : "s"). This action cannot be undone.")
            }
            // Single-conversation delete confirmation
            .confirmationDialog(
                "Delete \"\(deletingConversation?.title ?? "")\"?",
                isPresented: .init(
                    get: { deletingConversation != nil },
                    set: { if !$0 { deletingConversation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let conv = deletingConversation {
                        let deletedId = conv.id
                        deletingConversation = nil
                        Task {
                            await listViewModel.deleteConversation(id: deletedId)
                            if activeConversationId == deletedId {
                                activeConversationId = nil
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    deletingConversation = nil
                }
            } message: {
                Text("This action cannot be undone.")
            }
            // Channel delete confirmation
            .confirmationDialog(
                "Delete Channel?",
                isPresented: .init(
                    get: { deletingChannelId != nil },
                    set: { if !$0 { deletingChannelId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Channel", role: .destructive) {
                    if let channelId = deletingChannelId {
                        deletingChannelId = nil
                        if activeChannelId == channelId { activeChannelId = nil }
                        Task {
                            try? await dependencies.apiClient?.deleteChannel(id: channelId)
                            await channelListVM.refreshChannels()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    deletingChannelId = nil
                }
            } message: {
                Text("This will permanently delete this channel and all its messages.")
            }
            // Export error alert
            .alert("Export Failed", isPresented: .init(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportError ?? "") }
    }

    // MARK: - Lifecycle Handlers (.task, .onChange, .onReceive)

    private func applyLifecycleHandlers<Content: View>(content: Content) -> some View {
        content
            .task {
                if let manager = dependencies.conversationManager {
                    listViewModel.configure(with: manager)
                }
                if let folderManager = dependencies.folderManager {
                    listViewModel.folderViewModel.configure(with: folderManager)
                }
                // Configure and load channels — must pass currentUserId for DM participant filtering
                if let apiClient = dependencies.apiClient {
                    var userId = dependencies.authViewModel.currentUser?.id
                    if userId == nil || userId?.isEmpty == true {
                        userId = try? await apiClient.getCurrentUser().id
                    }
                    channelListVM.configure(apiClient: apiClient, socket: dependencies.socketService, currentUserId: userId)
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.loadConversations() }
                    group.addTask { await listViewModel.folderViewModel.loadFolders() }
                    group.addTask { await dependencies.fetchTaskConfig() }
                    group.addTask { await channelListVM.loadChannels() }
                }
                registerSocketReconnectHandler()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active && oldPhase != .active {
                    Task { await refreshAllDataOnForeground() }
                }
            }
            .onChange(of: activeConversationId) { _, _ in
                // Reset terminal file browser when switching conversations
                // so it doesn't show stale state from the previous chat
                if showFileBrowser { closeFileBrowserAnimated() }
                terminalBrowserVM.reset()
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
            .onReceive(NotificationCenter.default.publisher(for: .conversationTitleUpdated)) { notification in
                guard let userInfo = notification.userInfo,
                      let conversationId = userInfo["conversationId"] as? String,
                      let title = userInfo["title"] as? String
                else { return }
                listViewModel.updateTitle(for: conversationId, title: title)
                let folderVM = listViewModel.folderViewModel
                for idx in folderVM.folders.indices {
                    if let chatIdx = folderVM.folders[idx].chats.firstIndex(where: { $0.id == conversationId }) {
                        folderVM.folders[idx].chats[chatIdx].title = title
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .adminClonedChat)) { notification in
                if let conversationId = notification.object as? String {
                    showSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        activeConversationId = conversationId
                        SharedDataService.shared.saveLastActiveConversationId(conversationId)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToChannel)) { notification in
                if let channelId = notification.object as? String {
                    activeChannelId = channelId
                    activeConversationId = nil
                    Haptics.play(.light)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIDismissOverlays)) { _ in
                // Quick action requested — dismiss any active sheet/cover so
                // the new action doesn't stack on top of the old one.
                showSettings = false
                showNotes = false
                showChannels = false
                showCreateChannel = false
                showCreateFolderSheet = false
                showExportShareSheet = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUINewChannel)) { _ in
                // Widget "Channel" button — open the create-channel sheet
                showCreateChannel = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUINewChatWithFocus)) { _ in
                // Widget "Ask Open Relay" bar — start new chat and auto-focus keyboard
                startNewChat()
                // Give the view time to settle before requesting keyboard focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .chatInputFieldRequestFocus, object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openUIWidgetVoiceCall)) { _ in
                // Widget mic button — start a voice call with full configuration
                // (mirrors ChatDetailView's startVoiceCall pattern)
                let voiceCallVM = dependencies.makeVoiceCallViewModel()
                let chatVM = dependencies.activeChatStore.viewModel(for: nil)
                if let manager = dependencies.conversationManager {
                    let modelName = dependencies.activeChatStore.cachedModels
                        .first(where: { $0.id == dependencies.activeChatStore.cachedSelectedModelId })?.name
                        ?? "AI Assistant"
                    voiceCallVM.configure(
                        conversationManager: manager,
                        chatViewModel: chatVM,
                        modelName: modelName
                    )
                }
                router.presentVoiceCall(viewModel: voiceCallVM)
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversationListNeedsRefresh)) { _ in
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await listViewModel.refreshConversations() }
                        group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                    }
                }
            }
    }

    // MARK: - Progress Overlays

    private func applyOverlays<Content: View>(content: Content) -> some View {
        content
            .overlay {
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Preparing export…")
                                .scaledFont(size: 16)
                                .foregroundStyle(.white)
                        }
                        .padding(Spacing.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if listViewModel.isDeletingBulk {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        VStack(spacing: Spacing.md) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Deleting…")
                                .scaledFont(size: 16)
                                .foregroundStyle(.white)
                        }
                        .padding(Spacing.xl)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
    }

    // MARK: - Drawer Toggle

    private func toggleDrawer() {
        if showDrawer {
            closeDrawerAnimated()
        } else {
            openDrawerAnimated()
        }
    }

    private func closeDrawer() {
        closeDrawerAnimated()
    }

    /// Animates the drawer to fully open, resets drag offset, triggers haptic + refresh.
    private func openDrawerAnimated() {
        // Dismiss keyboard immediately so it doesn't overlap the drawer
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showDrawer = true
            dragOffset = 0
        }
        Haptics.play(.light)
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await listViewModel.refreshIfStale() }
                group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                group.addTask { await channelListVM.refreshChannels() }
            }
        }
    }

    /// Animates the drawer to fully closed and resets drag offset.
    private func closeDrawerAnimated() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showDrawer = false
            dragOffset = 0
        }
    }

    // MARK: - File Browser Open/Close (right panel, mirrors drawer)

    /// Configures the terminal browser VM with the active chat's terminal server.
    private func configureTerminalBrowserIfNeeded() {
        guard let apiClient = dependencies.apiClient else { return }
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        guard vm.terminalEnabled, let server = vm.selectedTerminalServer else { return }
        terminalBrowserVM.configure(apiClient: apiClient, serverId: server.id)
    }

    /// Animates the file browser to fully open.
    private func openFileBrowserAnimated() {
        configureTerminalBrowserIfNeeded()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showFileBrowser = true
            fileBrowserDragOffset = 0
        }
        // Explicitly load directory after opening to ensure files appear
        // (the .task modifier may have fired before configure() was called)
        terminalBrowserVM.refresh()
        Haptics.play(.light)
    }

    /// Animates the file browser to fully closed.
    private func closeFileBrowserAnimated() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showFileBrowser = false
            fileBrowserDragOffset = 0
        }
    }

    // MARK: - New Chat

    private func startNewChat() {
        // If we're already on the new-chat screen AND a transcription is in
        // progress, stay put — destroying the VM would silently discard the work.
        let alreadyOnNewChat = activeConversationId == nil && activeChannelId == nil
        let currentNewVM = dependencies.activeChatStore.viewModel(for: nil)
        if alreadyOnNewChat && currentNewVM.hasActiveTranscriptions {
            return
        }

        // If we're NOT already on the new-chat screen, just navigate there
        // without resetting the VM — the transcription can keep running.
        // Only remove + recreate the VM when there's no ongoing work.
        if !currentNewVM.hasActiveTranscriptions {
            dependencies.activeChatStore.remove(nil)
            newChatGeneration += 1
        }

        activeConversationId = nil
        activeChannelId = nil
        activeFolderWorkspaceId = nil
        // Reset terminal file browser state so it starts fresh in the new chat
        closeFileBrowserAnimated()
        terminalBrowserVM.reset()
        Haptics.play(.light)
    }

    // MARK: - Chat Content

    @ViewBuilder
    private var chatContent: some View {
        if let channelId = activeChannelId {
            // Show channel detail inline (same as how chats work)
            ChannelDetailView(channelId: channelId)
                .id("channel-\(channelId)")
                .transition(.opacity)
        } else if let conversationId = activeConversationId {
            ChatDetailView(
                conversationId: conversationId,
                viewModel: dependencies.activeChatStore.viewModel(for: conversationId)
            )
            .id(conversationId)
            .transition(.opacity)
        } else if let folderWorkspaceId = activeFolderWorkspaceId {
            // Folder workspace: new chat screen locked to this folder.
            // The ChatViewModel receives folder context so when the user
            // sends a message the chat is created inside this folder.
            let vm = dependencies.activeChatStore.viewModel(for: nil)
            let folder = listViewModel.folderViewModel.folders.first { $0.id == folderWorkspaceId }
                ?? listViewModel.folderViewModel.activeFolderDetail
            ChatDetailView(
                viewModel: vm,
                folderWorkspace: folder
            )
            .id("folder-workspace-\(folderWorkspaceId)-\(newChatGeneration)")
            .transition(.opacity)
            .onAppear {
                // Set folder context on the VM so new chats are created in this folder
                let folderDetail = listViewModel.folderViewModel.activeFolderDetail
                vm.setFolderContext(
                    folderId: folderWorkspaceId,
                    systemPrompt: folderDetail?.systemPrompt
                        ?? folder?.systemPrompt,
                    modelIds: folderDetail?.modelIds
                        ?? folder?.modelIds
                        ?? []
                )
            }
        } else {
            ChatDetailView(
                viewModel: dependencies.activeChatStore.viewModel(for: nil)
            )
            .id("new-chat-\(newChatGeneration)")
            .transition(.opacity)
        }
    }

    // MARK: - Model Selector

    private var modelSelector: some View {
        MainModelSelectorLabel(
            conversationId: activeConversationId,
            activeChatStore: dependencies.activeChatStore,
            theme: theme
        )
    }

    // MARK: - Drawer Content

    private var drawerContent: some View {
        VStack(spacing: 0) {
            // Top bar: search or selection controls
            if listViewModel.isSelectionMode {
                selectionModeHeader
            } else {
                searchBar
            }

            // Conversation list grouped by time
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // ── PINNED MODELS SECTION (quick-switch shortcuts) ─
                    drawerPinnedModelsSection

                    // ── FOLDERS SECTION (always visible so user can create new folders) ─
                    let folderVM = listViewModel.folderViewModel
                    if !folderVM.featureDisabled {
                        drawerFoldersSection(folderVM: folderVM)
                    }

                    // ── DIVIDER between Folders & Channels ──────────────
                    let channelsEnabled = dependencies.authViewModel.backendConfig?.features?.enableChannels != false
                    if (!folderVM.featureDisabled && !folderVM.folders.isEmpty) || (channelsEnabled && !channelListVM.channels.isEmpty) {
                        Rectangle()
                            .fill(theme.textTertiary.opacity(0.15))
                            .frame(height: 1)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                    }

                    // ── CHANNELS SECTION (shown only when enabled on server) ──
                    if channelsEnabled {
                    VStack(alignment: .leading, spacing: 0) {
                        // Collapsible header
                        Button {
                            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                                channelsExpanded.toggle()
                            }
                            Haptics.play(.light)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.down")
                                    .scaledFont(size: 8, weight: .bold)
                                    .foregroundStyle(theme.textTertiary)
                                    .rotationEffect(.degrees(channelsExpanded ? 0 : -90))
                                    .animation(.easeInOut(duration: AnimDuration.fast), value: channelsExpanded)

                                Image(systemName: "bubble.left.and.bubble.right")
                                    .scaledFont(size: 10, weight: .semibold)
                                    .foregroundStyle(theme.textTertiary)
                                Text("Channels")
                                    .scaledFont(size: 12, weight: .medium)
                                    .fontWeight(.bold)
                                    .foregroundStyle(theme.textTertiary)
                                    .textCase(.uppercase)
                                    .tracking(0.5)
                                Spacer()

                                // Create new channel directly (always visible)
                                Button {
                                    closeDrawer()
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if channelsExpanded {
                            if channelListVM.channels.isEmpty {
                                Text("No channels yet")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, 4)
                            } else {
                                // DMs first
                                if !channelListVM.dmChannels.isEmpty {
                                    drawerChannelGroupLabel("Direct Messages", icon: "person.crop.circle")
                                    ForEach(channelListVM.dmChannels) { channel in
                                        drawerChannelRow(channel)
                                    }
                                }
                                // Groups
                                if !channelListVM.groupChannels.isEmpty {
                                    drawerChannelGroupLabel("Groups", icon: "person.3")
                                    ForEach(channelListVM.groupChannels) { channel in
                                        drawerChannelRow(channel)
                                    }
                                }
                                // Standard channels
                                if !channelListVM.standardChannels.isEmpty {
                                    drawerChannelGroupLabel("Channels", icon: "number")
                                    ForEach(channelListVM.standardChannels) { channel in
                                        drawerChannelRow(channel)
                                    }
                                }
                            }
                        }
                    }
                    } // end if channelsEnabled

                    // ── DIVIDER between Channels & Chats ──────────────
                    Rectangle()
                        .fill(theme.textTertiary.opacity(0.15))
                        .frame(height: 1)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)

                    // ── CHATS SECTION (entire section is a drop zone) ─
                    let hasAnyChats = !listViewModel.pinnedConversations.isEmpty
                        || !listViewModel.groupedConversations.isEmpty

                    if hasAnyChats || !folderVM.folders.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            // Collapsible header (also acts as drop zone indicator)
                            Button {
                                withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                                    chatsExpanded.toggle()
                                }
                                Haptics.play(.light)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.down")
                                        .scaledFont(size: 8, weight: .bold)
                                        .foregroundStyle(drawerChatsDropActive ? theme.brandPrimary : theme.textTertiary)
                                        .rotationEffect(.degrees(chatsExpanded ? 0 : -90))
                                        .animation(.easeInOut(duration: AnimDuration.fast), value: chatsExpanded)

                                    Image(systemName: "bubble.left.and.text.bubble.right")
                                        .scaledFont(size: 10, weight: .semibold)
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
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if chatsExpanded {
                                // Pinned
                                if !listViewModel.pinnedConversations.isEmpty {
                                    CollapsibleDrawerSection(title: "Pinned") {
                                        ForEach(listViewModel.pinnedConversations) { conversation in
                                            drawerConversationRow(conversation)
                                        }
                                    }
                                }

                                // Time-grouped
                                ForEach(listViewModel.groupedConversations, id: \.0) { group in
                                    CollapsibleDrawerSection(title: group.0, count: group.1.count) {
                                        ForEach(group.1) { conversation in
                                            drawerConversationRow(conversation)
                                        }
                                    }
                                }
                            }
                        }
                        .background(
                            drawerChatsDropActive
                                ? theme.brandPrimary.opacity(0.06)
                                : Color.clear
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.md)
                                .stroke(theme.brandPrimary, lineWidth: drawerChatsDropActive ? 1.5 : 0)
                                .padding(.horizontal, 2)
                        )
                        .animation(.easeInOut(duration: AnimDuration.fast), value: drawerChatsDropActive)
                        .dropDestination(for: DraggableChat.self) { items, _ in
                            guard let item = items.first,
                                  item.currentFolderId != nil else { return false }
                            let chatId = item.conversationId
                            let folderChats = folderVM.folders.flatMap(\.chats)
                            let conversation = folderChats.first(where: { $0.id == chatId })
                                ?? listViewModel.conversations.first(where: { $0.id == chatId })
                            guard let conversation else { return false }

                            withAnimation {
                                drawerChatsDropActive = false
                                folderVM.dragCompleted()
                            }
                            // Update folderId locally — add to conversations list if missing
                            if let idx = listViewModel.conversations.firstIndex(where: { $0.id == chatId }) {
                                listViewModel.conversations[idx].folderId = nil
                            } else {
                                var conv = conversation
                                conv.folderId = nil
                                listViewModel.conversations.insert(conv, at: 0)
                            }
                            Task { await folderVM.moveChat(conversation: conversation, to: nil) }
                            return true
                        } isTargeted: { isTargeted in
                            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                                drawerChatsDropActive = isTargeted
                            }
                        }
                    }
                }
                .padding(.bottom, Spacing.md)
            }

            Spacer(minLength: 0)

            if listViewModel.isSelectionMode {
                selectionModeBottomBar
            } else {
                drawerBottomBar
            }
        }
        .background(theme.background)
    }

    // MARK: - Selection Mode Header

    private var selectionModeHeader: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    listViewModel.exitSelectionMode()
                }
            } label: {
                Text("Cancel")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.brandPrimary)
            }

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
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textTertiary)

            TextField("Search conversations...", text: $listViewModel.searchText)
                .scaledFont(size: 16)
                .foregroundStyle(theme.textPrimary)

            if !listViewModel.searchText.isEmpty {
                Button {
                    listViewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textTertiary)
                }
            }

            if !listViewModel.conversations.isEmpty {
                Menu {
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
                        Label("Archive All Chats", systemImage: "archivebox")
                    }

                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Chats", systemImage: "trash")
                    }

                    Divider()

                    Button {
                        closeDrawer()
                        showArchivedChats = true
                    } label: {
                        Label("Archived Chats", systemImage: "archivebox")
                    }

                    Button {
                        closeDrawer()
                        showSharedChats = true
                    } label: {
                        Label("Shared Chats", systemImage: "link.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }

            Button {
                closeDrawer()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Drawer Section

    @ViewBuilder
    private func drawerSection<Content: View>(
        title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.down")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)

                Text(title)
                    .scaledFont(size: 14, weight: .medium)
                    .fontWeight(.semibold)
                    .foregroundStyle(theme.textSecondary)

                if let count {
                    Text("\(count)")
                        .scaledFont(size: 12, weight: .medium)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.surfaceContainer)
                        .clipShape(Capsule())
                }

                Spacer()

                if systemImage == "folder" {
                    Button {} label: {
                        Image(systemName: "folder.badge.plus")
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            content()
        }
    }

    // MARK: - Drawer Pinned Models Section

    /// Shows pinned models as quick-switch shortcuts in the sidebar,
    /// matching the web UI's "Models" section above folders.
    @ViewBuilder
    private var drawerPinnedModelsSection: some View {
        let vm = dependencies.activeChatStore.viewModel(for: activeConversationId)
        let pinnedIds = vm.pinnedModelIds
        let models = vm.availableModels
        let pinnedModels = pinnedIds.compactMap { id in models.first(where: { $0.id == id }) }

        if !pinnedModels.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Section header
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                    Text("Models")
                        .scaledFont(size: 12, weight: .medium)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

                // Pinned model rows
                ForEach(pinnedModels) { model in
                    let isSelected = model.id == vm.selectedModelId
                    Button {
                        let modelId = model.id
                        startNewChat()
                        let newVM = dependencies.activeChatStore.viewModel(for: nil)
                        newVM.selectModel(modelId)
                        closeDrawer()
                    } label: {
                        HStack(spacing: 8) {
                            ModelAvatar(
                                size: 22,
                                imageURL: vm.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: vm.serverAuthToken
                            )
                            Text(model.shortName)
                                .scaledFont(size: 14)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .scaledFont(size: 11, weight: .semibold)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 7)
                        .background(isSelected ? theme.brandPrimary.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Divider below models
            Rectangle()
                .fill(theme.textTertiary.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
        }
    }

    // MARK: - Drawer Folders Section

    @ViewBuilder
    private func drawerFoldersSection(folderVM: FolderListViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header with collapse toggle + "New Folder" button
            Button {
                withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                    foldersExpanded.toggle()
                }
                Haptics.play(.light)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .scaledFont(size: 8, weight: .bold)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(foldersExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: AnimDuration.fast), value: foldersExpanded)

                    Image(systemName: "folder")
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)

                    Text("Folders")
                        .scaledFont(size: 12, weight: .medium)
                        .fontWeight(.bold)
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()

                    Button {
                        showCreateFolderSheet = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Folder rows — use rootFolders (tree with childFolders populated)
            if foldersExpanded {
                ForEach(folderVM.rootFolders) { folder in
                    DrawerFolderRow(
                        folder: folder,
                        folderVM: folderVM,
                        allConversations: listViewModel.conversations,
                        activeConversationId: activeConversationId,
                        activeFolderWorkspaceId: activeFolderWorkspaceId,
                        onSelectChat: { chatId in
                            activeConversationId = chatId
                            activeFolderWorkspaceId = nil
                            SharedDataService.shared.saveLastActiveConversationId(chatId)
                            closeDrawer()
                        },
                        onSelectFolder: { folderId in
                            Task { await folderVM.setActiveFolder(folderId) }
                            dependencies.activeChatStore.remove(nil)
                            newChatGeneration += 1
                            activeFolderWorkspaceId = folderId
                            activeConversationId = nil
                            activeChannelId = nil
                            closeDrawer()
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
                                for fIdx in folderVM.folders.indices {
                                    folderVM.folders[fIdx].chats.removeAll { $0.id == chatId }
                                }
                                if activeConversationId == chatId {
                                    activeConversationId = nil
                                }
                            }
                        },
                        onTogglePin: { conversation in
                            Task { await listViewModel.togglePin(conversation: conversation) }
                        }
                    )
                    .padding(.horizontal, Spacing.sm)
                }
            }
        }
        .animation(.easeInOut(duration: AnimDuration.medium), value: folderVM.folders.map(\.id))
    }

    // MARK: - Drawer Channel Helpers

    /// Small sub-group label (e.g. "Direct Messages", "Groups", "Channels") inside the channels section.
    @ViewBuilder
    private func drawerChannelGroupLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 9, weight: .medium)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
            Text(title)
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(theme.textTertiary.opacity(0.7))
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// A single channel row in the drawer sidebar.
    @ViewBuilder
    private func drawerChannelRow(_ channel: Channel) -> some View {
        Button {
            activeChannelId = channel.id
            activeConversationId = nil
            closeDrawer()
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
                Text(channel.type == .dm
                    ? (channel.dmParticipants.first?.displayName ?? channel.displayName)
                    : channel.displayName)
                    .scaledFont(size: 14)
                    .fontWeight(activeChannelId == channel.id || channel.unreadCount > 0 ? .semibold : .regular)
                    .foregroundStyle(activeChannelId == channel.id ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                Spacer()
                if channel.unreadCount > 0 {
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
                    ? theme.brandPrimary.opacity(0.08)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if channel.type == .dm {
                Button {
                    channelListVM.hideDM(channelId: channel.id)
                    Haptics.play(.light)
                } label: {
                    Label("Hide Conversation", systemImage: "eye.slash")
                }
            } else {
                Button(role: .destructive) {
                    deletingChannelId = channel.id
                } label: {
                    Label("Delete Channel", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Drawer Conversation Row

    private func drawerConversationRow(_ conversation: Conversation) -> some View {
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
                            ? "checkmark.circle.fill"
                            : "circle"
                        )
                        .scaledFont(size: 18)
                        .foregroundStyle(
                            listViewModel.isSelected(conversation.id)
                                ? theme.brandPrimary
                                : theme.textTertiary
                        )

                        Text(conversation.title)
                            .scaledFont(size: 14)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                        listViewModel.isSelected(conversation.id)
                            ? theme.brandPrimary.opacity(0.1)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    activeConversationId = conversation.id
                    activeChannelId = nil  // Clear channel when opening a chat
                    activeFolderWorkspaceId = nil  // Clear folder highlight when opening a regular chat
                    SharedDataService.shared.saveLastActiveConversationId(conversation.id)
                    closeDrawer()
                } label: {
                    HStack {
                        Text(conversation.title)
                            .scaledFont(size: 14)
                            .fontWeight(activeConversationId == conversation.id ? .semibold : .regular)
                            .foregroundStyle(
                                activeConversationId == conversation.id
                                    ? theme.textPrimary
                                    : theme.textSecondary
                            )
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 7)
                    .background(
                        activeConversationId == conversation.id
                            ? theme.brandPrimary.opacity(0.08)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Make draggable into a folder
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
                    // Share
                    Button {
                        sharingConversation = conversation
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    // Download submenu (matching WebUI)
                    Menu {
                        Button {
                            Task { await exportChat(conversation, format: .json) }
                        } label: {
                            Label("Export chat (.json)", systemImage: "doc")
                        }
                        Button {
                            Task { await exportChat(conversation, format: .txt) }
                        } label: {
                            Label("Plain text (.txt)", systemImage: "doc.plaintext")
                        }
                        Button {
                            Task { await exportChat(conversation, format: .pdf) }
                        } label: {
                            Label("PDF document (.pdf)", systemImage: "doc.richtext")
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }

                    // Rename
                    Button {
                        renamingConversation = conversation
                        renameText = conversation.title
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    // Pin
                    Button {
                        Task { await listViewModel.togglePin(conversation: conversation) }
                    } label: {
                        Label(
                            conversation.pinned ? "Unpin" : "Pin",
                            systemImage: conversation.pinned ? "pin.slash" : "pin"
                        )
                    }

                    // Clone
                    Button {
                        Task {
                            guard let manager = dependencies.conversationManager else { return }
                            let cloned = try? await manager.cloneConversation(id: conversation.id)
                            if let cloned {
                                await listViewModel.refreshConversations()
                                activeConversationId = cloned.id
                                closeDrawer()
                            }
                        }
                    } label: {
                        Label("Clone", systemImage: "doc.on.doc")
                    }

                    // Archive
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

                    // Move to folder submenu
                    let folders = listViewModel.folderViewModel.folders
                    if !folders.isEmpty {
                        Menu("Move to Folder") {
                            if conversation.folderId != nil {
                                Button {
                                    let conv = conversation
                                    Task {
                                        await listViewModel.folderViewModel.moveChat(conversation: conv, to: nil)
                                        if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                            listViewModel.conversations[idx].folderId = nil
                                        }
                                    }
                                } label: {
                                    Label("Remove from Folder", systemImage: "folder.badge.minus")
                                }
                            }
                            ForEach(folders) { folder in
                                Button {
                                    let conv = conversation
                                    let folderId = folder.id
                                    Task {
                                        await listViewModel.folderViewModel.moveChat(conversation: conv, to: folderId)
                                        if let idx = listViewModel.conversations.firstIndex(where: { $0.id == conv.id }) {
                                            listViewModel.conversations[idx].folderId = folderId
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

                    // Delete
                    Button(role: .destructive) {
                        deletingConversation = conversation
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Selection Mode Bottom Bar

    private var selectionModeBottomBar: some View {
        Button(role: .destructive) {
            showDeleteSelectedConfirmation = true
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "trash")
                Text("Delete Selected (\(listViewModel.selectedCount))")
            }
            .scaledFont(size: 14, weight: .medium)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(
                listViewModel.selectedCount > 0
                    ? Color.red
                    : Color.red.opacity(0.3)
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        }
        .disabled(listViewModel.selectedCount == 0)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
        .background(theme.surfaceContainer.opacity(0.3))
    }

    // MARK: - Drawer Bottom Bar

    private var drawerBottomBar: some View {
        VStack(spacing: 0) {
            // Subtle top separator
            Rectangle()
                .fill(theme.textTertiary.opacity(0.12))
                .frame(height: 0.5)

            HStack(spacing: Spacing.sm) {
                // User avatar + full name — taps to Settings/Profile
                Button {
                    closeDrawer()
                    showSettings = true
                } label: {
                    HStack(spacing: 10) {
                        UserAvatar(
                            size: 32,
                            imageURL: {
                                guard let userId = dependencies.authViewModel.currentUser?.id,
                                      let baseURL = dependencies.apiClient?.baseURL,
                                      !userId.isEmpty, !baseURL.isEmpty else { return nil }
                                return URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image")
                            }(),
                            name: dependencies.authViewModel.currentUser?.displayName ?? "User",
                            authToken: dependencies.apiClient?.network.authToken
                        )

                        Text(dependencies.authViewModel.currentUser?.displayName ?? "User")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                // New Chat — primary action, always visible
                Button {
                    closeDrawer()
                    startNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("New Chat")

                // More menu — secondary actions tucked away cleanly
                Menu {
                    Button {
                        closeDrawer()
                        showMemories = true
                    } label: {
                        Label("Memories", systemImage: "brain.head.profile")
                    }
                    Button {
                        showWorkspace = true
                    } label: {
                        Label("Workspace", systemImage: "square.grid.2x2")
                    }

                    if dependencies.authViewModel.backendConfig?.features?.enableNotes != false {
                        Button {
                            closeDrawer()
                            showNotes = true
                        } label: {
                            Label("Notes", systemImage: "note.text")
                        }
                    }

                    Divider()

                    Button {
                        closeDrawer()
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .scaledFont(size: 18, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
        }
        .background(theme.background)
    }

    // MARK: - Title Generation

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
        } catch {
            // Silently fail — keep current text
        }
        isGeneratingTitle = false
    }

    // MARK: - Chat Export

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
                // Use the server's raw message format for PDF generation.
                // The API fetches the full chat JSON and passes native messages
                // to the PDF renderer, avoiding any format mismatches.
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

    // MARK: - Foreground Refresh

    private func refreshAllDataOnForeground() async {
        // Use connect() without force so an already-in-progress connection
        // is NOT cancelled. connect(force:true) calls disconnectInternal()
        // which cancels the current URLSessionWebSocketTask, causing
        // "Receive error: cancelled" → handleDisconnect → autoReconnect →
        // connect(force:true) → infinite reconnect loop.
        if let socket = dependencies.socketService, !socket.isConnected, !socket.isConnecting {
            socket.connect()
        }

        // Refresh both conversations and folders in parallel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await listViewModel.refreshIfStale() }
            group.addTask { await listViewModel.folderViewModel.refreshFolders() }
        }

        // Do NOT call loadConversation() here — it sets isLoadingConversation=true
        // which tears down the entire message list and replaces it with skeleton
        // placeholders, destroying scroll position and causing the avatar flash.
        //
        // ChatViewModel.startForegroundSyncListener() (registered during load())
        // already handles foreground sync via syncWithServer(), which uses
        // adoptServerMessages() for in-place surgical updates — no view recreation,
        // no scroll jump, no flash.
        //
        // Similarly do NOT reload models/tools — they're loaded once on init and
        // refreshed lazily before each send via refreshSelectedModelMetadata().

        dependencies.updateWidgetData(conversations: listViewModel.conversations)
    }

    // MARK: - Socket Reconnect Handler

    private func registerSocketReconnectHandler() {
        guard !hasRegisteredSocketHandlers else { return }
        hasRegisteredSocketHandlers = true

        dependencies.socketService?.onReconnect = { [self] in
            Task { @MainActor in
                // Refresh both conversations and folders in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                }
                // Use syncWithServer() instead of loadConversation() —
                // syncWithServer() does in-place updates via adoptServerMessages()
                // and does NOT set isLoadingConversation=true, so the message list
                // stays stable (no flash, no scroll jump).
                if let activeId = activeConversationId {
                    let vm = dependencies.activeChatStore.viewModel(for: activeId)
                    if !vm.isStreaming {
                        await vm.syncWithServer()
                    }
                }
            }
        }

        dependencies.socketService?.onConnect = { [self] in
            Task { @MainActor in
                // Refresh both conversations and folders in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await listViewModel.refreshIfStale() }
                    group.addTask { await listViewModel.folderViewModel.refreshFolders() }
                }
            }
        }
    }
}

// MARK: - Model Selector Label (Extracted to avoid re-computing viewModel in MainChatView body)

/// A lightweight view that reads the active chat's model info
/// only when it actually needs to render. This avoids the parent
/// `MainChatView` body from accessing `ActiveChatStore.viewModel(for:)`
/// on every evaluation.
private struct MainModelSelectorLabel: View {
let conversationId: String?
    let activeChatStore: ActiveChatStore
    let theme: AppTheme

    @Environment(AppDependencyContainer.self) private var dependencies

    @State private var isShowingModelSelectorSheet = false
    @State private var editingModelDetail: ModelDetail? = nil

    private var vm: ChatViewModel {
        activeChatStore.viewModel(for: conversationId)
    }

    var body: some View {
        Group {
            if vm.availableModels.isEmpty {
                Text("New Chat")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            } else {
                Button {
                    vm.refreshModelsInBackground()
                    isShowingModelSelectorSheet = true
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if let model = vm.selectedModel {
                            ModelAvatar(
                                size: 22,
                                imageURL: vm.resolvedImageURL(for: model),
                                label: model.shortName,
                                authToken: vm.serverAuthToken
                            )
                            .fixedSize()
                        }
                        Text(vm.selectedModel?.shortName ?? "Select Model")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: 160, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingModelSelectorSheet) {
                    ModelSelectorSheet(
                        models: vm.availableModels,
                        selectedModelId: vm.selectedModelId,
                        serverBaseURL: vm.serverBaseURL,
                        authToken: vm.serverAuthToken,
                        isAdmin: dependencies.authViewModel.currentUser?.role == .admin,
                        pinnedModelIds: vm.pinnedModelIds,
                        onEdit: dependencies.authViewModel.currentUser?.role == .admin ? { model in
                            isShowingModelSelectorSheet = false
                            Task { await openModelEditor(for: model) }
                        } : nil,
                        onTogglePin: { modelId in
                            vm.togglePinModel(modelId)
                        },
                        onSelect: { model in
                            vm.selectModel(model.id)
                        }
                    )
                    .themed()
                }
                .sheet(item: $editingModelDetail) { detail in
                    NavigationStack {
                        ModelEditorView(existingModel: detail) { _ in
                            Task { vm.refreshModelsInBackground() }
                            editingModelDetail = nil
                        }
                    }
                    .themed()
                }
            }
        }
    }

    private func openModelEditor(for model: AIModel) async {
        guard let apiClient = dependencies.apiClient else { return }
        if let detail = try? await apiClient.getWorkspaceModelDetail(id: model.id) {
            editingModelDetail = detail
        }
    }
}
