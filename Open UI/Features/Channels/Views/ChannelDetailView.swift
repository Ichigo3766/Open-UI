import SwiftUI
import PhotosUI
import QuickLook
import MarkdownView

/// Channel chat view with:
/// - Markdown rendering for all message content
/// - Rich mention highlighting (user/model/self badges)
/// - Enhanced reply previews with colored borders
/// - Unified attachment picker with photo browsing
/// - Image grid layout for multi-image messages
/// - Slack/Discord-inspired left-aligned message layout
struct ChannelDetailView: View {
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    
    @State private var viewModel: ChannelViewModel
    @State private var scrollPosition = ScrollPosition()
    @State private var isScrolledUp = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var keyboard = KeyboardTracker()
    
    // @mention picker
    @State private var isShowingMentionPicker = false
    @State private var mentionQuery = ""
    
    // #channel picker
    @State private var isShowingChannelPicker = false
    @State private var channelQuery = ""
    
    // Attachments — unified picker
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showAttachmentPicker = false
    @State private var showFilePicker = false
    
    // Message actions
    @State private var activeActionMessageId: String?
    
    // Emoji picker + reaction overlay
    @State private var showEmojiKeyboard = false
    @State private var emojiTargetMessageId: String?
    @State private var reactionOverlayMessage: ChannelMessage?
    
    // Reaction tooltip (MF-003)
    @State private var reactionTooltipText: String?
    @State private var showReactionTooltip = false
    
    // QuickLook for file preview
    @State private var quickLookURL: URL?
    @State private var isLoadingFile = false
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""
    
    // Channel settings
    @State private var showChannelSettings = false
    
    // Error alerts (SEC-005 fix)
    @State private var showOperationError = false
    @State private var operationErrorMessage = ""
    
    init(channelId: String) {
        self._viewModel = State(initialValue: ChannelViewModel(channelId: channelId))
    }
    
    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            messageListArea
            
            if let msg = reactionOverlayMessage {
                let isOwn = msg.userId == viewModel.currentUserId && !viewModel.isModelMessage(msg)
                MessageReactionOverlay(
                    message: msg,
                    isCurrentUser: isOwn,
                    onReaction: { emoji in
                        Task { await viewModel.toggleReaction(messageId: msg.id, emoji: emoji) }
                        withAnimation(.easeOut(duration: 0.2)) { reactionOverlayMessage = nil }
                    },
                    onReply: {
                        viewModel.setReplyTo(msg)
                    },
                    onThread: {
                        Task { await viewModel.openThread(for: msg) }
                    },
                    onPin: {
                        Task { await viewModel.togglePin(messageId: msg.id) }
                    },
                    onCopy: {
                        viewModel.copyMessage(msg)
                    },
                    onEdit: isOwn ? {
                        viewModel.beginEditing(message: msg)
                    } : nil,
                    onDelete: isOwn ? {
                        Task { await viewModel.deleteMessage(id: msg.id) }
                    } : nil,
                    onMoreEmoji: {
                        let targetId = msg.id
                        withAnimation(.easeOut(duration: 0.2)) { reactionOverlayMessage = nil }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            emojiTargetMessageId = targetId
                            showEmojiKeyboard = true
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) { reactionOverlayMessage = nil }
                    }
                )
                .animation(.easeOut(duration: 0.2), value: reactionOverlayMessage?.id)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let replyMsg = viewModel.replyToMessage {
                    replyPreviewBar(replyMsg)
                }
                if viewModel.mentionedModelName != nil {
                    modelMentionBar
                }
                // MF-005: Only show input if user has write access
                if viewModel.hasWriteAccess {
                    channelInputField
                } else {
                    readOnlyBanner
                }
            }
            .background(theme.background)
            .padding(.bottom, keyboard.height)
        }
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .bottom) {
            if isShowingChannelPicker {
                ChannelLinkPickerView(
                    query: channelQuery,
                    channels: viewModel.availableChannelsForPicker,
                    onSelect: { channel in
                        viewModel.insertChannelMention(channel)
                        dismissChannelPicker()
                        Haptics.play(.light)
                    },
                    onDismiss: { dismissChannelPicker() }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.2), value: isShowingChannelPicker)
            }
        }
        .overlay(alignment: .bottom) {
            if isShowingMentionPicker {
                UserModelPickerView(
                    query: mentionQuery,
                    members: viewModel.members,
                    models: viewModel.availableModels,
                    serverBaseURL: viewModel.serverBaseURL,
                    authToken: viewModel.serverAuthToken,
                    onSelectUser: { member in
                        viewModel.insertUserMention(member)
                        dismissMentionPicker()
                        Haptics.play(.light)
                    },
                    onSelectModel: { model in
                        viewModel.setModelMention(model)
                        dismissMentionPicker()
                        Haptics.play(.light)
                    },
                    onDismiss: { dismissMentionPicker() }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.2), value: isShowingMentionPicker)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.threadParentMessage != nil },
            set: { if !$0 { viewModel.closeThread() } }
        )) {
            if let parent = viewModel.threadParentMessage {
                ThreadDetailSheet(viewModel: viewModel, parentMessage: parent)
            }
        }
        .sheet(isPresented: $viewModel.showMembersSheet) {
            ChannelMembersSheet(members: viewModel.members, isLoading: viewModel.isLoadingMembers, serverBaseURL: viewModel.serverBaseURL)
        }
        .sheet(isPresented: $viewModel.showPinnedSheet) {
            PinnedMessagesSheet(messages: viewModel.pinnedMessages)
        }
        // Channel settings sheet (SEC-005: error handling)
        .sheet(isPresented: $showChannelSettings, onDismiss: {
            Task {
                await viewModel.loadChannel()
                await viewModel.loadMembers()
            }
        }) {
            if let channel = viewModel.channel {
                if channel.type == .dm {
                    DmSettingsSheet(
                        channel: channel,
                        members: viewModel.dmParticipants,
                        allUsers: viewModel.allServerUsers,
                        currentUserId: viewModel.currentUserId,
                        serverBaseURL: viewModel.serverBaseURL,
                        onAddMembers: { userIds in
                            do {
                                try await dependencies.apiClient?.addChannelMembers(id: channel.id, userIds: userIds)
                            } catch {
                                showError("Failed to add members: \(error.localizedDescription)")
                            }
                        },
                        onLeave: {
                            do {
                                try await dependencies.apiClient?.updateMemberActiveStatus(channelId: channel.id, isActive: false)
                            } catch {
                                showError("Failed to leave: \(error.localizedDescription)")
                            }
                        }
                    )
                } else {
                    CreateChannelSheet(
                        onUpdate: { channel, name, description, isPrivate in
                            Task {
                                do {
                                    _ = try await dependencies.apiClient?.updateChannel(
                                        id: channel.id,
                                        name: name,
                                        description: description,
                                        isPrivate: isPrivate
                                    )
                                } catch {
                                    showError("Failed to update channel: \(error.localizedDescription)")
                                }
                            }
                        },
                        onDelete: { channel in
                            Task {
                                do {
                                    try await dependencies.apiClient?.deleteChannel(id: channel.id)
                                } catch {
                                    showError("Failed to delete channel: \(error.localizedDescription)")
                                }
                            }
                        },
                        onUpdateAccessGrants: { channelId, grantsPayload in
                            do {
                                _ = try await dependencies.apiClient?.updateChannel(
                                    id: channelId,
                                    name: channel.name,
                                    description: channel.description,
                                    isPrivate: channel.isPrivate,
                                    accessGrants: grantsPayload
                                )
                            } catch {
                                showError("Failed to update access: \(error.localizedDescription)")
                            }
                        },
                        onAddGroupMembers: { channelId, userIds in
                            do {
                                try await dependencies.apiClient?.addChannelMembers(id: channelId, userIds: userIds)
                            } catch {
                                showError("Failed to add members: \(error.localizedDescription)")
                            }
                        },
                        onRemoveGroupMembers: { channelId, userIds in
                            do {
                                try await dependencies.apiClient?.removeChannelMembers(id: channelId, userIds: userIds)
                            } catch {
                                showError("Failed to remove members: \(error.localizedDescription)")
                            }
                        },
                        apiClient: dependencies.apiClient,
                        editingChannel: channel,
                        allUsers: viewModel.allServerUsers,
                        channelMembers: viewModel.members
                    )
                }
            }
        }
        .sheet(isPresented: $showAttachmentPicker) {
            UnifiedAttachmentPicker(
                onPhotoSelected: { items in
                    Task { await processPhotos(items) }
                },
                onFileSelected: { urls in
                    Task { for url in urls { await processFileURL(url) } }
                },
                onDismiss: { showAttachmentPicker = false }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.hidden)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .overlay(alignment: .top) {
            if viewModel.showCopiedToast {
                copiedToast
            }
        }
        // MF-003: Reaction tooltip overlay
        .overlay(alignment: .bottom) {
            if showReactionTooltip, let text = reactionTooltipText {
                Text(text)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textInverse)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(theme.textPrimary.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.bottom, 100)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .task {
            keyboard.start()
            if let apiClient = dependencies.apiClient {
                var userId = dependencies.authViewModel.currentUser?.id
                if userId == nil || userId?.isEmpty == true {
                    userId = try? await apiClient.getCurrentUser().id
                }
                viewModel.configure(
                    apiClient: apiClient,
                    socket: dependencies.socketService,
                    currentUserId: userId
                )
                if userId == nil {
                    print("[ChannelDetailView] WARNING: currentUserId is nil — Edit/Delete will be hidden")
                }
            }
            await viewModel.load()
        }
        .onDisappear {
            keyboard.stop()
            viewModel.cleanup()
        }
        .onChange(of: selectedPhotos) { _, items in
            Task { await processPhotos(items); selectedPhotos = [] }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { urls in
                Task { for url in urls { await processFileURL(url) } }
            }
        }
        .quickLookPreview($quickLookURL)
        .overlay {
            if isLoadingFile {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Loading file…")
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(.white)
                    }
                    .padding(Spacing.lg)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .alert("Download Failed", isPresented: $showDownloadError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadErrorMessage)
        }
        // SEC-005: Surface operation errors
        .alert("Error", isPresented: $showOperationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationErrorMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .markdownLinkTapped)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            if url.scheme == "openui-channel", let channelId = url.host {
                NotificationCenter.default.post(name: .navigateToChannel, object: channelId)
            } else {
                UIApplication.shared.open(url)
            }
        }
        .background {
            InlineEmojiKeyboard(isActive: $showEmojiKeyboard) { emoji in
                if let messageId = emojiTargetMessageId {
                    Task { await viewModel.toggleReaction(messageId: messageId, emoji: emoji) }
                    Haptics.play(.light)
                }
                showEmojiKeyboard = false
                emojiTargetMessageId = nil
            }
            .allowsHitTesting(false)
        }
    }
    
    // MARK: - Error Surfacing (SEC-005)
    
    @MainActor
    private func showError(_ message: String) {
        operationErrorMessage = message
        showOperationError = true
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if viewModel.isDM {
                dmToolbarTitle
            } else if viewModel.isGroup {
                groupToolbarTitle
            } else {
                standardToolbarTitle
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 0) {
                Button {
                    Task { await viewModel.loadPinnedMessages() }
                    viewModel.showPinnedSheet = true
                } label: {
                    Image(systemName: "pin")
                        .scaledFont(size: 12, weight: .medium)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                
                Button {
                    Task { await viewModel.loadMembers() }
                    viewModel.showMembersSheet = true
                } label: {
                    Image(systemName: "person.2")
                        .scaledFont(size: 12, weight: .medium)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                
                if viewModel.canManageChannel {
                    Button {
                        Task {
                            async let channelRefresh: () = viewModel.loadChannel()
                            async let usersRefresh: () = viewModel.loadAllServerUsers()
                            _ = await (channelRefresh, usersRefresh)
                            showChannelSettings = true
                        }
                    } label: {
                        Image(systemName: "gearshape")
                            .scaledFont(size: 12, weight: .medium)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }
    
    // MARK: - Type-Specific Toolbar Titles
    
    private var dmToolbarTitle: some View {
        HStack(spacing: 8) {
            if let participant = viewModel.dmOtherParticipant {
                ZStack(alignment: .bottomTrailing) {
                    UserAvatar(
                        size: 28,
                        imageURL: participant.resolveAvatarURL(serverBaseURL: viewModel.serverBaseURL),
                        name: participant.displayName
                    )
                    Circle()
                        .fill(participant.isOnline ? Color.green : Color.gray.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.channelDisplayTitle)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let participant = viewModel.dmOtherParticipant {
                    Text(participant.isOnline ? "Active now" : "Offline")
                        .scaledFont(size: 11)
                        .foregroundStyle(participant.isOnline ? .green : theme.textTertiary)
                }
            }
        }
    }
    
    private var groupToolbarTitle: some View {
        VStack(spacing: 1) {
            Text(viewModel.channel?.name ?? "Group")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if !viewModel.members.isEmpty {
                Text("\(viewModel.members.count) members")
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
            } else if let desc = viewModel.channel?.description, !desc.isEmpty {
                Text(desc)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
    
    private var standardToolbarTitle: some View {
        VStack(spacing: 1) {
            Text(viewModel.channel?.name ?? "Channel")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if let desc = viewModel.channel?.description, !desc.isEmpty {
                Text(desc)
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
    
    // MARK: - Message List
    
    private var messageListArea: some View {
        ZStack {
            scrollContent
            
            if viewModel.isLoadingMessages && viewModel.messages.isEmpty {
                loadingPlaceholders
            }
            
            if !viewModel.isLoadingMessages && viewModel.messages.isEmpty {
                emptyChannelView
            }
        }
        .overlay(alignment: .bottomTrailing) { scrollToBottomFAB }
        .onAppear { scrollPosition.scrollTo(edge: .bottom) }
        .onChange(of: viewModel.messages.count) { old, new in
            guard new > old, !isScrolledUp else { return }
            withAnimation { scrollPosition.scrollTo(edge: .bottom) }
        }
    }
    
    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if viewModel.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, Spacing.md)
                }
                
                ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                    if shouldShowDateSeparator(at: index) {
                        dateSeparatorView(for: message.createdAt)
                    }
                    
                    let showHeader = shouldShowSenderHeader(at: index)
                    let showTimestamp = isLastInGroup(at: index)
                    let position = groupPosition(at: index)
                    channelMessageRow(message, showSenderHeader: showHeader, showGroupTimestamp: showTimestamp, position: position)
                        .id(message.id)
                        .task {
                            if message.id == viewModel.messages.first?.id {
                                await viewModel.loadOlderMessages()
                            }
                        }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(minHeight: max(containerHeight, 0), alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .onScrollGeometryChange(for: CGPoint.self) { geo in
            geo.contentOffset
        } action: { _, newOffset in
            let distFromBottom = max(0, contentHeight - newOffset.y - containerHeight)
            if distFromBottom <= 120 {
                if isScrolledUp { isScrolledUp = false }
            } else if newOffset.y < lastScrollOffset - 40 {
                if !isScrolledUp { isScrolledUp = true }
            }
            if abs(newOffset.y - lastScrollOffset) > 2 { lastScrollOffset = newOffset.y }
        }
        .onScrollGeometryChange(for: CGSize.self) { geo in
            CGSize(width: geo.contentSize.height, height: geo.containerSize.height)
        } action: { _, newSize in
            if abs(newSize.width - contentHeight) > 1 { contentHeight = newSize.width }
            if abs(newSize.height - containerHeight) > 1 { containerHeight = newSize.height }
        }
    }
    
    // MARK: - Message Grouping
    
    private enum GroupPosition {
        case single, first, middle, last
    }
    
    private func shouldShowSenderHeader(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = viewModel.messages[index]
        let previous = viewModel.messages[index - 1]
        if !Calendar.current.isDate(current.createdAt, inSameDayAs: previous.createdAt) {
            return true
        }
        return current.effectiveSenderId != previous.effectiveSenderId
    }
    
    private func isLastInGroup(at index: Int) -> Bool {
        let messages = viewModel.messages
        guard index < messages.count - 1 else { return true }
        let current = messages[index]
        let next = messages[index + 1]
        if !Calendar.current.isDate(current.createdAt, inSameDayAs: next.createdAt) {
            return true
        }
        return current.effectiveSenderId != next.effectiveSenderId
    }
    
    private func groupPosition(at index: Int) -> GroupPosition {
        let isFirst = shouldShowSenderHeader(at: index)
        let isLast = isLastInGroup(at: index)
        switch (isFirst, isLast) {
        case (true, true):   return .single
        case (true, false):  return .first
        case (false, false): return .middle
        case (false, true):  return .last
        }
    }
    
    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = viewModel.messages[index].createdAt
        let previous = viewModel.messages[index - 1].createdAt
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }
    
    // MARK: - Bubble Colors
    
    private var bubbleBackground: Color {
        theme.isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.06)
    }
    
    private var bubbleBorder: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
    
    // MARK: - Message Row
    
    private let avatarSize: CGFloat = 28
    
    // MARK: - Date Separator
    
    private func dateSeparatorView(for date: Date) -> some View {
        HStack(spacing: 8) {
            VStack { Divider().background(theme.textTertiary.opacity(0.2)) }
            Text(date.channelDateSeparator)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
            VStack { Divider().background(theme.textTertiary.opacity(0.2)) }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private func channelMessageRow(_ message: ChannelMessage, showSenderHeader: Bool, showGroupTimestamp: Bool, position: GroupPosition = .single) -> some View {
        let isCurrentUser = message.userId == viewModel.currentUserId && !viewModel.isModelMessage(message)
        let isModel = viewModel.isModelMessage(message)
        let resolvedName = viewModel.resolvedSenderName(for: message)
        let isFirstInGroup = (position == .first || position == .single)
        
        VStack(alignment: .leading, spacing: 0) {
            if showSenderHeader {
                HStack(spacing: 8) {
                    senderAvatar(message, size: avatarSize)
                    
                    HStack(spacing: 5) {
                        Text(resolvedName)
                            .scaledFont(size: 13, weight: .bold)
                            .foregroundStyle(isModel ? theme.mentionModelText : theme.textPrimary)
                        
                        if isModel {
                            Text("BOT")
                                .scaledFont(size: 8, weight: .heavy)
                                .foregroundStyle(theme.mentionModelText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(theme.mentionModelBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                        
                        Text(message.createdAt.channelTime)
                            .scaledFont(size: 10)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.bottom, 3)
            }
            
            if message.isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .scaledFont(size: 9)
                        .rotationEffect(.degrees(45))
                    Text("Pinned")
                        .scaledFont(size: 10, weight: .semibold)
                }
                .foregroundStyle(.yellow.opacity(0.8))
                .padding(.bottom, 2)
            }
            
            if let replyId = message.replyToId {
                replyIndicator(for: replyId, message: message)
                    .padding(.bottom, 2)
            }
            
            if viewModel.editingMessage?.id == message.id {
                editBubble(isCurrentUser: isCurrentUser)
            } else if !message.content.isEmpty || !message.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !message.content.isEmpty {
                        ChannelMarkdownView(
                            content: message.content,
                            currentUserId: viewModel.currentUserId,
                            isCurrentUser: false,
                            accessibleChannelIds: viewModel.accessibleChannelIds
                        )
                    }
                    
                    if !message.files.isEmpty {
                        messageAttachments(message.files)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(bubbleBackground)
                .clipShape(ChannelBubbleShape(isFirstInGroup: isFirstInGroup))
                .overlay(
                    ChannelBubbleShape(isFirstInGroup: isFirstInGroup)
                        .strokeBorder(bubbleBorder, lineWidth: 0.5)
                )
            }
            
            // Reactions (MF-003: with tooltip on long-press)
            if !message.reactions.isEmpty {
                reactionsBar(message)
                    .padding(.top, 3)
            }
            
            if message.hasThread {
                ThreadReplyBadge(
                    replyCount: message.replyCount,
                    latestReplyAt: message.latestReplyAt
                ) {
                    Task { await viewModel.openThread(for: message) }
                    Haptics.play(.light)
                }
                .padding(.top, 3)
            }
            
            if showGroupTimestamp && !showSenderHeader {
                Text(message.createdAt.channelTime)
                    .scaledFont(size: 10)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, 2)
            }
            
            if message.isFailed {
                Button {
                    Task { await viewModel.retrySendMessage(id: message.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .scaledFont(size: 11)
                        Text("Failed to send. Tap to retry.")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .foregroundStyle(theme.error)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, showSenderHeader ? 12 : 2)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    reactionOverlayMessage = message
                    Haptics.play(.medium)
                }
        )
        .opacity(message.isOptimistic ? 0.6 : 1.0)
    }
    
    // MARK: - Sender Avatar
    
    @ViewBuilder
    private func senderAvatar(_ message: ChannelMessage, size: CGFloat = 32) -> some View {
        let isModel = viewModel.isModelMessage(message)
        if isModel, let model = viewModel.resolveModelForMessage(message) {
            ModelAvatar(
                size: size,
                imageURL: model.resolveAvatarURL(baseURL: viewModel.serverBaseURL),
                label: model.shortName,
                authToken: viewModel.serverAuthToken
            )
        } else {
            let resolvedName = viewModel.resolvedSenderName(for: message)
            let avatarURL = avatarURLForUser(id: message.userId)
            UserAvatar(
                size: size,
                imageURL: avatarURL,
                name: resolvedName,
                authToken: viewModel.serverAuthToken
            )
        }
    }
    
    private func avatarURLForUser(id: String) -> URL? {
        guard !id.isEmpty, !viewModel.serverBaseURL.isEmpty else { return nil }
        return URL(string: "\(viewModel.serverBaseURL)/api/v1/users/\(id)/profile/image")
    }
    
    // MARK: - Reply Indicator
    
    @ViewBuilder
    private func replyIndicator(for replyId: String, message: ChannelMessage) -> some View {
        if let replyMsg = viewModel.messages.first(where: { $0.id == replyId }) {
            let isModel = viewModel.isModelMessage(replyMsg)
            ChannelReplyPreview(
                senderName: viewModel.resolvedSenderName(for: replyMsg),
                content: replyMsg.content,
                isModel: isModel
            )
        } else if let slim = message.replyToMessage {
            ChannelReplyPreview(
                senderName: slim.user?.displayName ?? "Unknown",
                content: slim.content,
                isModel: false
            )
        }
    }
    
    // MARK: - File Attachments
    
    @ViewBuilder
    private func messageAttachments(_ files: [ChatMessageFile]) -> some View {
        let imageFiles = files.filter { $0.type == "image" || ($0.contentType ?? "").hasPrefix("image/") }
        let otherFiles = files.filter { $0.type != "image" && !($0.contentType ?? "").hasPrefix("image/") }
        
        if !imageFiles.isEmpty {
            ChannelImageGrid(imageFiles: imageFiles, apiClient: dependencies.apiClient)
        }
        
        ForEach(Array(otherFiles.enumerated()), id: \.offset) { _, file in
            let fileName = file.name ?? file.url ?? "File"
            ChannelFileCard(
                name: fileName,
                contentType: file.contentType,
                onTap: {
                    if let fileId = file.url {
                        Task { await previewFileInApp(fileId: fileId, fileName: fileName) }
                    }
                }
            )
            .frame(maxWidth: 280)
        }
    }
    
    // MARK: - Edit Bubble
    
    private func editBubble(isCurrentUser: Bool) -> some View {
        @Bindable var vm = viewModel
        return VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message…", text: $vm.editingText, axis: .vertical)
                .scaledFont(size: 14)
                .lineLimit(1...10)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfaceContainer.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            
            HStack(spacing: 8) {
                Button { viewModel.cancelEditing() } label: {
                    Text("Cancel")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                Button { Task { await viewModel.submitEdit() } } label: {
                    Text("Save")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.brandPrimary)
                }
                .disabled(viewModel.editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surfaceContainer.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
    
    // MARK: - Reactions Bar (MF-003: with tooltip on long-press)
    
    private func reactionsBar(_ message: ChannelMessage) -> some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { reaction in
                Button {
                    Task { await viewModel.toggleReaction(messageId: message.id, emoji: reaction.name) }
                    Haptics.play(.light)
                } label: {
                    let isOwn = reaction.userIds.contains(viewModel.currentUserId ?? "")
                    HStack(spacing: 2) {
                        Text(reaction.name)
                            .font(.system(size: 13))
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .scaledFont(size: 11, weight: .medium)
                                .foregroundStyle(isOwn ? theme.brandPrimary : theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        isOwn ? theme.brandPrimary.opacity(0.12) : theme.surfaceContainer.opacity(0.6)
                    )
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            isOwn ? theme.brandPrimary.opacity(0.3) : Color.clear,
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
                // MF-003: Show reactor names on long-press
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { _ in
                            let summary = reaction.reactorSummary
                            if !summary.isEmpty {
                                reactionTooltipText = summary
                                withAnimation(.easeOut(duration: 0.15)) { showReactionTooltip = true }
                                // Auto-hide after 2 seconds
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    await MainActor.run {
                                        withAnimation(.easeOut(duration: 0.15)) { showReactionTooltip = false }
                                    }
                                }
                            }
                        }
                )
            }
            
            Button {
                emojiTargetMessageId = message.id
                showEmojiKeyboard = true
                Haptics.play(.light)
            } label: {
                Image(systemName: "face.smiling")
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(theme.surfaceContainer.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Read-Only Banner (MF-005)
    
    private var readOnlyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textTertiary)
            Text("This channel is read-only")
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(theme.surfaceContainer.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 8)
    }
    
    // MARK: - Reply Preview Bar
    
    private func replyPreviewBar(_ message: ChannelMessage) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.replyBorder)
                .frame(width: 3, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(viewModel.resolvedSenderName(for: message))")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(theme.replyBorder)
                Text(ChannelMessage.parseMentions(in: message.content).prefix(60))
                    .scaledFont(size: 12)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button {
                viewModel.clearReply()
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 18)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 8)
        .background(theme.replyBackground)
    }
    
    // MARK: - Model Mention Bar
    
    private var modelMentionBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(theme.mentionModelText)
            Text(viewModel.mentionedModelName ?? "")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("will respond to this message")
                .scaledFont(size: 12)
                .foregroundStyle(theme.textTertiary)
            
            Spacer()
            
            Button {
                viewModel.clearModelMention()
                Haptics.play(.light)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 16)
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.vertical, 6)
        .background(theme.mentionModelBackground)
    }
    
    // MARK: - Input Field
    
    private var channelInputField: some View {
        @Bindable var vm = viewModel
        
        return VStack(spacing: 0) {
            if !viewModel.attachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, 4)
            }
            
            HStack(alignment: .center, spacing: 8) {
                Button {
                    showAttachmentPicker = true
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                
                PasteableTextView(
                    text: $vm.inputText,
                    placeholder: viewModel.inputPlaceholder,
                    font: .systemFont(ofSize: 14, weight: .regular),
                    textColor: UIColor(theme.textPrimary),
                    placeholderColor: UIColor(theme.textTertiary),
                    tintColor: UIColor(theme.brandPrimary),
                    isEnabled: true,
                    onPasteAttachments: { attachments in
                        withAnimation { vm.attachments.append(contentsOf: attachments) }
                        for att in attachments { vm.uploadAttachmentImmediately(attachmentId: att.id) }
                    },
                    onSubmit: { Task { await viewModel.sendMessage() } },
                    onHashTrigger: { query in
                        channelQuery = query
                        if !isShowingChannelPicker {
                            withAnimation(.easeOut(duration: 0.2)) { isShowingChannelPicker = true }
                        }
                    },
                    onHashDismiss: { dismissChannelPicker() },
                    onAtTrigger: { query in
                        mentionQuery = query
                        if !isShowingMentionPicker {
                            withAnimation(.easeOut(duration: 0.2)) { isShowingMentionPicker = true }
                        }
                    },
                    onAtDismiss: { dismissMentionPicker() },
                    sendOnReturn: true
                )
                .fixedSize(horizontal: false, vertical: true)
                
                if viewModel.canSend {
                    Button {
                        Task { await viewModel.sendMessage() }
                        Haptics.play(.light)
                    } label: {
                        Circle()
                            .fill(theme.brandPrimary)
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "arrow.up")
                                    .scaledFont(size: 13, weight: .bold)
                                    .foregroundStyle(theme.brandOnPrimary)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(theme.isDark ? theme.cardBackground.opacity(0.95) : theme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(theme.isDark ? 0.2 : 0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.15), value: viewModel.canSend)
    }
    
    // MARK: - Attachment Strip
    
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnail {
                            thumbnail.resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.surfaceContainer)
                                .frame(width: 50, height: 50)
                                .overlay(
                                    VStack(spacing: 2) {
                                        if attachment.isUploading {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "doc")
                                                .scaledFont(size: 14)
                                                .foregroundStyle(theme.textTertiary)
                                        }
                                        Text(attachment.name)
                                            .scaledFont(size: 7)
                                            .foregroundStyle(theme.textTertiary)
                                            .lineLimit(1)
                                    }
                                )
                        }
                        
                        Button {
                            withAnimation { viewModel.attachments.removeAll { $0.id == attachment.id } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .scaledFont(size: 16)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
        }
    }
    
    // MARK: - Empty Channel
    
    private var emptyChannelView: some View {
        VStack(spacing: Spacing.md) {
            if viewModel.isDM {
                if let participant = viewModel.dmOtherParticipant {
                    UserAvatar(
                        size: 56,
                        imageURL: participant.resolveAvatarURL(serverBaseURL: viewModel.serverBaseURL),
                        name: participant.displayName,
                        authToken: viewModel.serverAuthToken
                    )
                } else {
                    Image(systemName: "person.crop.circle")
                        .scaledFont(size: 40)
                        .foregroundStyle(Color.green.opacity(0.5))
                }
                Text("Say hello to \(viewModel.channelDisplayTitle)")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Text("Send a message or @mention a model")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .scaledFont(size: 40)
                    .foregroundStyle(theme.textTertiary.opacity(0.5))
                Text("No messages yet")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                Text("Start the conversation with @model or @user")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }
    
    // MARK: - Loading (INC-007: Animated shimmer)
    
    private var loadingPlaceholders: some View {
        VStack(spacing: 16) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(theme.surfaceContainer.opacity(0.4))
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.surfaceContainer.opacity(0.4))
                            .frame(width: CGFloat.random(in: 80...140), height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.surfaceContainer.opacity(0.3))
                            .frame(width: CGFloat.random(in: 150...280), height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.surfaceContainer.opacity(0.2))
                            .frame(width: CGFloat.random(in: 100...200), height: 14)
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.screenPadding)
            }
        }
        .redacted(reason: .placeholder)
        .shimmer()
    }
    
    // MARK: - Scroll FAB
    
    @ViewBuilder
    private var scrollToBottomFAB: some View {
        if isScrolledUp && !viewModel.messages.isEmpty {
            ZStack {
                Circle().fill(.ultraThinMaterial).frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                Image(systemName: "chevron.down")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
            }
            .contentShape(Circle())
            .highPriorityGesture(TapGesture().onEnded {
                withAnimation { scrollPosition.scrollTo(edge: .bottom) }
                Haptics.play(.light)
            })
            .padding(.trailing, Spacing.md)
            .padding(.bottom, Spacing.sm)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }
    
    // MARK: - Copied Toast
    
    private var copiedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc.fill").scaledFont(size: 12)
            Text("Copied").scaledFont(size: 12, weight: .medium)
        }
        .foregroundStyle(theme.textInverse)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(theme.textPrimary.opacity(0.85))
        .clipShape(Capsule())
        .padding(.top, Spacing.md)
        .transition(.toastTransition)
    }
    
    // MARK: - Pickers
    
    private func dismissChannelPicker() {
        if isShowingChannelPicker {
            withAnimation(.easeOut(duration: 0.15)) {
                isShowingChannelPicker = false
                channelQuery = ""
            }
        }
    }
    
    private func dismissMentionPicker() {
        if isShowingMentionPicker {
            withAnimation(.easeOut(duration: 0.15)) {
                isShowingMentionPicker = false
                mentionQuery = ""
            }
        }
    }
    
    // MARK: - File Processing (DRY-004: Could share with thread, but kept here for view locality)
    
    private func processPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let image = UIImage(data: data)
                let thumbnail = image.map { Image(uiImage: $0) }
                let resized = FileAttachmentService.downsampleForUpload(data: data, image: image)
                let attachment = ChatAttachment(
                    type: .image,
                    name: "Photo_\(Int(Date.now.timeIntervalSince1970)).jpg",
                    thumbnail: thumbnail,
                    data: resized
                )
                viewModel.attachments.append(attachment)
                viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
            }
        }
    }
    
    private func processFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let attachment = ChatAttachment(type: .file, name: url.lastPathComponent, thumbnail: nil, data: data)
        viewModel.attachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id)
    }
    
    // MARK: - File Preview (QuickLook)
    
    private func previewFileInApp(fileId: String, fileName: String) async {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("file_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        
        let cachedFile = cacheDir.appendingPathComponent("\(fileId)_\(fileName)")
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            quickLookURL = cachedFile
            return
        }
        
        guard let apiClient = dependencies.apiClient else { return }
        withAnimation { isLoadingFile = true }
        
        do {
            let (data, _) = try await apiClient.getFileContent(id: fileId)
            try data.write(to: cachedFile)
            withAnimation { isLoadingFile = false }
            quickLookURL = cachedFile
        } catch {
            withAnimation { isLoadingFile = false }
            downloadErrorMessage = "Failed to load file: \(error.localizedDescription)"
            showDownloadError = true
        }
    }
}

// MARK: - Channel Bubble Shape

struct ChannelBubbleShape: InsettableShape {
    let isFirstInGroup: Bool
    var insetAmount: CGFloat = 0
    
    private let standardRadius: CGFloat = 16
    private let tailRadius: CGFloat = 4
    
    func inset(by amount: CGFloat) -> ChannelBubbleShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
    
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let tl = isFirstInGroup ? tailRadius : standardRadius
        let tr = standardRadius
        let br = standardRadius
        let bl = standardRadius
        
        return Path { p in
            p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
            p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
            p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
            p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
            p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        }
    }
}

