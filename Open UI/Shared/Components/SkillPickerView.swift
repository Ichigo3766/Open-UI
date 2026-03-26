import SwiftUI

// MARK: - Skill Picker View

/// A searchable overlay that displays the user's skill library, triggered by `$` in the chat input.
///
/// Follows the same UX pattern as `PromptPickerView` and `KnowledgePickerView`:
/// - Floats above the input field
/// - Filters in real-time as the user types after `$`
/// - Dismisses on selection or Escape
struct SkillPickerView: View {
    let query: String
    let skills: [SkillItem]
    let isLoading: Bool
    let onSelect: (SkillItem) -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme

    /// Skills filtered by the current query, matching on name and description.
    /// Only shows active skills (isActive == true).
    private var filteredSkills: [SkillItem] {
        let active = skills.filter(\.isActive)
        guard !query.isEmpty else { return active }
        let lowered = query.lowercased()
        return active.filter { skill in
            skill.name.lowercased().contains(lowered) ||
            (skill.description ?? "").lowercased().contains(lowered)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.brandPrimary)
                Text("Skills")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !query.isEmpty {
                    Text("Filtering: $\(query)")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            Divider()
                .foregroundStyle(theme.cardBorder.opacity(0.3))

            // Content
            if isLoading {
                loadingState
            } else if filteredSkills.isEmpty {
                emptyState
            } else {
                skillList
            }
        }
        .background(theme.cardBackground.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.4), lineWidth: 0.5)
        )
        .shadow(color: theme.isDark ? .black.opacity(0.3) : .black.opacity(0.12), radius: 16, y: -4)
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.xs)
        .frame(maxHeight: 320)
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading skills…")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "brain")
                .scaledFont(size: 24)
                .foregroundStyle(theme.textTertiary.opacity(0.5))
            if skills.isEmpty {
                Text("No skills available")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
                Text("Create skills in your Open WebUI workspace")
                    .scaledFont(size: 11)
                    .foregroundStyle(theme.textTertiary.opacity(0.7))
            } else {
                Text("No skills match \"$\(query)\"")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Skill List

    private var skillList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredSkills) { skill in
                    skillRow(skill)
                        .onTapGesture {
                            onSelect(skill)
                            Haptics.play(.light)
                        }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Skill Row

    private func skillRow(_ skill: SkillItem) -> some View {
        HStack(spacing: Spacing.sm) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.brandPrimary.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: "brain")
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
            }

            // Name & description preview
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                if let desc = skill.description, !desc.isEmpty {
                    Text(desc.prefix(80).replacingOccurrences(of: "\n", with: " "))
                        .scaledFont(size: 11)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
