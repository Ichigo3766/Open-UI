import SwiftUI

// MARK: - Auth Header

/// Reusable animated header for auth screens.
private struct AuthScreenHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    @State private var appeared = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .fill(theme.brandPrimary.opacity(0.1))
                    .frame(width: 80, height: 80)
                    .scaleEffect(appeared ? 1.0 : 0.6)

                Image(systemName: icon)
                    .scaledFont(size: 32, weight: .medium)
                    .foregroundStyle(theme.brandPrimary)
                    .scaleEffect(appeared ? 1.0 : 0.5)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1), value: appeared)

            Text(title)
                .scaledFont(size: 28, weight: .bold, design: .rounded)
                .foregroundStyle(theme.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.2), value: appeared)

            Text(subtitle)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.3), value: appeared)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Error Banner

/// Animated error message banner.
private struct AuthErrorBanner: View {
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.error)
                .scaledFont(size: 14)
            Text(message)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(theme.errorBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
        .transition(.asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

// MARK: - Credential Login View

/// Credential login view supporting email/password authentication — modernized.
struct LoginView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var formAppeared = false
    @State private var shakeCount = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Spacing.xl) {
                Spacer(minLength: Spacing.lg)

                AuthScreenHeader(
                    icon: "person.badge.key",
                    title: "Welcome Back",
                    subtitle: "Sign in to continue"
                )

                // Form card
                VStack(spacing: Spacing.lg) {
                    ModernTextField(
                        label: "Email",
                        placeholder: "you@example.com",
                        text: $viewModel.email,
                        keyboardType: .emailAddress,
                        textContentType: .emailAddress
                    )

                    ModernTextField(
                        label: "Password",
                        placeholder: "Enter your password",
                        text: $viewModel.password,
                        isSecure: true,
                        textContentType: .password,
                        onSubmit: {
                            if !viewModel.email.isEmpty && !viewModel.password.isEmpty {
                                Task { await viewModel.login() }
                            }
                        }
                    )

                    // Error message
                    if let error = viewModel.errorMessage {
                        AuthErrorBanner(message: error)
                            .shakeOnError(trigger: shakeCount)
                    }

                    // Sign in button
                    AuthPrimaryButton(
                        title: "Sign In",
                        icon: viewModel.isLoggingIn ? nil : "arrow.right",
                        isLoading: viewModel.isLoggingIn,
                        isDisabled: viewModel.email.isEmpty || viewModel.password.isEmpty
                    ) {
                        Task {
                            await viewModel.login()
                            if viewModel.errorMessage != nil {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                                    shakeCount += 1
                                }
                            }
                        }
                    }

                    // Sign up link (when enabled)
                    if viewModel.isSignupEnabled {
                        HStack(spacing: Spacing.xs) {
                            Text("Don't have an account?")
                                .scaledFont(size: 14)
                                .foregroundStyle(theme.textTertiary)

                            Button {
                                withAnimation(MicroAnimation.gentle) {
                                    viewModel.goToPhase(.signUp)
                                }
                            } label: {
                                Text("Create one")
                                    .scaledFont(size: 14, weight: .medium)
                                    .foregroundStyle(theme.brandPrimary)
                            }
                        }
                        .padding(.top, Spacing.xs)
                    }
                }
                .padding(Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
                )
                .padding(.horizontal, Spacing.screenPadding)
                .opacity(formAppeared ? 1 : 0)
                .offset(y: formAppeared ? 0 : 20)

                Spacer(minLength: Spacing.xl)
            }
        }
        .background(theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.goBack()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Back")
                            .scaledFont(size: 14)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2)) {
                formAppeared = true
            }
        }
    }
}

// MARK: - LDAP Login View

/// LDAP login view using username-based authentication — modernized.
struct LDAPLoginView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var formAppeared = false
    @State private var shakeCount = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Spacing.xl) {
                Spacer(minLength: Spacing.lg)

                AuthScreenHeader(
                    icon: "network.badge.shield.half.filled",
                    title: "LDAP Sign In",
                    subtitle: "Authenticate with your directory credentials"
                )

                // Form card
                VStack(spacing: Spacing.lg) {
                    ModernTextField(
                        label: "Username",
                        placeholder: "Enter your LDAP username",
                        text: $viewModel.ldapUsername,
                        textContentType: .username
                    )

                    ModernTextField(
                        label: "Password",
                        placeholder: "Enter your LDAP password",
                        text: $viewModel.ldapPassword,
                        isSecure: true,
                        textContentType: .password,
                        onSubmit: {
                            if !viewModel.ldapUsername.isEmpty && !viewModel.ldapPassword.isEmpty {
                                Task { await viewModel.ldapLogin() }
                            }
                        }
                    )

                    // Error message
                    if let error = viewModel.errorMessage {
                        AuthErrorBanner(message: error)
                            .shakeOnError(trigger: shakeCount)
                    }

                    // Sign in button
                    AuthPrimaryButton(
                        title: "Sign In with LDAP",
                        icon: viewModel.isLoggingIn ? nil : "arrow.right",
                        isLoading: viewModel.isLoggingIn,
                        isDisabled: viewModel.ldapUsername.isEmpty || viewModel.ldapPassword.isEmpty
                    ) {
                        Task {
                            await viewModel.ldapLogin()
                            if viewModel.errorMessage != nil {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                                    shakeCount += 1
                                }
                            }
                        }
                    }
                }
                .padding(Spacing.lg)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
                )
                .padding(.horizontal, Spacing.screenPadding)
                .opacity(formAppeared ? 1 : 0)
                .offset(y: formAppeared ? 0 : 20)

                Spacer(minLength: Spacing.xl)
            }
        }
        .background(theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.goBack()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "chevron.left")
                            .scaledFont(size: 14, weight: .semibold)
                        Text("Back")
                            .scaledFont(size: 14)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2)) {
                formAppeared = true
            }
        }
    }
}

// MARK: - Auth Method Selection View

/// Auth method selection view that shows available login options — modernized.
struct AuthMethodSelectionView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var appeared = false

    /// OAuth providers detected from the server configuration.
    private var enabledOAuthProviders: [String] {
        viewModel.oauthProviders?.enabledProviders ?? []
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: Spacing.xl) {
                Spacer(minLength: Spacing.lg)

                // Server info header with animated check
                VStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(theme.success.opacity(0.12))
                            .frame(width: 80, height: 80)
                            .scaleEffect(appeared ? 1 : 0.5)

                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 36)
                            .foregroundStyle(theme.success)
                            .scaleEffect(appeared ? 1 : 0)
                    }
                    .animation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1), value: appeared)

                    Text(viewModel.serverName)
                        .scaledFont(size: 28, weight: .bold, design: .rounded)
                        .foregroundStyle(theme.textPrimary)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.2), value: appeared)

                    if let version = viewModel.serverVersion {
                        Text("Version \(version)")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .background(theme.surfaceContainer)
                            .clipShape(Capsule())
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.25), value: appeared)
                    }

                    Text("Choose how you'd like to sign in")
                        .scaledFont(size: 14)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.top, Spacing.xs)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.3), value: appeared)
                }

                // Auth methods
                VStack(spacing: Spacing.md) {
                    // OAuth provider buttons
                    if !enabledOAuthProviders.isEmpty {
                        VStack(spacing: Spacing.sm) {
                            ForEach(Array(enabledOAuthProviders.enumerated()), id: \.element) { index, provider in
                                oauthProviderButton(provider: provider)
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 15)
                                    .animation(
                                        .spring(response: 0.4, dampingFraction: 0.8).delay(0.35 + Double(index) * 0.06),
                                        value: appeared
                                    )
                            }
                        }

                        // Divider
                        if viewModel.isLoginEnabled || viewModel.isLDAPEnabled {
                            dividerWithText("or")
                                .opacity(appeared ? 1 : 0)
                                .animation(.easeOut(duration: 0.3).delay(0.5), value: appeared)
                        }
                    }

                    // Other auth method buttons
                    if viewModel.isLoginEnabled {
                        authMethodButton(
                            icon: "envelope.fill",
                            title: "Email & Password",
                            subtitle: "Sign in with your account credentials",
                            index: enabledOAuthProviders.count
                        ) {
                            viewModel.goToPhase(.credentialLogin)
                        }
                    }

                    if viewModel.isLDAPEnabled {
                        authMethodButton(
                            icon: "network.badge.shield.half.filled",
                            title: "LDAP",
                            subtitle: "Sign in with your directory account",
                            index: enabledOAuthProviders.count + 1
                        ) {
                            viewModel.goToPhase(.ldapLogin)
                        }
                    }

                    if viewModel.isTrustedHeaderAuth && enabledOAuthProviders.isEmpty {
                        authMethodButton(
                            icon: "globe",
                            title: "Single Sign-On (SSO)",
                            subtitle: "Use your organization's identity provider",
                            index: enabledOAuthProviders.count + 2
                        ) {
                            viewModel.goToPhase(.ssoLogin)
                        }
                    }

                    // Sign up option
                    if viewModel.isSignupEnabled {
                        VStack(spacing: Spacing.sm) {
                            dividerWithText("new here?")
                                .opacity(appeared ? 1 : 0)
                                .animation(.easeOut(duration: 0.3).delay(0.7), value: appeared)

                            authMethodButton(
                                icon: "person.badge.plus",
                                title: "Create Account",
                                subtitle: "Sign up for a new account",
                                index: enabledOAuthProviders.count + 3
                            ) {
                                viewModel.goToPhase(.signUp)
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenPadding)

                Spacer(minLength: Spacing.xl)

                // Manage servers — switches context without destroying saved data
                VStack(spacing: Spacing.sm) {
                    if !viewModel.savedServers.isEmpty {
                        Button {
                            withAnimation {
                                viewModel.phase = .serverSwitcher
                            }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.left.arrow.right.circle")
                                    .scaledFont(size: 14)
                                Text(viewModel.savedServers.count > 1
                                     ? "Switch server (\(viewModel.savedServers.count) saved)"
                                     : "Add or switch server")
                                    .scaledFont(size: 14)
                            }
                            .foregroundStyle(theme.brandPrimary.opacity(0.8))
                        }
                    } else {
                        Button {
                            withAnimation {
                                viewModel.phase = .serverConnection
                            }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "arrow.left.circle")
                                    .scaledFont(size: 14)
                                Text("Connect to a different server")
                                    .scaledFont(size: 14)
                            }
                            .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                .opacity(appeared ? 0.9 : 0)
                .animation(.easeOut(duration: 0.3).delay(0.8), value: appeared)
                .padding(.bottom, Spacing.lg)
            }
        }
        .background(theme.background)
        .onAppear { appeared = true }
    }

    // MARK: - OAuth Provider Button

    private func oauthProviderButton(provider: String) -> some View {
        let displayName = viewModel.oauthProviders?.displayName(for: provider)
            ?? provider.capitalized
        let iconName = OAuthProviders.iconName(for: provider)

        return Button {
            viewModel.selectedSSOProvider = provider
            viewModel.goToPhase(.ssoLogin)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: iconName)
                    .scaledFont(size: 18, weight: .semibold)
                    .foregroundStyle(theme.buttonPrimaryText)
                    .frame(width: 24, height: 24)

                Text("Continue with \(displayName)")
                    .scaledFont(size: 16, weight: .medium)
                    .foregroundStyle(theme.buttonPrimaryText)

                Spacer()

                Image(systemName: "arrow.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.buttonPrimaryText.opacity(0.7))
            }
            .padding(.horizontal, Spacing.md)
            .frame(maxWidth: .infinity)
            .frame(height: TouchTarget.large)
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.button + 4, style: .continuous)
                .fill(theme.buttonPrimary)
                .shadow(color: theme.buttonPrimary.opacity(0.2), radius: 8, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button + 4, style: .continuous))
        .buttonStyle(.plain)
        .pressEffect()
    }

    // MARK: - Divider with Text

    private func dividerWithText(_ text: String) -> some View {
        HStack {
            Rectangle()
                .fill(theme.divider)
                .frame(height: 0.5)
            Text(text)
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, Spacing.sm)
            Rectangle()
                .fill(theme.divider)
                .frame(height: 0.5)
        }
    }

    // MARK: - Auth Method Button

    private func authMethodButton(
        icon: String,
        title: String,
        subtitle: String,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                        .fill(theme.brandPrimary.opacity(0.1))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .scaledFont(size: 18, weight: .medium)
                        .foregroundStyle(theme.brandPrimary)
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textPrimary)

                    Text(subtitle)
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pressEffect()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 15)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.8).delay(0.4 + Double(index) * 0.06),
            value: appeared
        )
    }
}
