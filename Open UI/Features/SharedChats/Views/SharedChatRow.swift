import SwiftUI

/// A single row in the Shared Chats list.
/// Shows the conversation title, share date, and copy/revoke action buttons.
struct SharedChatRow: View {
    let conversation: Conversation
    let serverBaseURL: String
    let isUnsharing: Bool
    let onCopyLink: () -> Void
    let onRevoke: () -> Void
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Title row
                Text(conversation.title)
                    .scaledFont(size: 15, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                // Shared date
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                    Text("Shared \(formattedDate)")
                        .scaledFont(size: 13)
                        .foregroundStyle(theme.textTertiary)
                }

                // Action buttons
                HStack(spacing: Spacing.sm) {
                    // Copy link
                    Button {
                        onCopyLink()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .scaledFont(size: 12, weight: .medium)
                            Text("Copy Link")
                                .scaledFont(size: 13, weight: .medium)
                        }
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.brandPrimary.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy share link")

                    // Revoke
                    Button {
                        onRevoke()
                    } label: {
                        if isUnsharing {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(theme.error)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "link.badge.minus")
                                    .scaledFont(size: 12, weight: .medium)
                                Text("Revoke")
                                    .scaledFont(size: 13, weight: .medium)
                            }
                            .foregroundStyle(theme.error)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.error.opacity(0.08))
                            .clipShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isUnsharing)
                    .accessibilityLabel("Revoke share link")
                    .accessibilityHint("Removes public access to this chat")

                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, Spacing.screenPadding)
            .padding(.vertical, Spacing.sm + 2)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .opacity(isUnsharing ? 0.5 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title), shared \(formattedDate)")
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: conversation.updatedAt)
    }
}
