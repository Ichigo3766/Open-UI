import SwiftUI

/// Main view displaying the list of channels accessible to the current user.
/// Shows channels grouped by type (Standard, Group, DM) with unread badges,
/// search, create, and delete functionality.
struct ChannelsListView: View {
    @State private var viewModel = ChannelListViewModel()
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    
    @State private var channelToDelete: Channel?
    @State private var showDeleteConfirmation = false
    @State private var showNewDMSheet = false
    @State private var isCreatingDM = false
    
    private var serverBaseURL: String { dependencies.apiClient?.baseURL ?? "" }
    private var serverAuthToken: String? { dependencies.apiClient?.network.authToken }
    
    var body: some View {
        @Bindable var router = router
        
        NavigationStack(path: $router.channelPath) {
            Group {
                if viewModel.isLoading && !viewModel.hasLoaded {
                    loadingView
                } else if !viewModel.hasChannels && viewModel.hasLoaded && viewModel.errorMessage == nil {
                    emptyStateView
                } else if let error = viewModel.errorMessage, !viewModel.hasChannels {
                    errorView(error)
                } else {
                    channelsList
                }
            }
            .navigationTitle("Channels")
            .searchable(text: $viewModel.searchText, prompt: "Search channels")
            .toolbar { toolbarContent }
            .navigationDestination(for: ChannelRoute.self) { route in
                switch route {
                case .channelDetail(let channelId):
                    ChannelDetailView(channelId: channelId)
                }
            }
            .sheet(isPresented: $viewModel.showCreateSheet) {
                CreateChannelSheet(
                    onCreate: { name, description, type, isPrivate, memberIds in
                        Task {
                            // DMs can have empty names (web UI sends name="" for DMs)
                            let channelName = (type == .dm) ? name : (name.isEmpty ? "new-channel" : name)
                            if let channel = await viewModel.createChannel(
                                name: channelName,
                                description: description,
                                type: type,
                                isPrivate: isPrivate,
                                userIds: memberIds
                            ) {
                                router.channelPath.append(ChannelRoute.channelDetail(channelId: channel.id))
                            }
                        }
                    },
                    apiClient: dependencies.apiClient,
                    allUsers: viewModel.allServerUsers
                )
            }
            .refreshable {
                await viewModel.refreshChannels()
            }
            .task {
                if let apiClient = dependencies.apiClient {
                    // Ensure we have the current user ID — required for DM participant filtering
                    var userId = dependencies.authViewModel.currentUser?.id
                    if userId == nil || userId?.isEmpty == true {
                        userId = try? await apiClient.getCurrentUser().id
                    }
                    viewModel.configure(apiClient: apiClient, socket: dependencies.socketService, currentUserId: userId)
                }
                await viewModel.loadChannels()
                await viewModel.loadAllServerUsers()
                viewModel.startSocketListener()
            }
            .onDisappear {
                viewModel.stopSocketListener()
            }
            .destructiveConfirmation(
                isPresented: $showDeleteConfirmation,
                title: "Delete Channel",
                message: "This will permanently delete this channel and all its messages.",
                destructiveTitle: "Delete"
            ) {
                if let channel = channelToDelete {
                    Task { await viewModel.deleteChannel(id: channel.id) }
                }
            }
            // New DM user picker sheet
            .sheet(isPresented: $showNewDMSheet) {
                NewDMSheet(
                    allUsers: viewModel.allServerUsers,
                    currentUserId: viewModel.currentUserId,
                    isLoading: isCreatingDM,
                    serverBaseURL: serverBaseURL,
                    onSelectUser: { user in
                        isCreatingDM = true
                        Task {
                            if let channel = await viewModel.startDMWith(userId: user.id) {
                                showNewDMSheet = false
                                isCreatingDM = false
                                router.channelPath.append(ChannelRoute.channelDetail(channelId: channel.id))
                            } else {
                                isCreatingDM = false
                            }
                        }
                    },
                    onCancel: { showNewDMSheet = false }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showNewDMSheet = true
                Task { await viewModel.loadAllServerUsers() }
            } label: {
                Image(systemName: "person.badge.plus")
            }
            .accessibilityLabel("New Direct Message")
            
            Button {
                viewModel.showCreateSheet = true
            } label: {
                Image(systemName: "plus.message")
            }
            .accessibilityLabel("New Channel")
        }
    }
    
    // MARK: - Loading
    
    private var loadingView: some View {
        VStack(spacing: Spacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                SkeletonListItem(showAvatar: true)
            }
        }
        .padding(.top, Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Channels", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Channels are collaborative spaces where users and AI models can interact together.")
        } actions: {
            Button {
                viewModel.showCreateSheet = true
            } label: {
                Label("Create Channel", systemImage: "plus.message")
            }
            .buttonStyle(.borderedProminent)
            .pressEffect()
        }
    }
    
    // MARK: - Error
    
    private func errorView(_ message: String) -> some View {
        ErrorStateView(
            message: "Something Went Wrong",
            detail: message,
            onRetry: { Task { await viewModel.loadChannels() } }
        )
    }
    
    // MARK: - Channels List
    
    private var channelsList: some View {
        List {
            // Standard Channels
            if !viewModel.standardChannels.isEmpty {
                Section("Channels") {
                    ForEach(viewModel.standardChannels) { channel in
                        channelRow(channel)
                    }
                }
            }
            
            // Group Channels
            if !viewModel.groupChannels.isEmpty {
                Section("Groups") {
                    ForEach(viewModel.groupChannels) { channel in
                        channelRow(channel)
                    }
                }
            }
            
            // DM Channels
            if !viewModel.dmChannels.isEmpty {
                Section("Direct Messages") {
                    ForEach(viewModel.dmChannels) { channel in
                        channelRow(channel)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut(duration: 0.2), value: viewModel.channels.map(\.id))
    }
    
    // MARK: - Channel Row (type-aware)
    
    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        Button {
            router.channelPath.append(ChannelRoute.channelDetail(channelId: channel.id))
        } label: {
            HStack(spacing: Spacing.md) {
                // Type-specific avatar/icon
                channelAvatar(channel)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        // Type-specific display name
                        Text(channelDisplayName(channel))
                            .scaledFont(size: 16, weight: channel.unreadCount > 0 ? .semibold : .medium)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Text(channel.updatedAt.chatTimestamp)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    
                    // Type-specific subtitle
                    channelSubtitle(channel)
                }
                
                // Unread badge
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
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if channel.type == .dm {
                // MF-001: Hide DM instead of delete
                Button {
                    viewModel.hideDM(channelId: channel.id)
                    Haptics.play(.light)
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .tint(.orange)
            } else {
                Button(role: .destructive) {
                    channelToDelete = channel
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if channel.type == .dm {
                Button {
                    viewModel.hideDM(channelId: channel.id)
                } label: {
                    Label("Hide Conversation", systemImage: "eye.slash")
                }
            } else {
                Button {
                    channelToDelete = channel
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Channel", systemImage: "trash")
                }
            }
        }
    }
    
    // MARK: - Type-Specific Avatar
    
    @ViewBuilder
    private func channelAvatar(_ channel: Channel) -> some View {
        switch channel.type {
        case .dm:
            // DM: show other participant's avatar with online dot (filter out current user)
            let otherParticipants = channel.dmParticipants.filter { $0.id != viewModel.currentUserId }
            let participant = otherParticipants.first ?? channel.dmParticipants.first
            let name = participant?.displayName ?? channel.displayName
            ZStack(alignment: .bottomTrailing) {
                UserAvatar(
                    size: 40,
                    imageURL: participant?.resolveAvatarURL(serverBaseURL: serverBaseURL),
                    name: name,
                    authToken: serverAuthToken
                )
                // Online status dot
                Circle()
                    .fill(participant?.isOnline == true ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(theme.background, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
            
        case .group:
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "person.3.fill")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(.orange)
            }
            
        case .standard:
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
            }
        }
    }
    
    // MARK: - Type-Specific Display Name
    
    private func channelDisplayName(_ channel: Channel) -> String {
        switch channel.type {
        case .dm:
            // Show only OTHER participants' names — never show current user's own name
            let otherParticipants = channel.dmParticipants.filter { $0.id != viewModel.currentUserId }
            if !otherParticipants.isEmpty {
                return otherParticipants.map { $0.displayName }.joined(separator: ", ")
            }
            // Fallback: if dmParticipants is empty (not yet populated), show displayName
            return channel.displayName
        case .group:
            return channel.name
        case .standard:
            return channel.name
        }
    }
    
    // MARK: - Type-Specific Subtitle
    
    @ViewBuilder
    private func channelSubtitle(_ channel: Channel) -> some View {
        switch channel.type {
        case .dm:
            // Show online/offline status for 1-on-1 DMs, or last message snippet
            if let participant = channel.dmParticipants.first, channel.dmParticipants.count == 1 {
                Text(participant.isOnline ? "Active now" : "Offline")
                    .scaledFont(size: 13)
                    .foregroundStyle(participant.isOnline ? Color.green : theme.textTertiary)
            } else if let lastMsg = channel.lastMessage {
                Text(lastMsg.content.prefix(50))
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            
        case .group:
            if let description = channel.description, !description.isEmpty {
                Text(description)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            
        case .standard:
            if let description = channel.description, !description.isEmpty {
                Text(description)
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Channel Route

enum ChannelRoute: Hashable {
    case channelDetail(channelId: String)
}

// MARK: - Create / Edit Channel Sheet

/// Shared sheet for creating a new channel or editing an existing one.
///
/// Access list members are derived from `channel.accessGrants` (the single source of truth),
/// resolved against `allUsers` for display names. The sheet owns local copies of grants
/// and members so mutations are optimistic and don't depend on parent re-renders.
struct CreateChannelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    
    // MARK: - Callbacks
    
    /// (name, description, type, isPrivate, memberIds) — memberIds used for Group + DM types.
    var onCreate: ((String, String?, ChannelType, Bool, [String]) -> Void)?
    var onUpdate: ((Channel, String, String?, Bool) -> Void)?
    var onDelete: ((Channel) -> Void)?
    /// Update the full access_grants array on the server (Standard channels only).
    var onUpdateAccessGrants: ((String, [[String: Any]]) async -> Void)?
    /// Add members to a Group channel: (channelId, userIds).
    var onAddGroupMembers: ((String, [String]) async -> Void)?
    /// Remove members from a Group channel: (channelId, userIds).
    var onRemoveGroupMembers: ((String, [String]) async -> Void)?
    
    /// APIClient for self-fetching users (DM creation).
    var apiClient: APIClient?
    var editingChannel: Channel?
    /// All server users — used for pickers.
    var allUsers: [ChannelMember] = []
    /// Current channel members — used for Group edit mode.
    var channelMembers: [ChannelMember] = []
    
    // MARK: - Local State
    
    @State private var name = ""
    @State private var description = ""
    @State private var channelType: ChannelType = .standard
    @State private var isPrivate = true
    @State private var showDeleteConfirmation = false
    @State private var showAddMemberPicker = false
    
    /// Local copy of access grants — for Standard channel edit mode.
    @State private var localAccessGrants: [AccessGrant] = []
    
    /// Local copy of group members — for Group channel edit mode.
    @State private var localGroupMembers: [ChannelMember] = []
    
    /// Selected member IDs for Group creation.
    @State private var selectedGroupMemberIds: Set<String> = []
    
    /// Resolved members for group creation display (avoids inline filter ambiguity).
    private var selectedGroupMembers: [ChannelMember] {
        let ids = selectedGroupMemberIds
        return effectiveUsers.filter { ids.contains($0.id) }
    }
    
    @State private var togglingMemberIds: Set<String> = []
    @State private var removingMemberIds: Set<String> = []
    @State private var isAddingMembers = false
    
    /// Search text for DM inline user list.
    @State private var dmUserSearch = ""
    
    /// Self-fetched users for DM/Group inline selection (fetched via apiClient).
    @State private var fetchedUsers: [ChannelMember] = []
    @State private var isLoadingUsers = false
    @State private var hasFetchedUsers = false
    
    /// The effective user list — uses self-fetched users if available, otherwise allUsers from parent.
    private var effectiveUsers: [ChannelMember] {
        fetchedUsers.isEmpty ? allUsers : fetchedUsers
    }
    
    /// Filtered users for DM inline selection.
    private var dmFilteredUsers: [ChannelMember] {
        if dmUserSearch.isEmpty { return effectiveUsers }
        let q = dmUserSearch.lowercased()
        return effectiveUsers.filter {
            ($0.name ?? "").lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
    }
    
    private var isEditMode: Bool { editingChannel != nil }
    
    /// Members derived from access grants (Standard channels).
    private var grantMembers: [ChannelMember] {
        let grantUserIds = Set(localAccessGrants.compactMap(\.userId))
        return allUsers.filter { grantUserIds.contains($0.id) }
    }
    
    private var existingGrantUserIds: Set<String> {
        Set(localAccessGrants.compactMap(\.userId))
    }
    
    /// Existing member IDs for Group channel (edit mode).
    private var existingGroupMemberIds: Set<String> {
        Set(localGroupMembers.map(\.id))
    }
    
    /// Resolves the effective permission for a user.
    /// The server stores read and write as SEPARATE grant entries (not a boolean).
    /// A user with write access has TWO grants: one "read" + one "write".
    /// A user with read-only access has ONE grant: just "read".
    private func permission(for memberId: String) -> String {
        let userGrants = localAccessGrants.filter { $0.userId == memberId }
        // If any grant has write=true, the user has write access
        if userGrants.contains(where: { $0.write }) { return "write" }
        return "read"
    }
    
    /// Builds access_grants payload matching the web UI format exactly.
    /// Web UI sends only: {principal_type, principal_id, permission}
    /// Server auto-fills id, resource_type, resource_id, created_at.
    private func buildGrantsPayload() -> [[String: Any]] {
        return localAccessGrants.map { grant in
            [
                "principal_type": grant.groupId != nil ? "group" : "user",
                "principal_id": grant.groupId ?? grant.userId ?? "",
                "permission": grant.write ? "write" : "read"
            ] as [String: Any]
        }
    }
    
    /// Dynamic nav title based on type.
    private var sheetTitle: String {
        if isEditMode {
            switch channelType {
            case .standard: return "Edit Channel"
            case .group: return "Edit Group"
            case .dm: return "Edit Channel"
            }
        } else {
            switch channelType {
            case .standard: return "New Channel"
            case .group: return "New Group"
            case .dm: return "New Channel"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                if isEditMode {
                    Section("Channel Type") {
                        HStack(spacing: 8) {
                            Image(systemName: channelType.iconName)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                            Text(channelType.displayName)
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                
                // Channel Info — adapts per type
                if channelType == .dm {
                    Section("Channel Name") {
                        TextField("new-channel", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Optional")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                } else {
                    Section(channelType == .group ? "Group Info" : "Channel Info") {
                        TextField(channelType == .group ? "Group name" : "Channel name", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Description (optional)", text: $description)
                    }
                }
                
                // Type picker — all 3 types
                if !isEditMode {
                    Section("Type") {
                        Picker("Channel Type", selection: $channelType) {
                            Text("Channel").tag(ChannelType.standard)
                            Text("Group").tag(ChannelType.group)
                            Text("Direct Message").tag(ChannelType.dm)
                        }
                        // Type description
                        switch channelType {
                        case .standard:
                            Text("Traditional topic-based channel")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        case .group:
                            Text("Membership-based collaboration space")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        case .dm:
                            Text("Private conversation between selected users")
                                .scaledFont(size: 12)
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                
                // Visibility — Standard and Group only (DMs are always private)
                if channelType != .dm {
                    visibilitySection
                }
                
                // Type-specific management sections (edit mode)
                if isEditMode, let channel = editingChannel {
                    switch channelType {
                    case .standard:
                        // Standard: Access Grants with read/write permissions
                        accessListSection(channel: channel)
                    case .group:
                        // Group: Member list with add/remove (no permissions)
                        groupMembersSection(channel: channel)
                    case .dm:
                        EmptyView() // DMs don't use this sheet for edit
                    }
                    
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Label(channelType == .group ? "Delete Group" : "Delete Channel", systemImage: "trash")
                                    .scaledFont(size: 15, weight: .semibold)
                                Spacer()
                            }
                        }
                    }
                }
                
                // Group create mode: initial member selection
                if !isEditMode && channelType == .group {
                    groupCreateMembersSection
                }
                
                // DM create mode: inline user multi-select (matches web UI)
                if !isEditMode && channelType == .dm {
                    dmUserSelectionSection
                }
            }
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditMode ? "Update" : "Create") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
                        if editingChannel != nil {
                            onUpdate?(editingChannel!, trimmedName, desc.isEmpty ? nil : desc, isPrivate)
                        } else {
                            // Pass selected member IDs for Group + DM creation
                            let memberIds = (channelType == .group || channelType == .dm) ? Array(selectedGroupMemberIds) : []
                            onCreate?(trimmedName, desc.isEmpty ? nil : desc, channelType, isPrivate, memberIds)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(channelType == .dm
                        ? selectedGroupMemberIds.isEmpty  // DM: need at least 1 user selected
                        : name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let channel = editingChannel { onDelete?(channel) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let typeLabel = channelType == .group ? "group" : "channel"
                Text("This will permanently delete this \(typeLabel) and all its messages.")
            }
            .onAppear {
                if let channel = editingChannel {
                    name = channel.name
                    description = channel.description ?? ""
                    channelType = channel.type
                    isPrivate = channel.isPrivate
                    localAccessGrants = channel.accessGrants
                    localGroupMembers = channelMembers
                }
            }
            .task {
                // Self-fetch users via apiClient — ensures users are always available
                guard let apiClient, !hasFetchedUsers else { return }
                hasFetchedUsers = true
                isLoadingUsers = true
                do {
                    fetchedUsers = try await apiClient.searchUsers()
                } catch {
                    // Fall back to allUsers from parent
                }
                isLoadingUsers = false
            }
            .sheet(isPresented: $showAddMemberPicker) {
                if channelType == .group {
                    // Group mode: add members (no permissions)
                    AddAccessSheet(
                        channelId: editingChannel?.id ?? "",
                        existingMemberIds: existingGroupMemberIds,
                        allUsers: effectiveUsers,
                        isLoading: isAddingMembers,
                        serverBaseURL: apiClient?.baseURL ?? "",
                        authToken: apiClient?.network.authToken,
                        onAdd: { channelId, selectedIds in
                            handleAddGroupMembers(channelId: channelId, userIds: selectedIds)
                        },
                        onCancel: { showAddMemberPicker = false }
                    )
                    .interactiveDismissDisabled()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                } else if let channel = editingChannel {
                    // Standard mode: add access grants with permissions
                    AddAccessSheet(
                        channelId: channel.id,
                        existingMemberIds: existingGrantUserIds,
                        allUsers: effectiveUsers,
                        isLoading: isAddingMembers,
                        serverBaseURL: apiClient?.baseURL ?? "",
                        authToken: apiClient?.network.authToken,
                        onAdd: { channelId, selectedIds in
                            handleAddAccessGrants(channelId: channelId, userIds: selectedIds)
                        },
                        onCancel: { showAddMemberPicker = false }
                    )
                    .interactiveDismissDisabled()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
    }
    
    // MARK: - Visibility Section
    
    @ViewBuilder
    private var visibilitySection: some View {
        Section("Visibility") {
            Button {
                isPrivate = false
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .scaledFont(size: 16)
                        .foregroundStyle(!isPrivate ? theme.brandPrimary : theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Public")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text(channelType == .group
                            ? "Anyone can find and join this group"
                            : "All registered users can see and join this channel")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    Spacer()
                    if !isPrivate {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }
            }
            .buttonStyle(.plain)
            
            Button {
                isPrivate = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "lock")
                        .scaledFont(size: 16)
                        .foregroundStyle(isPrivate ? theme.brandPrimary : theme.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private")
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Text(channelType == .group
                            ? "Only invited members can access this group"
                            : "Only select users and groups with permission can access")
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                    }
                    Spacer()
                    if isPrivate {
                        Image(systemName: "checkmark")
                            .scaledFont(size: 14, weight: .semibold)
                            .foregroundStyle(theme.brandPrimary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Standard: Access Grants Section (read/write permissions)
    
    @ViewBuilder
    private func accessListSection(channel: Channel) -> some View {
        Section("Access Control") {
            if grantMembers.isEmpty {
                Text("No access grants configured.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(grantMembers) { member in
                    accessRow(member: member, channel: channel)
                }
            }
            
            Button {
                showAddMemberPicker = true
            } label: {
                Label("Add Access", systemImage: "plus")
                    .scaledFont(size: 14, weight: .medium)
            }
        }
    }
    
    @ViewBuilder
    private func accessRow(member: ChannelMember, channel: Channel) -> some View {
        let perm = permission(for: member.id)
        let isToggling = togglingMemberIds.contains(member.id)
        let isRemoving = removingMemberIds.contains(member.id)
        
        HStack(spacing: Spacing.sm) {
            UserAvatar(
                size: 30,
                imageURL: {
                    let base = apiClient?.baseURL ?? ""
                    guard !base.isEmpty else { return nil }
                    return URL(string: "\(base)/api/v1/users/\(member.id)/profile/image")
                }(),
                name: member.displayName,
                authToken: apiClient?.network.authToken
            )
            
            Text(member.displayName)
                .scaledFont(size: 14, weight: .medium)
                .foregroundStyle(theme.textPrimary)
            
            Spacer()
            
            // Permission toggle (Standard channels only)
            Button {
                handleTogglePermission(channelId: channel.id, userId: member.id, currentPerm: perm)
            } label: {
                if isToggling {
                    ProgressView().controlSize(.mini).frame(width: 50, height: 20)
                } else {
                    Text(perm.uppercased())
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(perm == "write" ? .green : .orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((perm == "write" ? Color.green : Color.orange).opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain).disabled(isToggling)
            
            Button {
                handleRemoveAccessGrant(channelId: channel.id, userId: member.id)
            } label: {
                if isRemoving {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                } else {
                    Image(systemName: "xmark").scaledFont(size: 11, weight: .semibold).foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain).disabled(isRemoving)
        }
        .opacity(isRemoving ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: perm)
    }
    
    // MARK: - Group: Members Section (no permissions, just add/remove)
    
    @ViewBuilder
    private func groupMembersSection(channel: Channel) -> some View {
        Section("Members (\(localGroupMembers.count))") {
            if localGroupMembers.isEmpty {
                Text("No members yet.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(localGroupMembers) { member in
                    groupMemberRow(member: member, channel: channel)
                }
            }
            
            Button {
                showAddMemberPicker = true
            } label: {
                Label("Add Members", systemImage: "person.badge.plus")
                    .scaledFont(size: 14, weight: .medium)
            }
        }
    }
    
    @ViewBuilder
    private func groupMemberRow(member: ChannelMember, channel: Channel) -> some View {
        let isRemoving = removingMemberIds.contains(member.id)
        
        HStack(spacing: Spacing.sm) {
            UserAvatar(
                size: 30,
                imageURL: {
                    let base = apiClient?.baseURL ?? ""
                    guard !base.isEmpty else { return nil }
                    return URL(string: "\(base)/api/v1/users/\(member.id)/profile/image")
                }(),
                name: member.displayName,
                authToken: apiClient?.network.authToken
            )
            
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                if let role = member.role {
                    Text(role.capitalized)
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            
            Spacer()
            
            // Online indicator
            Circle()
                .fill(member.isOnline ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
            
            Button {
                handleRemoveGroupMember(channelId: channel.id, userId: member.id)
            } label: {
                if isRemoving {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                } else {
                    Image(systemName: "xmark").scaledFont(size: 11, weight: .semibold).foregroundStyle(theme.textTertiary)
                }
            }
            .buttonStyle(.plain).disabled(isRemoving)
        }
        .opacity(isRemoving ? 0.5 : 1.0)
    }
    
    // MARK: - Group Create: Initial Member Selection
    
    @ViewBuilder
    private var groupCreateMembersSection: some View {
        Section("Initial Members") {
            if selectedGroupMemberIds.isEmpty {
                Text("No members selected. You can add members after creation.")
                    .scaledFont(size: 13)
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(selectedGroupMembers) { user in
                    HStack(spacing: Spacing.sm) {
                        UserAvatar(
                            size: 28,
                            imageURL: {
                                let base = apiClient?.baseURL ?? ""
                                guard !base.isEmpty else { return nil }
                                return URL(string: "\(base)/api/v1/users/\(user.id)/profile/image")
                            }(),
                            name: user.displayName,
                            authToken: apiClient?.network.authToken
                        )
                        Text(user.displayName)
                            .scaledFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Button {
                            withAnimation { _ = selectedGroupMemberIds.remove(user.id) }
                        } label: {
                            Image(systemName: "xmark")
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Button {
                showAddMemberPicker = true
            } label: {
                Label("Add Members", systemImage: "person.badge.plus")
                    .scaledFont(size: 14, weight: .medium)
            }
        }
    }
    
    // MARK: - DM Create: Inline User Selection (matches web UI)
    
    @ViewBuilder
    private var dmUserSelectionSection: some View {
        Section {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textTertiary)
                TextField("Search", text: $dmUserSearch)
                    .scaledFont(size: 14)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            
            // User list header
            Text("Users")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)
            
            // User list with checkboxes
            ForEach(dmFilteredUsers) { user in
                Button {
                    if selectedGroupMemberIds.contains(user.id) {
                        selectedGroupMemberIds.remove(user.id)
                    } else {
                        selectedGroupMemberIds.insert(user.id)
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        UserAvatar(
                            size: 32,
                            imageURL: {
                                let base = apiClient?.baseURL ?? ""
                                guard !base.isEmpty else { return nil }
                                return URL(string: "\(base)/api/v1/users/\(user.id)/profile/image")
                            }(),
                            name: user.displayName,
                            authToken: apiClient?.network.authToken
                        )
                        
                        Text(user.displayName)
                            .scaledFont(size: 15, weight: .medium)
                            .foregroundStyle(theme.textPrimary)
                        
                        Spacer()
                        
                        Image(systemName: selectedGroupMemberIds.contains(user.id) ? "checkmark.square.fill" : "square")
                            .scaledFont(size: 20)
                            .foregroundStyle(selectedGroupMemberIds.contains(user.id) ? theme.brandPrimary : theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Standard Channel Action Handlers
    
    /// Toggles a user between read-only and write access.
    /// Server model: read-only = 1 grant ("read"), write = 2 grants ("read" + "write").
    /// Toggle TO write: add a "write" grant alongside the existing "read" grant.
    /// Toggle FROM write: remove the "write" grant, keep "read".
    private func handleTogglePermission(channelId: String, userId: String, currentPerm: String) {
        Haptics.play(.light)
        togglingMemberIds.insert(userId)
        
        if currentPerm == "write" {
            // Downgrade to read: remove write grants for this user
            withAnimation(.easeInOut(duration: 0.15)) {
                localAccessGrants.removeAll { $0.userId == userId && $0.write }
            }
            // Ensure at least a read grant exists
            if !localAccessGrants.contains(where: { $0.userId == userId }) {
                localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false))
            }
        } else {
            // Upgrade to write: add a write grant (keep existing read grant)
            localAccessGrants.append(AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: false, write: true))
        }
        
        Task {
            await onUpdateAccessGrants?(channelId, buildGrantsPayload())
            togglingMemberIds.remove(userId)
        }
    }
    
    private func handleRemoveAccessGrant(channelId: String, userId: String) {
        removingMemberIds.insert(userId)
        Haptics.play(.light)
        withAnimation(.easeInOut(duration: 0.2)) {
            // Remove ALL grants for this user (both read and write)
            localAccessGrants.removeAll { $0.userId == userId }
        }
        Task {
            await onUpdateAccessGrants?(channelId, buildGrantsPayload())
            removingMemberIds.remove(userId)
        }
    }
    
    /// Adds new users with read-only access (single "read" grant per user).
    private func handleAddAccessGrants(channelId: String, userIds: [String]) {
        isAddingMembers = true
        let newGrants = userIds.map { userId in
            AccessGrant(id: UUID().uuidString, userId: userId, groupId: nil, read: true, write: false)
        }
        withAnimation(.easeInOut(duration: 0.2)) { localAccessGrants.append(contentsOf: newGrants) }
        showAddMemberPicker = false
        Task {
            await onUpdateAccessGrants?(channelId, buildGrantsPayload())
            isAddingMembers = false
        }
    }
    
    // MARK: - Group Channel Action Handlers
    
    private func handleAddGroupMembers(channelId: String, userIds: [String]) {
        isAddingMembers = true
        // If in create mode, just add to selection
        if !isEditMode {
            withAnimation { selectedGroupMemberIds.formUnion(userIds) }
            showAddMemberPicker = false
            isAddingMembers = false
            return
        }
        // Edit mode: optimistic add + API call
        let newMembers = allUsers.filter { userIds.contains($0.id) }
        withAnimation(.easeInOut(duration: 0.2)) { localGroupMembers.append(contentsOf: newMembers) }
        showAddMemberPicker = false
        Task {
            await onAddGroupMembers?(channelId, userIds)
            isAddingMembers = false
        }
    }
    
    private func handleRemoveGroupMember(channelId: String, userId: String) {
        removingMemberIds.insert(userId)
        Haptics.play(.light)
        withAnimation(.easeInOut(duration: 0.2)) {
            localGroupMembers.removeAll { $0.id == userId }
        }
        Task {
            await onRemoveGroupMembers?(channelId, [userId])
            removingMemberIds.remove(userId)
        }
    }
}

// MARK: - Add Access Sheet

/// Multi-select user picker with search, checkboxes, and Add button.
/// Presented as a child sheet — uses callbacks that don't trigger parent re-renders.
struct AddAccessSheet: View {
    @Environment(\.theme) private var theme
    
    let channelId: String
    let existingMemberIds: Set<String>
    let allUsers: [ChannelMember]
    let isLoading: Bool
    var serverBaseURL: String = ""
    var authToken: String?
    let onAdd: (String, [String]) -> Void
    let onCancel: () -> Void
    
    @State private var searchText = ""
    @State private var selectedUserIds: Set<String> = []
    
    private var availableUsers: [ChannelMember] {
        let filtered = allUsers.filter { !existingMemberIds.contains($0.id) }
        if searchText.isEmpty { return filtered }
        let query = searchText.lowercased()
        return filtered.filter {
            ($0.name ?? "").lowercased().contains(query) ||
            $0.email.lowercased().contains(query)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("Search", text: $searchText)
                        .scaledFont(size: 15)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, 8)
                
                if availableUsers.isEmpty {
                    ContentUnavailableView {
                        Label("No Users", systemImage: "person.slash")
                    } description: {
                        Text(searchText.isEmpty
                            ? "All available users already have access."
                            : "No users match your search.")
                    }
                } else {
                    Text("Users")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.screenPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    
                    List(availableUsers) { user in
                        Button {
                            if selectedUserIds.contains(user.id) {
                                selectedUserIds.remove(user.id)
                            } else {
                                selectedUserIds.insert(user.id)
                            }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                UserAvatar(
                                    size: 32,
                                    imageURL: {
                                        guard !serverBaseURL.isEmpty else { return nil }
                                        return URL(string: "\(serverBaseURL)/api/v1/users/\(user.id)/profile/image")
                                    }(),
                                    name: user.displayName,
                                    authToken: authToken
                                )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.displayName)
                                        .scaledFont(size: 15, weight: .medium)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(user.role?.capitalized ?? "User")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: selectedUserIds.contains(user.id) ? "checkmark.square.fill" : "square")
                                    .scaledFont(size: 20)
                                    .foregroundStyle(selectedUserIds.contains(user.id) ? theme.brandPrimary : theme.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
                
                // Add button
                Button {
                    onAdd(channelId, Array(selectedUserIds))
                } label: {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(isLoading ? "Adding…" : "Add")
                            .scaledFont(size: 16, weight: .semibold)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedUserIds.isEmpty || isLoading ? theme.textTertiary.opacity(0.3) : theme.brandPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selectedUserIds.isEmpty || isLoading)
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.vertical, 12)
            }
            .navigationTitle("Add Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { onCancel() } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 14, weight: .semibold)
                    }
                    .disabled(isLoading)
                }
            }
        }
    }
}

// MARK: - New DM Sheet

/// Dedicated user picker for starting a new Direct Message.
/// Tap a user → creates/opens a DM channel and navigates to it.
struct NewDMSheet: View {
    let allUsers: [ChannelMember]
    let currentUserId: String?
    let isLoading: Bool
    var serverBaseURL: String = ""
    let onSelectUser: (ChannelMember) -> Void
    let onCancel: () -> Void
    
    @State private var searchText = ""
    @Environment(\.theme) private var theme
    
    private var filteredUsers: [ChannelMember] {
        // Exclude the current user from the list
        let users = allUsers.filter { $0.id != currentUserId }
        if searchText.isEmpty { return users }
        let query = searchText.lowercased()
        return users.filter {
            ($0.name ?? "").lowercased().contains(query)
            || $0.email.lowercased().contains(query)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("Search people…", text: $searchText)
                        .scaledFont(size: 15)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, Spacing.screenPadding)
                .padding(.top, 8)
                
                if filteredUsers.isEmpty {
                    ContentUnavailableView {
                        Label("No Users", systemImage: "person.slash")
                    } description: {
                        Text(searchText.isEmpty
                            ? "No users available."
                            : "No users match \"\(searchText)\".")
                    }
                } else {
                    List(filteredUsers) { user in
                        Button {
                            onSelectUser(user)
                        } label: {
                            HStack(spacing: Spacing.md) {
                                // Avatar with online dot
                                ZStack(alignment: .bottomTrailing) {
                                    UserAvatar(
                                        size: 40,
                                        imageURL: user.resolveAvatarURL(serverBaseURL: serverBaseURL),
                                        name: user.displayName
                                    )
                                    Circle()
                                        .fill(user.isOnline ? Color.green : Color.gray.opacity(0.4))
                                        .frame(width: 12, height: 12)
                                        .overlay(Circle().stroke(theme.background, lineWidth: 2))
                                        .offset(x: 2, y: 2)
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(user.displayName)
                                        .scaledFont(size: 16, weight: .medium)
                                        .foregroundStyle(theme.textPrimary)
                                    Text(user.email)
                                        .scaledFont(size: 13)
                                        .foregroundStyle(theme.textTertiary)
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .disabled(isLoading)
                }
            }
        }
    }
}
