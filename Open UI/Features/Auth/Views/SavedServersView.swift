import SwiftUI

/// Full-page server switcher — shows all saved server profiles with their
/// last-used account info, connection status, and switch/edit/delete actions.
///
/// Presented as:
/// - The root phase after sign-out when multiple servers are saved.
/// - A sheet/navigation destination from Settings → "Switch Server".
/// - The bottom section of `ServerConnectionView` when servers exist.
struct SavedServersView: View {
    @Bindable var viewModel: AuthViewModel
    /// When `true`, the view includes an "Add New Server" button and full controls.
    /// When `false` (embedded in ServerConnectionView), it's a compact list.
    var showAddServerButton: Bool = true
    /// Optional dismiss action for sheet presentation.
    var onDismiss: (() -> Void)? = nil

    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @State private var serverToDelete: ServerConfig?
    @State private var showDeleteConfirmation = false
    @State private var isSwitching = false
    @State private var switchingServerId: String?
    /// Sheet state for "Add New Server" — presented modally so the user can cancel.
    @State private var showAddServerSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — only shown when used as a standalone screen
            if showAddServerButton {
                headerView
                    .padding(.bottom, Spacing.lg)
            }

            if viewModel.savedServers.isEmpty {
                emptyStateView
            } else {
                serverListView
            }

            if showAddServerButton {
                addServerButton
                    .padding(.top, Spacing.lg)
            }
        }
        // "Add New Server" — presented as a sheet so the user can cancel
        .sheet(isPresented: $showAddServerSheet) {
            AddServerSheet(viewModel: viewModel, onDismiss: {
                showAddServerSheet = false
            })
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "server.rack")
                .scaledFont(size: 36)
                .foregroundStyle(theme.brandPrimary)
                .padding(.bottom, Spacing.xs)

            Text("Your Servers")
                .scaledFont(size: 28, weight: .bold, design: .rounded)
                .foregroundStyle(theme.textPrimary)

            Text("Select a server to continue")
                .scaledFont(size: 15)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xl)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "network.slash")
                .scaledFont(size: 44)
                .foregroundStyle(theme.textTertiary)
            Text("No Saved Servers")
                .scaledFont(size: 17, weight: .semibold)
                .foregroundStyle(theme.textPrimary)
            Text("Connect to an OpenWebUI server to get started.")
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    // MARK: - Server List

    private var serverListView: some View {
        VStack(spacing: Spacing.md) {
            ForEach(viewModel.savedServers) { server in
                ServerRowView(
                    server: server,
                    isActive: dependencies.serverConfigStore.activeServer?.id == server.id,
                    isSwitching: switchingServerId == server.id && isSwitching,
                    onSwitch: {
                        Task { await handleSwitch(to: server) }
                    },
                    onSignInDifferentUser: {
                        Task { await handleSignInDifferentUser(for: server) }
                    },
                    onDelete: {
                        serverToDelete = server
                        showDeleteConfirmation = true
                    }
                )
            }
        }
        .padding(.horizontal, Spacing.screenPadding)
        .confirmationDialog(
            "Remove Server",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let server = serverToDelete {
                Button("Remove \"\(server.name)\"", role: .destructive) {
                    Task { await viewModel.removeServer(id: server.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                serverToDelete = nil
            }
        } message: {
            if let server = serverToDelete {
                Text("This will remove \"\(server.name)\" and sign you out of that server. Your server-side data is not affected.")
            }
        }
    }

    // MARK: - Add Server Button

    private var addServerButton: some View {
        Button {
            // Present as a sheet — user can cancel without losing current session
            showAddServerSheet = true
        } label: {
            Label("Add New Server", systemImage: "plus.circle.fill")
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(theme.brandPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.08))
                )
        }
        .padding(.horizontal, Spacing.screenPadding)
        .padding(.bottom, Spacing.xl)
    }

    // MARK: - Switch Handler

    private func handleSwitch(to server: ServerConfig) async {
        guard !isSwitching else { return }
        isSwitching = true
        switchingServerId = server.id
        onDismiss?()
        await viewModel.switchToServer(server)
        isSwitching = false
        switchingServerId = nil
    }

    // MARK: - Sign In As Different User

    /// Switches to the server and immediately signs out, landing the user on
    /// the auth method selection screen so they can log in as a different account.
    private func handleSignInDifferentUser(for server: ServerConfig) async {
        onDismiss?()
        // If this is already the active server, just sign out
        if dependencies.serverConfigStore.activeServer?.id == server.id {
            await viewModel.signOut()
        } else {
            // Switch to the server first, then sign out
            await viewModel.switchToServer(server)
            // After switch we may be authenticated (cached session); sign out to reach login screen
            if viewModel.phase == .authenticated {
                await viewModel.signOut()
            }
            // If switch landed on authMethodSelection (no token), we're already there
        }
    }
}

// MARK: - Server Row

private struct ServerRowView: View {
    let server: ServerConfig
    let isActive: Bool
    let isSwitching: Bool
    let onSwitch: () -> Void
    let onSignInDifferentUser: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    private var hasToken: Bool {
        KeychainService.shared.hasToken(forServer: server.url)
    }

    private var statusColor: Color {
        if isActive { return theme.success }
        if hasToken { return theme.warning }
        return theme.textTertiary
    }

    private var statusLabel: String {
        if isActive { return "Connected" }
        if hasToken { return "Saved" }
        return "Not signed in"
    }

    private var actionTitle: String {
        if isActive { return "Active" }
        if hasToken { return "Switch" }
        return "Connect"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Entire top section is a button — tapping it switches to / enters the server
            Button(action: onSwitch) {
                HStack(spacing: Spacing.md) {
                    // Status indicator
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .padding(.top, 2)
                        .accessibilityLabel(statusLabel)

                    // Server info
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(server.name)
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        Text(server.url)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let userName = server.lastUserName, !userName.isEmpty {
                            HStack(spacing: Spacing.xxs) {
                                Image(systemName: "person.circle")
                                    .scaledFont(size: 11)
                                Text(userName)
                                    .scaledFont(size: 12)
                            }
                            .foregroundStyle(theme.textSecondary)
                        } else {
                            Text(statusLabel)
                                .scaledFont(size: 12)
                                .foregroundStyle(statusColor)
                        }
                    }

                    Spacer(minLength: 0)

                    // Right side: active badge or switch pill, plus delete
                    HStack(spacing: Spacing.sm) {
                        if isSwitching {
                            ProgressView()
                                .controlSize(.small)
                                .tint(theme.buttonPrimaryText)
                                .frame(width: 60)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                        } else {
                            Text(actionTitle)
                                .scaledFont(size: 13, weight: .medium)
                                .frame(minWidth: 60)
                                .foregroundStyle(isActive ? theme.success : theme.buttonPrimaryText)
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, Spacing.sm)
                                .background(
                                    Capsule()
                                        .fill(isActive
                                              ? theme.success.opacity(0.15)
                                              : theme.buttonPrimary)
                                )
                        }

                        // Delete button — stops tap propagation to the row button
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)
                                .padding(Spacing.sm)
                        }
                        .accessibilityLabel("Remove \(server.name)")
                    }
                }
                .padding(Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSwitching)
            .accessibilityLabel("\(actionTitle) \(server.name)")

            // "Sign in as different user" — shown when there's a saved account on this server
            if hasToken || isActive {
                Divider()
                    .padding(.horizontal, Spacing.md)

                Button(action: onSignInDifferentUser) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "person.badge.arrow.left")
                            .scaledFont(size: 12)
                        Text("Sign in as different user")
                            .scaledFont(size: 12, weight: .medium)
                    }
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                }
                .accessibilityLabel("Sign in to \(server.name) as a different user")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                .fill(isActive ? theme.brandPrimary.opacity(0.06) : theme.surfaceContainer)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous)
                        .strokeBorder(
                            isActive ? theme.brandPrimary.opacity(0.3) : theme.cardBorder,
                            lineWidth: isActive ? 1.5 : 0.5
                        )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg, style: .continuous))
    }
}

// MARK: - Compact Saved Servers (embedded in ServerConnectionView)

/// A compact list of saved servers shown beneath the URL field in
/// `ServerConnectionView`. Tapping a row immediately switches to that server.
struct CompactSavedServersSection: View {
    @Bindable var viewModel: AuthViewModel

    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @State private var switchingServerId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Saved Servers")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, Spacing.xs)

            VStack(spacing: Spacing.sm) {
                ForEach(viewModel.savedServers) { server in
                    compactServerRow(server)
                }
            }
        }
    }

    @ViewBuilder
    private func compactServerRow(_ server: ServerConfig) -> some View {
        let isActive = dependencies.serverConfigStore.activeServer?.id == server.id
        let isSwitching = switchingServerId == server.id

        Button {
            guard !isSwitching else { return }
            switchingServerId = server.id
            Task {
                await viewModel.switchToServer(server)
                switchingServerId = nil
            }
        } label: {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(isActive ? theme.success : (KeychainService.shared.hasToken(forServer: server.url) ? theme.warning : theme.textTertiary))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .scaledFont(size: 14, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if let userName = server.lastUserName, !userName.isEmpty {
                        Text(userName)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text(server.url)
                            .scaledFont(size: 12)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if isSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 16)
                        .foregroundStyle(theme.success)
                } else {
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .fill(theme.surfaceContainer)
            )
        }
        // Only disable when actively switching — always allow tapping, even the
        // "active" server (user may be signed out and want to go to login screen).
        .disabled(isSwitching)
    }
}
