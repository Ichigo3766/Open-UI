import SwiftUI

/// Displays the authenticated user's profile information.
struct ProfileView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @Environment(AppDependencyContainer.self) private var dependencies
    @State private var isEditing = false
    @State private var editName = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.sectionGap) {
                // Avatar and name header
                profileHeader

                // User details
                SettingsSection(header: "User Information") {
                    if isEditing {
                        VStack(spacing: Spacing.md) {
                            HStack(spacing: Spacing.md) {
                                Image(systemName: "person")
                                    .scaledFont(size: 16, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                                    .frame(width: IconSize.lg, height: IconSize.lg)
                                    .background(theme.brandPrimary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text("Name")
                                        .scaledFont(size: 12, weight: .medium)
                                        .foregroundStyle(theme.textTertiary)
                                    TextField("Your name", text: $editName)
                                        .scaledFont(size: 16)
                                        .textFieldStyle(.plain)
                                }
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.chatBubblePadding)

                            if let error = saveError {
                                Text(error)
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.error)
                                    .padding(.horizontal, Spacing.md)
                            }

                            if saveSuccess {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(theme.success)
                                    Text("Profile updated")
                                        .scaledFont(size: 12, weight: .medium)
                                        .foregroundStyle(theme.success)
                                }
                                .padding(.horizontal, Spacing.md)
                            }

                            HStack(spacing: Spacing.md) {
                                Button("Cancel") {
                                    isEditing = false
                                    saveError = nil
                                    saveSuccess = false
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    Task { await saveProfile() }
                                } label: {
                                    HStack(spacing: Spacing.xs) {
                                        if isSaving { ProgressView().controlSize(.small) }
                                        Text("Save")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(theme.brandPrimary)
                                .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.bottom, Spacing.md)
                        }
                    } else {
                        infoRow(icon: "person", label: "Name", value: user?.displayName ?? "—")
                    }
                    infoRow(icon: "envelope", label: "Email", value: user?.email ?? "—")
                    infoRow(icon: "at", label: "Username", value: user?.username ?? "—")
                    infoRow(
                        icon: "shield.checkered",
                        label: "Role",
                        value: user?.role.rawValue.capitalized ?? "—",
                        showDivider: false
                    )
                }

                // Server info
                SettingsSection(header: "Server") {
                    infoRow(
                        icon: "server.rack",
                        label: "Server",
                        value: viewModel.serverName
                    )
                    if let version = viewModel.serverVersion {
                        infoRow(
                            icon: "number",
                            label: "Version",
                            value: version,
                            showDivider: false
                        )
                    }
                }

                // Account status
                if let user {
                    SettingsSection(header: "Account Status") {
                        HStack(spacing: Spacing.md) {
                            Image(systemName: user.isActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(user.isActive ? theme.success : theme.error)
                                .scaledFont(size: 20)

                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(user.isActive ? "Account Active" : "Account Inactive")
                                    .scaledFont(size: 16)
                                    .foregroundStyle(theme.textPrimary)

                                Text(user.isActive
                                    ? "Your account is in good standing"
                                    : "Contact your administrator for access")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(theme.textTertiary)
                            }

                            Spacer()
                        }
                        .padding(Spacing.md)
                    }
                }
            }
            .padding(.vertical, Spacing.lg)
        }
        .background(theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") {
                        editName = user?.displayName ?? ""
                        isEditing = true
                        saveSuccess = false
                        saveError = nil
                    }
                }
            }
        }
    }

    private func saveProfile() async {
        guard let api = dependencies.apiClient else { return }
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        saveError = nil
        saveSuccess = false

        do {
            try await api.updateProfile(name: trimmedName)
            // Update the local user
            viewModel.currentUser?.name = trimmedName
            viewModel.currentUser?.username = trimmedName
            viewModel.cacheCurrentUser()
            saveSuccess = true
            // Auto-dismiss edit mode after a brief success display
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isEditing = false
        } catch {
            saveError = APIError.from(error).errorDescription ?? "Failed to update profile."
        }

        isSaving = false
    }

    private var user: User? { viewModel.currentUser }

    private var profileHeader: some View {
        VStack(spacing: Spacing.md) {
            UserAvatar(
                size: 88,
                imageURL: profileImageURL,
                name: user?.displayName,
                authToken: dependencies.apiClient?.network.authToken
            )

            VStack(spacing: Spacing.xs) {
                Text(user?.displayName ?? "User")
                    .scaledFont(size: 24, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)

                Text(user?.email ?? "")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)

                if let role = user?.role {
                    Text(role.rawValue.capitalized)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(theme.brandPrimary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.top, Spacing.sm)
    }

    private var profileImageURL: URL? {
        guard let userId = user?.id,
              let baseURL = dependencies.apiClient?.baseURL,
              !userId.isEmpty, !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/api/v1/users/\(userId)/profile/image")
    }

    private func infoRow(
        icon: String,
        label: String,
        value: String,
        showDivider: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
                    .frame(width: IconSize.lg, height: IconSize.lg)
                    .background(theme.brandPrimary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(label)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)

                    Text(value)
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.textPrimary)
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.chatBubblePadding)

            if showDivider {
                Divider()
                    .padding(.leading, Spacing.md + IconSize.lg + Spacing.md)
            }
        }
    }
}
