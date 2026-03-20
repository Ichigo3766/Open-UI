import SwiftUI
import PhotosUI
import QuickLook

// MARK: - User & Model Picker (Combined @mention)

/// Combined picker that shows channel members (users) first, then AI models.
/// Used when typing `@` in a channel — users get text mentions, models get AI responses.
struct UserModelPickerView: View {
    let query: String
    let members: [ChannelMember]
    let models: [AIModel]
    let serverBaseURL: String
    let authToken: String?
    let onSelectUser: (ChannelMember) -> Void
    let onSelectModel: (AIModel) -> Void
    let onDismiss: () -> Void
    
    @Environment(\.theme) private var theme
    
    private var filteredMembers: [ChannelMember] {
        if query.isEmpty { return Array(members.prefix(8)) }
        let q = query.lowercased()
        return members.filter {
            $0.displayName.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }.prefix(8).map { $0 }
    }
    
    private var filteredModels: [AIModel] {
        if query.isEmpty { return Array(models.prefix(8)) }
        let q = query.lowercased()
        return models.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }.prefix(8).map { $0 }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(theme.textTertiary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Users section
                    if !filteredMembers.isEmpty {
                        sectionHeader("Users", icon: "person.fill")
                        ForEach(filteredMembers) { member in
                            Button { onSelectUser(member) } label: {
                                userRow(member)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Models section
                    if !filteredModels.isEmpty {
                        sectionHeader("Models", icon: "cpu")
                        ForEach(filteredModels) { model in
                            Button { onSelectModel(model) } label: {
                                modelRow(model)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    if filteredMembers.isEmpty && filteredModels.isEmpty {
                        HStack {
                            Spacer()
                            Text("No matches for \"@\(query)\"")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.vertical, Spacing.lg)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.md)
            }
            .frame(maxHeight: 320)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: -4)
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, 80)
    }
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 10, weight: .semibold)
            Text(title)
                .scaledFont(size: 11, weight: .bold)
        }
        .foregroundStyle(theme.textTertiary)
        .textCase(.uppercase)
        .padding(.top, Spacing.md)
        .padding(.bottom, 4)
    }
    
    private func userRow(_ member: ChannelMember) -> some View {
        HStack(spacing: Spacing.sm) {
            // Avatar
            UserAvatar(
                size: 30,
                imageURL: member.resolveAvatarURL(serverBaseURL: serverBaseURL),
                name: member.displayName
            )
            
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if !member.email.isEmpty {
                    Text(member.email)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Online indicator
            if member.isOnline {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    
    private func memberInitials(_ name: String) -> some View {
        Circle()
            .fill(theme.brandPrimary.opacity(0.12))
            .frame(width: 30, height: 30)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(theme.brandPrimary)
            )
    }
    
    private func modelRow(_ model: AIModel) -> some View {
        HStack(spacing: Spacing.sm) {
            ModelAvatar(
                size: 30,
                imageURL: model.resolveAvatarURL(baseURL: serverBaseURL),
                label: model.shortName,
                authToken: authToken
            )
            
            VStack(alignment: .leading, spacing: 1) {
                Text(model.shortName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let desc = model.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            Image(systemName: "cpu")
                .scaledFont(size: 11)
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Channel Link Picker (#channel mentions)

/// Popup picker shown when user types `#` in a channel input.
/// Displays a filterable list of accessible channels for creating `<#id|name>` links.
struct ChannelLinkPickerView: View {
    let query: String
    let channels: [Channel]
    let onSelect: (Channel) -> Void
    let onDismiss: () -> Void
    
    @Environment(\.theme) private var theme
    
    private var filtered: [Channel] {
        if query.isEmpty { return Array(channels.prefix(10)) }
        let q = query.lowercased()
        return channels.filter {
            $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q)
        }.prefix(10).map { $0 }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(theme.textTertiary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Channels", icon: "number")
                    
                    if filtered.isEmpty {
                        HStack {
                            Spacer()
                            Text("No channels match \"#\(query)\"")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                                .padding(.vertical, Spacing.lg)
                            Spacer()
                        }
                    } else {
                        ForEach(filtered) { channel in
                            Button { onSelect(channel) } label: {
                                channelRow(channel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.bottom, Spacing.md)
            }
            .frame(maxHeight: 280)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: -4)
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, 80)
    }
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .scaledFont(size: 10, weight: .semibold)
            Text(title)
                .scaledFont(size: 11, weight: .bold)
        }
        .foregroundStyle(theme.textTertiary)
        .textCase(.uppercase)
        .padding(.top, Spacing.md)
        .padding(.bottom, 4)
    }
    
    private func channelRow(_ channel: Channel) -> some View {
        HStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Thread Detail Sheet

/// Shows a thread's parent message and replies with full channel-equivalent features:
/// markdown rendering, @mention picker, file attachments, same input field.
struct ThreadDetailSheet: View {
    @Bindable var viewModel: ChannelViewModel
    let parentMessage: ChannelMessage
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    
    // Smart local snapshot — syncs when messages arrive, ignores dismiss clearance
    @State private var displayMessages: [ChannelMessage] = []
    
    
    // @mention picker state (same as main channel)
    @State private var isShowingMentionPicker = false
    @State private var mentionQuery = ""

    // Thread attachment picker
    @State private var showThreadAttachmentPicker = false
    
    // Reaction overlay + inline emoji keyboard (reuses same components as channel)
    @State private var threadReactionOverlayMessage: ChannelMessage?
    @State private var threadShowEmojiKeyboard = false
    @State private var threadEmojiTargetMessageId: String?
    
    // QuickLook for file preview
    @State private var quickLookURL: URL?
    @State private var isLoadingFile = false
    @State private var showDownloadError = false
    @State private var downloadErrorMessage = ""
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        // Parent message
                        threadMessageRow(parentMessage, isParent: true, showHeader: true)
                            .padding(.bottom, 4)
                        
                        // Divider
                        HStack(spacing: 8) {
                            VStack { Divider() }
                            Text("\(parentMessage.replyCount) repl\(parentMessage.replyCount == 1 ? "y" : "ies")")
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(theme.textTertiary)
                            VStack { Divider() }
                        }
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.vertical, 8)
                        
                        if viewModel.isLoadingThread {
                            ProgressView()
                                .padding(.vertical, Spacing.xl)
                        } else if displayMessages.isEmpty {
                            VStack(spacing: 8) {
                                Text("No replies yet")
                                    .scaledFont(size: 15, weight: .medium)
                                    .foregroundStyle(theme.textSecondary)
                                Text("Be the first to reply")
                                    .scaledFont(size: 13)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .padding(.vertical, Spacing.xl)
                        } else {
                            // BUG-009 fix: Safe index bounds checking for message grouping
                            ForEach(Array(displayMessages.enumerated()), id: \.element.id) { index, msg in
                                let showHeader = index == 0 || msg.effectiveSenderId != displayMessages[index - 1].effectiveSenderId
                                let showTimestamp: Bool = {
                                    guard index < displayMessages.count - 1 else { return true }
                                    return msg.effectiveSenderId != displayMessages[index + 1].effectiveSenderId
                                }()
                                threadMessageRow(msg, isParent: false, showHeader: showHeader, showGroupTimestamp: showTimestamp)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                
                threadInput
            }
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            // @mention picker overlay
            .overlay(alignment: .bottom) {
                if isShowingMentionPicker {
                    UserModelPickerView(
                        query: mentionQuery,
                        members: viewModel.members,
                        models: viewModel.availableModels,
                        serverBaseURL: viewModel.serverBaseURL,
                        authToken: viewModel.serverAuthToken,
                        onSelectUser: { member in
                            viewModel.insertThreadUserMention(member)
                            dismissMentionPicker()
                            Haptics.play(.light)
                        },
                        onSelectModel: { model in
                            viewModel.setThreadModelMention(model)
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
        }
        .onAppear {
            displayMessages = viewModel.threadMessages
        }
        .onChange(of: viewModel.threadMessages) { oldValue, newValue in
            // Sync when messages arrive (new bot replies, etc.)
            // Ignore when cleared to [] during dismiss — protects against crash
            if !newValue.isEmpty || oldValue.isEmpty {
                displayMessages = newValue
            }
        }
        // In-app file preview using QuickLook (PDFs, images, docs, etc.)
        .quickLookPreview($quickLookURL)
        // File download loading overlay
        .overlay {
            if isLoadingFile {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 8) {
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
        // iMessage-style reaction overlay (same as channel, no "Reply in Thread")
        .overlay {
            if let msg = threadReactionOverlayMessage {
                let isOwn = msg.userId == viewModel.currentUserId && !viewModel.isModelMessage(msg)
                MessageReactionOverlay(
                    message: msg,
                    isCurrentUser: isOwn,
                    onReaction: { emoji in
                        Task { await viewModel.toggleReaction(messageId: msg.id, emoji: emoji) }
                        withAnimation(.easeOut(duration: 0.2)) { threadReactionOverlayMessage = nil }
                    },
                    onReply: {
                        // In thread, "Reply" focuses the thread input
                        // (thread reply is already the default action)
                    },
                    onThread: nil, // Already in a thread — hide this button
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
                        withAnimation(.easeOut(duration: 0.2)) { threadReactionOverlayMessage = nil }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            threadEmojiTargetMessageId = targetId
                            threadShowEmojiKeyboard = true
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) { threadReactionOverlayMessage = nil }
                    }
                )
                .animation(.easeOut(duration: 0.2), value: threadReactionOverlayMessage?.id)
            }
        }
        // Inline emoji keyboard for thread (same as channel)
        .background {
            InlineEmojiKeyboard(isActive: $threadShowEmojiKeyboard) { emoji in
                if let messageId = threadEmojiTargetMessageId {
                    Task { await viewModel.toggleReaction(messageId: messageId, emoji: emoji) }
                    Haptics.play(.light)
                }
                threadShowEmojiKeyboard = false
                threadEmojiTargetMessageId = nil
            }
            .allowsHitTesting(false)
        }
    }
    
    private func dismissMentionPicker() {
        withAnimation(.easeOut(duration: 0.15)) {
            isShowingMentionPicker = false
            mentionQuery = ""
        }
    }
    
    // MARK: - File Preview (QuickLook)
    
    /// Downloads a file from the server and presents it in an in-app QuickLook preview.
    /// Uses a local cache so files don't need to be re-downloaded.
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
    
    // MARK: - Thread Edit Bubble
    
    private var threadEditBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Edit message…", text: $viewModel.editingText, axis: .vertical)
                .scaledFont(size: 13)
                .lineLimit(1...10)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.surfaceContainer.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surfaceContainer.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    // MARK: - Bubble Colors
    
    private var bubbleBg: Color {
        theme.isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.06)
    }
    private var bubbleBorder: Color {
        theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
    
    // MARK: - Message Row
    
    private func threadMessageRow(_ message: ChannelMessage, isParent: Bool, showHeader: Bool, showGroupTimestamp: Bool = false) -> some View {
        let senderName = viewModel.resolvedSenderName(for: message)
        let isModel = viewModel.isModelMessage(message)
        
        return VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HStack(spacing: 8) {
                    threadAvatar(message, size: 26)
                    HStack(spacing: 4) {
                        Text(senderName)
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(isModel ? theme.mentionModelText : theme.textPrimary)
                        if isModel {
                            Text("BOT")
                                .scaledFont(size: 7, weight: .heavy)
                                .foregroundStyle(theme.mentionModelText)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(theme.mentionModelBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        if isParent {
                            Text("OP")
                                .scaledFont(size: 7, weight: .heavy)
                                .foregroundStyle(theme.brandPrimary)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(theme.brandPrimary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                        }
                        Text(message.createdAt.channelTime)
                            .scaledFont(size: 10)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(.bottom, 3)
            }
            
            // Pinned indicator
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
            
            // Bubble (or edit bubble if editing this message)
            if viewModel.editingMessage?.id == message.id {
                threadEditBubble
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if !message.content.isEmpty {
                        ChannelMarkdownView(
                            content: message.content,
                            currentUserId: viewModel.currentUserId,
                            isCurrentUser: false
                        )
                    }
                    if !message.files.isEmpty {
                        threadFileAttachments(message.files)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(bubbleBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(bubbleBorder, lineWidth: 0.5)
                )
            }
            
            if showGroupTimestamp && !showHeader {
                Text(message.createdAt.channelTime)
                    .scaledFont(size: 10)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, showHeader ? 12 : 2)
        .background(isParent ? theme.brandPrimary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4) {
            threadReactionOverlayMessage = message
            Haptics.play(.medium)
        }
    }
    
    @ViewBuilder
    private func threadAvatar(_ message: ChannelMessage, size: CGFloat) -> some View {
        let isModel = viewModel.isModelMessage(message)
        let name = viewModel.resolvedSenderName(for: message)
        if isModel, let model = viewModel.resolveModelForMessage(message) {
            ModelAvatar(size: size, imageURL: model.resolveAvatarURL(baseURL: viewModel.serverBaseURL), label: model.shortName, authToken: viewModel.serverAuthToken)
        } else {
            // Build URL directly from userId — don't depend on member lookup
            let avatarURL: URL? = {
                guard !message.userId.isEmpty, !viewModel.serverBaseURL.isEmpty else { return nil }
                return URL(string: "\(viewModel.serverBaseURL)/api/v1/users/\(message.userId)/profile/image")
            }()
            UserAvatar(
                size: size,
                imageURL: avatarURL,
                name: name,
                authToken: viewModel.serverAuthToken
            )
        }
    }
    
    @ViewBuilder
    private func threadFileAttachments(_ files: [ChatMessageFile]) -> some View {
        let imageFiles = files.filter { $0.type == "image" || ($0.contentType ?? "").hasPrefix("image/") }
        let otherFiles = files.filter { $0.type != "image" && !($0.contentType ?? "").hasPrefix("image/") }
        
        // Image thumbnails — use AuthenticatedImageView (same as channel + AI chat)
        if !imageFiles.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(imageFiles.prefix(3).enumerated()), id: \.offset) { _, file in
                    if let fileId = file.url, !fileId.isEmpty {
                        AuthenticatedImageView(fileId: fileId, apiClient: dependencies.apiClient)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        
        // File cards — tappable with QuickLook preview (same as channel + AI chat)
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
            .frame(maxWidth: 240)
        }
    }
    
    // MARK: - Thread Input (same as channel)
    
    // BUG-011 fix: Thread uses its own threadAttachments array
    private var threadInput: some View {
        VStack(spacing: 0) {
            if !viewModel.threadAttachments.isEmpty {
                threadAttachmentStrip
                    .padding(.horizontal, Spacing.screenPadding)
                    .padding(.bottom, 4)
            }
            
            HStack(alignment: .center, spacing: 8) {
                Button {
                    showThreadAttachmentPicker = true
                    Haptics.play(.light)
                } label: {
                    Image(systemName: "plus")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showThreadAttachmentPicker) {
                    UnifiedAttachmentPicker(
                        onPhotoSelected: { items in
                            Task { await processThreadPhotos(items) }
                        },
                        onFileSelected: { urls in
                            Task { for url in urls { await processThreadFileURL(url) } }
                        },
                        onDismiss: { showThreadAttachmentPicker = false }
                    )
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.hidden)
                }
                
                PasteableTextView(
                    text: $viewModel.threadInputText,
                    placeholder: "Reply in thread…",
                    font: .systemFont(ofSize: 14, weight: .regular),
                    textColor: UIColor(theme.textPrimary),
                    placeholderColor: UIColor(theme.textTertiary),
                    tintColor: UIColor(theme.brandPrimary),
                    isEnabled: true,
                    onPasteAttachments: { attachments in
                        // BUG-011 fix: Paste into thread-specific attachments
                        withAnimation { viewModel.threadAttachments.append(contentsOf: attachments) }
                        for att in attachments { viewModel.uploadAttachmentImmediately(attachmentId: att.id, isThread: true) }
                    },
                    onSubmit: { Task { await viewModel.sendThreadMessage() } },
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
                
                if viewModel.canSendThread {
                    Button {
                        Task { await viewModel.sendThreadMessage() }
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
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(theme.isDark ? 0.2 : 0.06), radius: 8, x: 0, y: 2)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.15), value: viewModel.canSendThread)
    }
    
    // MARK: - Thread Attachment Strip
    
    private var threadAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // BUG-011 fix: Use threadAttachments
                ForEach(viewModel.threadAttachments) { attachment in
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
                            withAnimation { viewModel.threadAttachments.removeAll { $0.id == attachment.id } }
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
    
    // MARK: - Thread Attachment Processing
    
    // BUG-011 fix: Thread attachment processing uses threadAttachments
    private func processThreadPhotos(_ items: [PhotosPickerItem]) async {
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
                viewModel.threadAttachments.append(attachment)
                viewModel.uploadAttachmentImmediately(attachmentId: attachment.id, isThread: true)
            }
        }
    }
    
    private func processThreadFileURL(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let attachment = ChatAttachment(type: .file, name: url.lastPathComponent, thumbnail: nil, data: data)
        viewModel.threadAttachments.append(attachment)
        viewModel.uploadAttachmentImmediately(attachmentId: attachment.id, isThread: true)
    }
}

// MARK: - Channel Members Sheet

struct ChannelMembersSheet: View {
    let members: [ChannelMember]
    let isLoading: Bool
    var serverBaseURL: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var searchText = ""
    
    private var filtered: [ChannelMember] {
        if searchText.isEmpty { return members }
        let q = searchText.lowercased()
        return members.filter {
            $0.displayName.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading && members.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { member in
                        HStack(spacing: Spacing.md) {
                            UserAvatar(
                                size: 36,
                                imageURL: member.resolveAvatarURL(serverBaseURL: serverBaseURL),
                                name: member.displayName
                            )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(member.displayName)
                                        .scaledFont(size: 15, weight: .medium)
                                        .foregroundStyle(theme.textPrimary)
                                    
                                    if member.role == "admin" {
                                        Text("Admin")
                                            .scaledFont(size: 9, weight: .bold)
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(member.email)
                                    .scaledFont(size: 12)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            
                            Spacer()
                            
                            // Online status
                            Circle()
                                .fill(member.isOnline ? Color.green : theme.textTertiary.opacity(0.3))
                                .frame(width: 10, height: 10)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "Search members")
                }
            }
            .navigationTitle("Members (\(members.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - DM Settings Sheet

/// Dedicated settings sheet for Direct Message channels.
/// Shows participants, allows adding people, and leaving the conversation.
/// No name field, no visibility toggle, no delete — per the docs.
struct DmSettingsSheet: View {
    let channel: Channel
    let members: [ChannelMember]
    let allUsers: [ChannelMember]
    let currentUserId: String?
    var serverBaseURL: String = ""
    let onAddMembers: ([String]) async -> Void
    let onLeave: () async -> Void
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var showAddPeoplePicker = false
    @State private var isAddingMembers = false
    @State private var isLeaving = false
    @State private var showLeaveConfirmation = false
    
    /// User IDs already in the DM.
    private var existingMemberIds: Set<String> {
        Set(members.map(\.id)).union(currentUserId.map { [$0] } ?? [])
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Participants
                Section("Participants (\(members.count + 1))") {
                    // Other participants
                    ForEach(members) { member in
                        HStack(spacing: Spacing.md) {
                            ZStack(alignment: .bottomTrailing) {
                                UserAvatar(
                                    size: 36,
                                    imageURL: member.resolveAvatarURL(serverBaseURL: serverBaseURL),
                                    name: member.displayName
                                )
                                Circle()
                                    .fill(member.isOnline ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                                    .offset(x: 2, y: 2)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                    .scaledFont(size: 15, weight: .medium)
                                    .foregroundStyle(theme.textPrimary)
                                Text(member.isOnline ? "Active now" : "Offline")
                                    .scaledFont(size: 12)
                                    .foregroundStyle(member.isOnline ? Color.green : theme.textTertiary)
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    
                    // "You" row
                    HStack(spacing: Spacing.md) {
                        ZStack(alignment: .bottomTrailing) {
                            UserAvatar(
                                size: 36,
                                imageURL: {
                                    guard let userId = currentUserId, !userId.isEmpty, !serverBaseURL.isEmpty else { return nil }
                                    return URL(string: "\(serverBaseURL)/api/v1/users/\(userId)/profile/image")
                                }(),
                                name: "You"
                            )
                            Circle()
                                .fill(Color.green)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(theme.background, lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }
                        Text("You")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                
                // Add People
                Section {
                    Button {
                        showAddPeoplePicker = true
                    } label: {
                        Label {
                            Text("Add People")
                                .scaledFont(size: 15, weight: .medium)
                        } icon: {
                            Image(systemName: "person.badge.plus")
                                .foregroundStyle(theme.brandPrimary)
                        }
                    }
                }
                
                // Leave Conversation
                Section {
                    Button(role: .destructive) {
                        showLeaveConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            if isLeaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Leave Conversation", systemImage: "arrow.right.square")
                                    .scaledFont(size: 15, weight: .semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLeaving)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Leave Conversation", isPresented: $showLeaveConfirmation, titleVisibility: .visible) {
                Button("Leave", role: .destructive) {
                    isLeaving = true
                    Task {
                        await onLeave()
                        isLeaving = false
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll stop receiving messages from this conversation. It will be hidden from your sidebar.")
            }
            .sheet(isPresented: $showAddPeoplePicker) {
                AddAccessSheet(
                    channelId: channel.id,
                    existingMemberIds: existingMemberIds,
                    allUsers: allUsers,
                    isLoading: isAddingMembers,
                    serverBaseURL: serverBaseURL,
                    onAdd: { _, selectedIds in
                        isAddingMembers = true
                        Task {
                            await onAddMembers(selectedIds)
                            isAddingMembers = false
                            showAddPeoplePicker = false
                        }
                    },
                    onCancel: { showAddPeoplePicker = false }
                )
                .interactiveDismissDisabled()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - Pinned Messages Sheet

struct PinnedMessagesSheet: View {
    let messages: [ChannelMessage]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    
    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    ContentUnavailableView {
                        Label("No Pinned Messages", systemImage: "pin.slash")
                    } description: {
                        Text("Pin important messages for easy reference.")
                    }
                } else {
                    List(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .scaledFont(size: 10)
                                    .foregroundStyle(theme.brandPrimary)
                                Text(message.senderName)
                                    .scaledFont(size: 13, weight: .semibold)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(message.createdAt.chatTimestamp)
                                    .scaledFont(size: 11)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            
                            // Use markdown rendering for pinned message content
                            Text(ChannelMessage.parseMentions(in: message.content))
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(4)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Pinned Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
