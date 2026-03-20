import SwiftUI

/// A collapsible folder row rendered inside the slide-out drawer of `MainChatView`.
///
/// Shows the folder name with an animated chevron. When expanded, lists
/// the chats inside with a left accent indent. Supports context menu
/// for rename/delete, and drag-and-drop to receive chats.
struct DrawerFolderRow: View {
    var folder: ChatFolder
    @Bindable var folderVM: FolderListViewModel
    var allConversations: [Conversation]
    var activeConversationId: String?
    var activeFolderWorkspaceId: String?
    var onSelectChat: (String) -> Void
    /// Called when the folder name/icon is tapped to open as workspace.
    var onSelectFolder: ((String) -> Void)?
    /// Called when a chat is moved (chatId, targetFolderId) so the caller
    /// can update its own conversation list's folderId.
    var onChatMoved: ((String, String?) -> Void)?
    /// Called when a chat should be deleted.
    var onDeleteChat: ((String) -> Void)?
    /// Called when a chat's pin state should be toggled.
    var onTogglePin: ((Conversation) -> Void)?
    /// Indentation depth for subfolders (0 = root level)
    var depth: Int = 0

    @Environment(\.theme) private var theme
    @State private var showDeleteConfirmation = false

    private var isDropTarget: Bool {
        folderVM.dragTargetFolderId == folder.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Folder header ────────────────────────────────────────
            // Header is split: chevron = expand/collapse, folder icon + name = open workspace
            let isActiveWorkspace = activeFolderWorkspaceId == folder.id
            HStack(spacing: 0) {
                // Depth indentation for subfolders
                if depth > 0 {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: CGFloat(depth) * 16)
                }

                // Chevron button — expand/collapse only
                Button {
                    Haptics.play(.light)
                    Task { await folderVM.toggleExpanded(folder: folder) }
                } label: {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 9, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                        .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: AnimDuration.fast), value: folder.isExpanded)
                        .frame(width: 12)
                        .padding(.vertical, 7)
                        .padding(.leading, Spacing.sm)
                        .padding(.trailing, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Folder name + icon button — opens workspace
                Button {
                    Haptics.play(.light)
                    onSelectFolder?(folder.id)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                            .scaledFont(size: 12)
                            .foregroundStyle(isActiveWorkspace ? theme.brandPrimary : theme.brandPrimary)

                        Text(folder.name)
                            .scaledFont(size: 14, weight: isActiveWorkspace ? .semibold : .medium, context: .list)
                            .foregroundStyle(isActiveWorkspace ? theme.brandPrimary : theme.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        // Chat count badge
                        if folder.isExpanded && !folder.chats.isEmpty {
                            let count = folder.chats.filter { !$0.title.isEmpty }.count
                            if count > 0 {
                                Text("\(count)")
                                    .scaledFont(size: 10, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.trailing, Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    isActiveWorkspace
                        ? theme.brandPrimary.opacity(0.1)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.sm)
                )
            }
            // Drop target highlight
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(isDropTarget ? theme.brandPrimary.opacity(0.12) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.sm)
                            .stroke(theme.brandPrimary, lineWidth: isDropTarget ? 1.5 : 0)
                    )
            )
            .animation(.easeInOut(duration: AnimDuration.fast), value: isDropTarget)
            // Accept dropped chats from anywhere (main list or other folders)
            .dropDestination(for: DraggableChat.self) { items, _ in
                guard let item = items.first,
                      item.currentFolderId != folder.id else { return false }
                folderVM.dragCompleted()
                let chatId = item.conversationId
                let sourceFolderId = item.currentFolderId
                let targetFolderId = folder.id

                // Find the full conversation object (with correct title).
                // Search folder chats first, then the main conversations list.
                let folderChats = folderVM.folders.flatMap(\.chats)
                let conv = folderChats.first(where: { $0.id == chatId })
                    ?? allConversations.first(where: { $0.id == chatId })
                    ?? Conversation(id: chatId, title: "", folderId: sourceFolderId)

                Task {
                    // Auto-expand the target folder so the user sees the chat immediately
                    if let idx = folderVM.folders.firstIndex(where: { $0.id == targetFolderId }),
                       !folderVM.folders[idx].isExpanded {
                        await folderVM.toggleExpanded(folder: folderVM.folders[idx])
                    }
                    await folderVM.moveChat(conversation: conv, to: targetFolderId)
                    // Notify caller to update listViewModel.conversations folderId
                    onChatMoved?(chatId, targetFolderId)
                }
                return true
            } isTargeted: { targeted in
                withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                    if targeted {
                        folderVM.dragEntered(folderId: folder.id)
                    } else {
                        folderVM.dragExited(folderId: folder.id)
                    }
                }
            }
            .contextMenu {
                Button {
                    Task { await folderVM.beginEdit(folder: folder) }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    folderVM.createSubfolderParentId = folder.id
                    folderVM.showCreateSheet = true
                } label: {
                    Label("Create Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    folderVM.beginRename(folder: folder)
                } label: {
                    Label("Rename", systemImage: "character.cursor.ibeam")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
            }
            .confirmationDialog(
                "Delete \"\(folder.name)\"?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Folder Only", role: .destructive) {
                    Task { await folderVM.deleteFolder(id: folder.id, deleteContents: false) }
                }
                Button("Delete Folder and Chats", role: .destructive) {
                    Task { await folderVM.deleteFolder(id: folder.id, deleteContents: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose whether to keep the chats or delete them along with the folder.")
            }

            // ── Expanded chat list + subfolders ─────────────────────
            if folder.isExpanded {
                // Look up the live folder from the flat array so chats/subfolders
                // reflect the latest server data (avoids stale value-type snapshots).
                let liveFolder = folderVM.folders.first(where: { $0.id == folder.id }) ?? folder
                let validChats = liveFolder.chats.filter { !$0.title.isEmpty }
                // Live child folders from the flat array — reactive to isExpanded changes
                let liveChildren = folderVM.folders
                    .filter { $0.parentId == folder.id }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                VStack(spacing: 0) {
                    // Subfolders first (before chats, matching WebUI order)
                    ForEach(liveChildren) { child in
                        DrawerFolderRow(
                            folder: child,
                            folderVM: folderVM,
                            allConversations: allConversations,
                            activeConversationId: activeConversationId,
                            activeFolderWorkspaceId: activeFolderWorkspaceId,
                            onSelectChat: onSelectChat,
                            onSelectFolder: onSelectFolder,
                            onChatMoved: onChatMoved,
                            onDeleteChat: onDeleteChat,
                            onTogglePin: onTogglePin,
                            depth: depth + 1
                        )
                    }

                    // Chats inside this folder
                    if validChats.isEmpty && liveFolder.chats.isEmpty && liveChildren.isEmpty {
                        // Still loading or genuinely empty
                        Text("No chats")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.leading, CGFloat(depth + 2) * 12 + 12)
                            .padding(.vertical, Spacing.xs)
                    } else {
                        ForEach(validChats) { chat in
                            drawerChatRow(chat)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: AnimDuration.fast), value: folder.isExpanded)
    }

    // MARK: - Chat Row Inside Folder

    private func drawerChatRow(_ chat: Conversation) -> some View {
        Button {
            onSelectChat(chat.id)
        } label: {
            HStack(spacing: Spacing.sm) {
                // Indent + accent bar — indent increases with subfolder depth
                Rectangle()
                    .fill(theme.brandPrimary.opacity(0.3))
                    .frame(width: 2)
                    .cornerRadius(1)
                    .padding(.leading, 22 + CGFloat(depth) * 16)

                Text(chat.title)
                    .scaledFont(size: 14)
                    .fontWeight(activeConversationId == chat.id ? .semibold : .regular)
                    .foregroundStyle(
                        activeConversationId == chat.id
                            ? theme.textPrimary
                            : theme.textSecondary
                    )
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.trailing, Spacing.sm)
            .background(
                activeConversationId == chat.id
                    ? theme.brandPrimary.opacity(0.1)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: CornerRadius.sm)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Allow dragging out of folder
        .draggable(DraggableChat(
            conversationId: chat.id,
            currentFolderId: folder.id
        )) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "bubble.left").scaledFont(size: 12)
                Text(chat.title)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu {
            Button {
                onTogglePin?(chat)
            } label: {
                Label(
                    chat.pinned ? "Unpin" : "Pin",
                    systemImage: chat.pinned ? "pin.slash" : "pin"
                )
            }

            Button {
                let chatId = chat.id
                Task {
                    await folderVM.moveChat(conversation: chat, to: nil)
                    onChatMoved?(chatId, nil)
                }
            } label: {
                Label("Remove from Folder", systemImage: "folder.badge.minus")
            }

            let otherFolders = folderVM.folders.filter { $0.id != folder.id }
            if !otherFolders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(otherFolders) { other in
                        Button {
                            Task { await folderVM.moveChat(conversation: chat, to: other.id) }
                        } label: {
                            Label(other.name, systemImage: "folder")
                        }
                    }
                }
            }

            Button(role: .destructive) {
                onDeleteChat?(chat.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel(Text(chat.title))
        .accessibilityHint(Text("Double tap to open. Drag to move between folders."))
    }
}
