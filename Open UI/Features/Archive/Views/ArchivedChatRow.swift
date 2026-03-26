import SwiftUI

/// A single row in the Archived Chats list.
/// Shows the conversation title, a relative archive timestamp, and a restore button.
struct ArchivedChatRow: View {
    let conversation: Conversation
    let isRestoring: Bool
    let isDeleting: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.sm) {
                // Leading content
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .scaledFont(size: 15, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: "archivebox")
                            .scaledFont(size: 11)
                            .foregroundStyle(theme.textTertiary)
                        Text(relativeTimestamp)
                            .scaledFont(size: 13)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Restore button
                Button {
                    onRestore()
                } label: {
                    if isRestoring {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.brandPrimary)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .scaledFont(size: 22)
                            .foregroundStyle(theme.brandPrimary)
                            .frame(width: 32, height: 32)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(isRestoring || isDeleting)
                .accessibilityLabel("Restore chat")
                .accessibilityHint("Moves this chat back to your main list")
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.sm + 2)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(isDeleting ? 0.4 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title), archived \(relativeTimestamp)")
    }

    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())
    }
}
