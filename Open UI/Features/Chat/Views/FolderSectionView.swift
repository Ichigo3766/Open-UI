import SwiftUI

// MARK: - FolderSectionView

/// The collapsible "Folders" section rendered at the top of the chat list.
///
/// Hosts each ``FolderRow`` and provides a drop target on the section
/// header so that dragged chats can be removed from their current folder
/// (moved to root / no folder) by dropping on the "Chats" area.
struct FolderSectionView: View {
    @Bindable var folderVM: FolderListViewModel
    var allConversations: [Conversation]
    var onNavigateToChat: (String) -> Void
    var onMoveChat: (Conversation, String?) -> Void
    var onDeleteChat: ((String) -> Void)?
    var onTogglePin: ((Conversation) -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        // Folders section
        if !folderVM.folders.isEmpty {
            Section {
                ForEach(folderVM.folders) { folder in
                    FolderRow(
                        folder: folder,
                        allConversations: allConversations,
                        folderVM: folderVM,
                        onNavigateToChat: onNavigateToChat,
                        onMoveChat: onMoveChat,
                        onDeleteChat: onDeleteChat,
                        onTogglePin: onTogglePin
                    )
                }
            } header: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "folder")
                        .scaledFont(size: 10, weight: .medium)
                    Text("Folders")
                        .scaledFont(size: 12, weight: .medium)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(theme.textSecondary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

// MARK: - FolderRow

/// A single folder row that supports expand/collapse, context menu,
/// swipe-to-delete, and drag-and-drop for moving chats.
struct FolderRow: View {
    var folder: ChatFolder
    var allConversations: [Conversation]
    @Bindable var folderVM: FolderListViewModel
    var onNavigateToChat: (String) -> Void
    var onMoveChat: (Conversation, String?) -> Void
    var onDeleteChat: ((String) -> Void)?
    var onTogglePin: ((Conversation) -> Void)?

    @Environment(\.theme) private var theme
    @State private var showDeleteConfirmation = false

    /// Whether this folder row is being dragged over.
    private var isDropTarget: Bool {
        folderVM.dragTargetFolderId == folder.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header row ──────────────────────────────────────────
            folderHeader

            // ── Expanded chat list ──────────────────────────────────
            if folder.isExpanded {
                expandedContent
            }
        }
        // Drop target: accept chats dropped onto this folder
        .dropDestination(for: DraggableChat.self) { items, _ in
            guard let item = items.first else { return false }
            guard item.currentFolderId != folder.id else { return false }
            let conversation = allConversations.first { $0.id == item.conversationId }
                ?? folderVM.folders.flatMap(\.chats).first { $0.id == item.conversationId }
            guard let conversation else { return false }
            folderVM.dragCompleted()
            onMoveChat(conversation, folder.id)
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: AnimDuration.fast)) {
                if isTargeted {
                    folderVM.dragEntered(folderId: folder.id)
                } else {
                    folderVM.dragExited(folderId: folder.id)
                }
            }
        }
        // Drop highlight ring
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.brandPrimary, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
                .animation(.easeInOut(duration: AnimDuration.fast), value: isDropTarget)
        )
        // Context menu on long press
        .contextMenu {
            Button {
                Task { await folderVM.beginEdit(folder: folder) }
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }

            Button {
                folderVM.createSubfolderParentId = folder.id
                folderVM.showCreateSheet = true
            } label: {
                Label(String(localized: "Create Folder"), systemImage: "folder.badge.plus")
            }

            Button {
                folderVM.beginRename(folder: folder)
            } label: {
                Label(String(localized: "Rename"), systemImage: "character.cursor.ibeam")
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(String(localized: "Delete Folder"), systemImage: "trash")
            }
        }
        // Swipe to delete
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        // Delete confirmation — offer "folder only" vs "folder + chats"
        .confirmationDialog(
            String(localized: "Delete \"\(folder.name)\"?"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete Folder Only"), role: .destructive) {
                Task { await folderVM.deleteFolder(id: folder.id, deleteContents: false) }
            }
            Button(String(localized: "Delete Folder and Chats"), role: .destructive) {
                Task { await folderVM.deleteFolder(id: folder.id, deleteContents: true) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Choose whether to keep the chats or delete them along with the folder.")
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: - Header Row

    private var folderHeader: some View {
        Button {
            Task { await folderVM.toggleExpanded(folder: folder) }
        } label: {
            HStack(spacing: Spacing.sm) {
                // Chevron
                Image(systemName: "chevron.right")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: AnimDuration.fast), value: folder.isExpanded)
                    .frame(width: 16)

                // Folder icon + name
                Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                    .scaledFont(size: 15)
                    .foregroundStyle(theme.brandPrimary)

                Text(folder.name)
                    .scaledFont(size: 16)
                    .fontWeight(.medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Chat count badge
                let count = folder.isExpanded
                    ? folder.chats.count
                    : (allConversations.filter { $0.folderId == folder.id }.count)
                if count > 0 {
                    Text("\(count)")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, Spacing.sm)
            .padding(.horizontal, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(folder.name) folder, \(folder.isExpanded ? "expanded" : "collapsed")"))
        .accessibilityHint(Text("Double tap to \(folder.isExpanded ? "collapse" : "expand")"))
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        if folder.chats.isEmpty {
            HStack {
                Spacer()
                Text("No chats in this folder")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.vertical, Spacing.sm)
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                ForEach(folder.chats) { chat in
                    FolderChatRow(
                        conversation: chat,
                        folder: folder,
                        folderVM: folderVM,
                        allConversations: allConversations,
                        onNavigate: { onNavigateToChat(chat.id) },
                        onMoveOut: { onMoveChat(chat, nil) },
                        onMoveToFolder: { targetFolderId in
                            onMoveChat(chat, targetFolderId)
                        },
                        onDelete: { onDeleteChat?(chat.id) },
                        onTogglePin: { onTogglePin?(chat) }
                    )
                }
            }
            .padding(.leading, Spacing.lg + Spacing.sm) // Indent under folder
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - FolderChatRow

/// A chat row rendered inside an expanded folder.
/// Supports drag-out, navigation, and context menu.
private struct FolderChatRow: View {
    let conversation: Conversation
    let folder: ChatFolder
    @Bindable var folderVM: FolderListViewModel
    var allConversations: [Conversation]
    var onNavigate: () -> Void
    var onMoveOut: () -> Void
    var onMoveToFolder: (String) -> Void
    var onDelete: (() -> Void)?
    var onTogglePin: (() -> Void)?

    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            onNavigate()
        } label: {
            HStack(spacing: Spacing.sm) {
                // Left accent line
                Rectangle()
                    .fill(theme.brandPrimary.opacity(0.3))
                    .frame(width: 2)
                    .cornerRadius(1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .scaledFont(size: 14)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Text(conversation.updatedAt.chatTimestamp)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()
            }
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Make the chat draggable out of the folder
        .draggable(DraggableChat(
            conversationId: conversation.id,
            currentFolderId: folder.id
        )) {
            // Drag preview
            HStack(spacing: Spacing.xs) {
                Image(systemName: "bubble.left")
                    .scaledFont(size: 13)
                Text(conversation.title)
                    .scaledFont(size: 12, weight: .medium)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        // Swipe actions
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }

            Button {
                onMoveOut()
            } label: {
                Label(String(localized: "Remove"), systemImage: "folder.badge.minus")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button {
                onTogglePin?()
            } label: {
                Label(
                    conversation.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    systemImage: conversation.pinned ? "pin.slash" : "pin"
                )
            }
            .tint(.blue)
        }
        // Context menu
        .contextMenu {
            Button {
                onTogglePin?()
            } label: {
                Label(
                    conversation.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    systemImage: conversation.pinned ? "pin.slash" : "pin"
                )
            }

            Button {
                onMoveOut()
            } label: {
                Label(String(localized: "Remove from Folder"), systemImage: "folder.badge.minus")
            }

            let otherFolders = folderVM.folders.filter { $0.id != folder.id }
            if !otherFolders.isEmpty {
                Menu(String(localized: "Move to Folder")) {
                    ForEach(otherFolders) { otherFolder in
                        Button {
                            onMoveToFolder(otherFolder.id)
                        } label: {
                            Label(otherFolder.name, systemImage: "folder")
                        }
                    }
                }
            }

            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .accessibilityLabel(Text(conversation.title))
        .accessibilityHint(Text("Double tap to open. Drag to move between folders."))
    }
}
