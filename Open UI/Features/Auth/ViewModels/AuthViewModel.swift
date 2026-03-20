import Foundation
import WebKit
import os.log

/// The current phase of the authentication flow.
enum AuthPhase: Equatable {
    /// No server connected yet.
    case serverConnection
    /// Restoring a previously saved session (shows loading indicator).
    case restoringSession
    /// Server connected; user must choose an auth method.
    case authMethodSelection
    /// Credentials (email/password) login form.
    case credentialLogin
    /// New account sign-up form.
    case signUp
    /// Account created but pending admin approval.
    case pendingApproval
    /// LDAP login form.
    case ldapLogin
    /// SSO (OAuth/OIDC) WebView flow.
    case ssoLogin
    /// Authenticated; ready to use.
    case authenticated
    /// Shows the list of saved server profiles for quick switching.
    case serverSwitcher
}

/// Describes the type of authentication used.
enum AuthType: String, Codable, Sendable {
    case credentials
    case ldap
    case sso
    case apiKey
}

/// Manages authentication state and the full server-connection → login flow.
@Observable
final class AuthViewModel {
    // MARK: - Published State

    var serverURL: String = ""
    var apiKey: String = ""
    /// User-supplied custom HTTP headers (key–value pairs) entered during server setup.
    var customHeaderEntries: [CustomHeaderEntry] = []
    var email: String = ""
    var password: String = ""
    var ldapUsername: String = ""
    var ldapPassword: String = ""
    var isConnecting: Bool = false
    var isLoggingIn: Bool = false
    var errorMessage: String?
    var currentUser: User?
    var phase: AuthPhase = .serverConnection
    var allowSelfSignedCerts: Bool = false
    var hasShownOnboarding: Bool = false

    /// Set to true to present the Cloudflare Browser Integrity Check WebView sheet.
    var showCloudflareChallenge: Bool = false
    /// The normalized URL pending connection after a Cloudflare challenge is solved.
    private var pendingCloudflareURL: String?
    /// Set to true to present the auth proxy WebView sheet (Authelia, Authentik, etc.).
    var showProxyAuthChallenge: Bool = false
    /// The normalized URL pending connection after a proxy auth challenge is solved.
    private var pendingProxyAuthURL: String?
    /// The OAuth provider key selected by the user (e.g. "google", "microsoft").
    /// Set before navigating to `.ssoLogin` so SSOAuthView can load the provider URL directly.
    var selectedSSOProvider: String?

    // MARK: - Sign Up State

    var signUpName: String = ""
    var signUpEmail: String = ""
    var signUpPassword: String = ""
    var signUpConfirmPassword: String = ""
    var isSigningUp: Bool = false

    /// Backend config fetched after server verification.
    var backendConfig: BackendConfig?

    // MARK: - Computed

    var isAuthenticated: Bool { currentUser != nil }

    var isLDAPEnabled: Bool {
        backendConfig?.features?.enableLdap == true
    }

    var isSignupEnabled: Bool {
        backendConfig?.features?.enableSignup == true
    }

    var isLoginEnabled: Bool {
        backendConfig?.isLoginFormEnabled ?? true
    }

    var isTrustedHeaderAuth: Bool {
        backendConfig?.features?.authTrustedHeaderAuth == true
    }

    var serverName: String {
        backendConfig?.name ?? "Open WebUI"
    }

    var serverVersion: String? {
        backendConfig?.version
    }

    /// OAuth providers available on the server.
    var oauthProviders: OAuthProviders? {
        backendConfig?.oauthProviders
    }

    /// Whether there is at least one SSO option available.
    /// Trusted-header or OAuth providers surface as SSO.
    var hasSSOOption: Bool {
        isTrustedHeaderAuth || (backendConfig?.hasSsoEnabled == true)
    }

    // MARK: - Sign Up Validation

    /// Whether the sign-up name is valid (non-empty).
    var isSignUpNameValid: Bool {
        !signUpName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the sign-up email looks valid.
    var isSignUpEmailValid: Bool {
        let trimmed = signUpEmail.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether the sign-up password meets minimum requirements.
    var isSignUpPasswordValid: Bool {
        signUpPassword.count >= 8
    }

    /// Whether the passwords match.
    var doPasswordsMatch: Bool {
        !signUpConfirmPassword.isEmpty && signUpPassword == signUpConfirmPassword
    }

    /// Password has at least one uppercase letter.
    var passwordHasUppercase: Bool {
        signUpPassword.range(of: "[A-Z]", options: .regularExpression) != nil
    }

    /// Password has at least one lowercase letter.
    var passwordHasLowercase: Bool {
        signUpPassword.range(of: "[a-z]", options: .regularExpression) != nil
    }

    /// Password has at least one number.
    var passwordHasNumber: Bool {
        signUpPassword.range(of: "[0-9]", options: .regularExpression) != nil
    }

    /// Password strength (0.0 – 1.0).
    var passwordStrength: Double {
        guard !signUpPassword.isEmpty else { return 0 }
        var strength = 0.0
        if signUpPassword.count >= 8 { strength += 0.25 }
        if passwordHasUppercase { strength += 0.25 }
        if passwordHasLowercase { strength += 0.25 }
        if passwordHasNumber { strength += 0.25 }
        return strength
    }

    /// Whether the entire sign-up form is valid.
    var isSignUpFormValid: Bool {
        isSignUpNameValid && isSignUpEmailValid && isSignUpPasswordValid && doPasswordsMatch
    }

    // MARK: - Private

    private let serverConfigStore: ServerConfigStore
    /// Weak reference to the app's dependency container.
    /// Set after init by `AppDependencyContainer` since `self` is not
    /// yet available during the container's own initializer.
    weak var dependencies: AppDependencyContainer?
    private let logger = Logger(subsystem: "com.openui", category: "Auth")
    private var tokenRefreshTask: Task<Void, Never>?

    private static let onboardingKey = "openui.has_shown_onboarding"
    private static let cachedUserKey = "openui.cached_user"

    // MARK: - Init

    init(serverConfigStore: ServerConfigStore, dependencies: AppDependencyContainer? = nil) {
        self.serverConfigStore = serverConfigStore
        self.dependencies = dependencies
        self.hasShownOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)

        // Optimistic auth: if we have a saved server, token, AND cached user,
        // skip the "Connecting…" spinner entirely and go straight to the chat.
        // The session will be validated in the background.
        if let active = serverConfigStore.activeServer {
            serverURL = active.url
            if KeychainService.shared.hasToken(forServer: active.url),
               let cachedUser = Self.loadCachedUser(forServer: active.url) {
                // Instant launch — user sees chat immediately
                currentUser = cachedUser
                phase = .authenticated
                logger.info("⚡ Optimistic auth: restored cached user '\(cachedUser.displayName)', skipping spinner")
            } else if KeychainService.shared.hasToken(forServer: active.url) {
                // Have token but no cached user — must validate (first launch after update)
                phase = .restoringSession
            } else {
                // Server saved but no token (signed out). Decision:
                // - If only ONE server is saved → go straight to its login screen (best UX for single-server users).
                // - If MULTIPLE servers are saved → show the server list so the user
                //   can choose which server to sign into, rather than auto-picking one.
                if serverConfigStore.servers.count > 1 {
                    phase = .serverSwitcher
                } else {
                    phase = .authMethodSelection
                }
            }
        }
    }

    // MARK: - Server Connection

    /// Attempts to connect to the specified server URL, verifies it is OpenWebUI,
    /// and transitions to the auth method selection phase.
    func connect() async {
        let trimmed = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            errorMessage = "Please enter a valid server URL."
            return
        }

        isConnecting = true
        errorMessage = nil
        logger.info("🔌 [connect] Starting connection to: \(trimmed)")

        // Normalise URL
        var normalizedURL = trimmed
        if normalizedURL.hasSuffix("/") {
            normalizedURL = String(normalizedURL.dropLast())
        }

        // Ensure scheme — only allow http/https for security (reject file://, javascript://, etc.)
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://\(normalizedURL)"
        }

        guard let url = URL(string: normalizedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            errorMessage = "Invalid URL format. Please enter a valid HTTP or HTTPS server address."
            isConnecting = false
            return
        }

        // Build the user-supplied custom headers dict (skip blank entries)
        let userCustomHeaders: [String: String] = Dictionary(
            customHeaderEntries
                .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) },
            uniquingKeysWith: { _, last in last }
        )

        let config = ServerConfig(
            name: url.host ?? "Server",
            url: normalizedURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            customHeaders: userCustomHeaders,
            lastConnected: .now,
            isActive: true,
            allowSelfSignedCertificates: allowSelfSignedCerts
        )

        let client = APIClient(serverConfig: config)

        // If an API key is provided, treat it as the auth token
        if !apiKey.isEmpty {
            client.updateAuthToken(apiKey)
        }

        // Health check with proxy detection — also detects HTTP→HTTPS redirects from
        // a load balancer so we can update the stored URL to the correct HTTPS address.
        let healthCheck = await client.checkHealthWithProxyDetectionAndFinalURL()

        // If the load balancer redirected HTTP→HTTPS, update normalizedURL so all
        // subsequent requests (login, SSO, /api/config) go to the HTTPS address.
        // We also need a fresh client and config pointing at the HTTPS URL.
        var activeConfig = config
        var activeClient = client
        if let redirectedURL = healthCheck.finalURL {
            logger.info("🔀 [connect] HTTP→HTTPS redirect detected: \(normalizedURL) → \(redirectedURL)")
            normalizedURL = redirectedURL
            serverURL = redirectedURL
            // Rebuild config + client with the corrected HTTPS URL
            activeConfig = ServerConfig(
                name: URL(string: redirectedURL)?.host ?? "Server",
                url: redirectedURL,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                customHeaders: userCustomHeaders,
                lastConnected: .now,
                isActive: true,
                allowSelfSignedCertificates: allowSelfSignedCerts
            )
            activeClient = APIClient(serverConfig: activeConfig)
            if !apiKey.isEmpty {
                activeClient.updateAuthToken(apiKey)
            }
        }

        switch healthCheck.result {
        case .healthy:
            break
        case .cloudflareChallenge:
            // The server is behind Cloudflare Bot Fight Mode.
            // We need a real browser to complete the JS/Turnstile challenge.
            // Show the WKWebView sheet so the user can pass the check.
            pendingCloudflareURL = normalizedURL
            isConnecting = false
            showCloudflareChallenge = true
            return
        case .proxyAuthRequired:
            // The server is behind an auth proxy (Authelia, Authentik, Keycloak, etc.).
            // Show a WKWebView so the user can authenticate through the proxy portal.
            // Once done, the proxy session cookies are captured and injected into URLSession.
            pendingProxyAuthURL = normalizedURL
            isConnecting = false
            showProxyAuthChallenge = true
            return
        case .unhealthy:
            errorMessage = "Server is reachable but not responding correctly."
            isConnecting = false
            return
        case .unreachable:
            errorMessage = "Could not connect to the server. Check the URL and your network."
            isConnecting = false
            return
        }

        // Verify it's an OpenWebUI server. This also probes /api/config, which
        // Cloudflare can independently challenge even if /health passed.
        // If it fails, do a second Cloudflare check before giving up.
        guard let config_result = await activeClient.verifyAndGetConfig() else {
            let cfCheck = await activeClient.checkHealthWithProxyDetection()
            if cfCheck == .cloudflareChallenge {
                pendingCloudflareURL = normalizedURL
                isConnecting = false
                showCloudflareChallenge = true
                return
            }
            errorMessage = "Server does not appear to be an OpenWebUI instance."
            isConnecting = false
            return
        }

        backendConfig = config_result
        logger.info("📋 [connect] backendConfig set — name='\(config_result.name ?? "nil")', version='\(config_result.version ?? "nil")', features_nil=\(config_result.features == nil), isSignupEnabled=\(self.isSignupEnabled), isLoginEnabled=\(self.isLoginEnabled), oauthProviders=\(config_result.oauthProviders?.enabledProviders.joined(separator: ",") ?? "none"), isValidOpenWebUI=\(config_result.isValidOpenWebUI)")
        // Upsert the new server. For multi-server scenarios the new server
        // must be made active explicitly — addServer() only auto-activates
        // the very first server in an empty list.
        serverConfigStore.addServer(activeConfig)
        if let saved = serverConfigStore.server(forURL: normalizedURL) {
            serverConfigStore.setActiveServer(id: saved.id)
        }
        dependencies?.refreshServices()

        // If API key was provided, try to authenticate immediately
        if !apiKey.isEmpty {
            do {
                currentUser = try await activeClient.getCurrentUser()
                cacheCurrentUser()
                phase = .authenticated
                startTokenRefreshTimer()
                markOnboardingSeen()
            } catch {
                // API key invalid; proceed to auth selection
                logger.warning("API key auth failed: \(error.localizedDescription)")
                phase = .authMethodSelection
            }
        } else {
            phase = .authMethodSelection
        }

        isConnecting = false
    }

    /// Disconnects from the current server and returns to server connection.
    func disconnect() {
        serverConfigStore.removeAllServers()
        dependencies?.refreshServices()
        backendConfig = nil
        currentUser = nil
        phase = .serverConnection
        serverURL = ""
        apiKey = ""
        stopTokenRefreshTimer()
    }

    // MARK: - Credential Login

    /// Logs in with email and password.
    func login() async {
        guard let client = dependencies?.apiClient else {
            errorMessage = "No server configured."
            return
        }

        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter your email and password."
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            let user = try await client.login(email: email, password: password)
            currentUser = user
            // Check if user is in pending state — needs admin approval
            if user.role == .pending {
                logger.info("Login: user is pending approval for \(self.email)")
                phase = .pendingApproval
                isLoggingIn = false
                return
            }
            // SECURITY FIX: Clear password from memory immediately after successful auth
            password = ""
            // Clear cached chat VMs so models are re-fetched for the new account
            dependencies?.activeChatStore.clear()
            connectSocketWithToken()
            cacheCurrentUser()
            backendConfig = try? await client.getBackendConfig()
            phase = .authenticated
            startTokenRefreshTimer()
            logger.info("Login successful for \(self.email)")
        } catch {
            let apiError = APIError.from(error)
            if case .httpError(let code, let msg, _) = apiError {
                if code == 401 {
                    errorMessage = "Invalid email or password."
                } else if code == 403 {
                    errorMessage = msg ?? "Account is not active. Contact your administrator."
                } else {
                    errorMessage = apiError.errorDescription
                }
            } else {
                errorMessage = apiError.errorDescription
            }
            logger.error("Login failed: \(error.localizedDescription)")
        }

        isLoggingIn = false
    }

    // MARK: - Sign Up

    /// Creates a new account with name, email, and password.
    func signUp() async {
        guard let client = dependencies?.apiClient else {
            errorMessage = "No server configured."
            return
        }

        guard isSignUpFormValid else {
            if !isSignUpNameValid {
                errorMessage = "Please enter your name."
            } else if !isSignUpEmailValid {
                errorMessage = "Please enter a valid email address."
            } else if !isSignUpPasswordValid {
                errorMessage = "Password must be at least 8 characters."
            } else if !doPasswordsMatch {
                errorMessage = "Passwords do not match."
            }
            return
        }

        isSigningUp = true
        errorMessage = nil

        do {
            let trimmedName = signUpName.trimmingCharacters(in: .whitespaces)
            let trimmedEmail = signUpEmail.trimmingCharacters(in: .whitespaces).lowercased()

            let user = try await client.signup(
                name: trimmedName,
                email: trimmedEmail,
                password: signUpPassword
            )
            currentUser = user
            // Check if user is pending admin approval
            if user.role == .pending {
                logger.info("Sign up: user is pending approval for \(trimmedEmail)")
                phase = .pendingApproval
                isSigningUp = false
                return
            }
            dependencies?.activeChatStore.clear()
            connectSocketWithToken()
            cacheCurrentUser()
            backendConfig = try? await client.getBackendConfig()
            phase = .authenticated
            startTokenRefreshTimer()
            // New users should always see onboarding
            hasShownOnboarding = false
            UserDefaults.standard.set(false, forKey: Self.onboardingKey)
            logger.info("Sign up successful for \(trimmedEmail)")
        } catch {
            let apiError = APIError.from(error)
            if case .httpError(let code, let msg, _) = apiError {
                if code == 400 {
                    errorMessage = msg ?? "This email is already registered."
                } else if code == 403 {
                    errorMessage = msg ?? "Sign up is not allowed. Contact your administrator."
                } else {
                    errorMessage = apiError.errorDescription
                }
            } else {
                errorMessage = apiError.errorDescription
            }
            logger.error("Sign up failed: \(error.localizedDescription)")
        }

        isSigningUp = false
    }

    // MARK: - LDAP Login

    /// Logs in via LDAP.
    func ldapLogin() async {
        guard let client = dependencies?.apiClient else {
            errorMessage = "No server configured."
            return
        }

        guard !ldapUsername.isEmpty, !ldapPassword.isEmpty else {
            errorMessage = "Please enter your LDAP username and password."
            return
        }

        isLoggingIn = true
        errorMessage = nil

        do {
            currentUser = try await client.ldapLogin(
                username: ldapUsername,
                password: ldapPassword
            )
            // SECURITY FIX: Clear LDAP password from memory immediately after successful auth
            ldapPassword = ""
            // Clear cached chat VMs so models are re-fetched for the new account
            dependencies?.activeChatStore.clear()
            connectSocketWithToken()
            cacheCurrentUser()
            backendConfig = try? await client.getBackendConfig()
            phase = .authenticated
            startTokenRefreshTimer()
            logger.info("LDAP login successful for \(self.ldapUsername)")
        } catch {
            let apiError = APIError.from(error)
            if case .httpError(let code, _, _) = apiError, code == 401 {
                errorMessage = "Invalid LDAP credentials."
            } else {
                errorMessage = apiError.errorDescription
            }
            logger.error("LDAP login failed: \(error.localizedDescription)")
        }

        isLoggingIn = false
    }

    // MARK: - SSO / Token Login

    /// Authenticates using a token captured from SSO WebView.
    func loginWithSSOToken(_ token: String) async {
        guard let client = dependencies?.apiClient else {
            errorMessage = "No server configured."
            return
        }

        isLoggingIn = true
        errorMessage = nil

        client.updateAuthToken(token)

        do {
            currentUser = try await client.getCurrentUser()
            // Clear cached chat VMs so models are re-fetched for the new account
            dependencies?.activeChatStore.clear()
            connectSocketWithToken()
            cacheCurrentUser()
            backendConfig = try? await client.getBackendConfig()
            phase = .authenticated
            startTokenRefreshTimer()
            logger.info("SSO login successful")
        } catch {
            client.updateAuthToken(nil)
            let apiError = APIError.from(error)
            errorMessage = "SSO authentication failed: \(apiError.errorDescription ?? "Unknown error")"
            logger.error("SSO login failed: \(error.localizedDescription)")
        }

        isLoggingIn = false
    }

    // MARK: - Session Restore

    /// Restores session from a stored token in the Keychain.
    ///
    /// Retries up to 3 times with exponential backoff for transient errors
    /// (network issues, 5xx server errors like 502 Bad Gateway). Only clears
    /// the token and kicks to login on genuine auth failures (401/403).
    func restoreSession() async {
        guard let client = dependencies?.apiClient,
              client.network.authToken != nil else {
            // No client or token available – fall back to the appropriate phase
            if serverConfigStore.activeServer != nil {
                // Always fetch backend config before showing auth methods
                await ensureBackendConfig()
                phase = .authMethodSelection
            } else {
                phase = .serverConnection
            }
            return
        }

        let maxRetries = 3
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                currentUser = try await client.getCurrentUser()
                backendConfig = try? await client.getBackendConfig()
                connectSocketWithToken()
                cacheCurrentUser()
                phase = .authenticated
                startTokenRefreshTimer()
                logger.info("Session restored for \(self.currentUser?.displayName ?? "unknown") (attempt \(attempt))")
                return
            } catch {
                lastError = error
                let apiError = APIError.from(error)

                // If the token is genuinely invalid (401/403), don't retry
                if apiError.requiresReauth {
                    logger.warning("Session restore: token invalid (401), clearing credentials")
                    client.updateAuthToken(nil)
                    currentUser = nil
                    if serverConfigStore.activeServer != nil {
                        // Fetch backend config so OAuth/signup options are available
                        await ensureBackendConfig()
                        phase = .authMethodSelection
                        errorMessage = "Your session has expired. Please sign in again."
                    } else {
                        phase = .serverConnection
                    }
                    return
                }

                // For transient errors (network, 5xx), retry with backoff
                if attempt < maxRetries {
                    let delay = TimeInterval(attempt) * 1.5 // 1.5s, 3s, 4.5s
                    logger.warning("Session restore failed (attempt \(attempt)/\(maxRetries)): \(apiError.localizedDescription), retrying in \(delay)s")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // All retries exhausted — but DON'T clear the token since it might
        // still be valid. The server was just unreachable.
        logger.warning("Session restore failed after \(maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown")")

        let apiError = lastError.map { APIError.from($0) }
        if apiError?.isRetryable == true || apiError?.requiresReauth == false {
            // Network/server error — show a recoverable "reconnecting" state
            // Keep the token, stay on the restoring screen with an error banner
            // so the user can manually retry without re-entering credentials
            errorMessage = "Unable to reach the server. Check your connection and try again."
            // Stay in restoringSession phase — the UI will show a retry button
        } else {
            // Unknown error — fall back to auth
            currentUser = nil
            if serverConfigStore.activeServer != nil {
                await ensureBackendConfig()
                phase = .authMethodSelection
            } else {
                phase = .serverConnection
            }
        }
    }

    /// Manually retries session restore. Called when the user taps "Retry"
    /// on the connection error screen.
    func retrySessionRestore() async {
        errorMessage = nil
        phase = .restoringSession
        await restoreSession()
    }

    // MARK: - Sign Out

    /// Signs out the current user and clears auth state.
    func signOut() async {
        stopTokenRefreshTimer()

        if let client = dependencies?.apiClient {
            try? await client.logout()
        }
        dependencies?.socketService?.disconnect()

        // Clear cached chat view models so stale model lists from the
        // previous account don't persist into the next session.
        dependencies?.activeChatStore.clear()

        // Clear the cached user so next launch doesn't optimistically
        // restore a signed-out user.
        clearCachedUser()

        // SECURITY FIX: Clear SSO/OAuth cookies so the next user can't
        // auto-authenticate with the previous user's SSO session.
        clearSSOCookies()
        
        // Clear cached profile images so the next user gets fresh avatars
        Task { await ImageCacheService.shared.evictProfileImages() }

        currentUser = nil
        email = ""
        password = ""
        ldapUsername = ""
        ldapPassword = ""
        signUpName = ""
        signUpEmail = ""
        signUpPassword = ""
        signUpConfirmPassword = ""
        errorMessage = nil

        // Return to auth method selection (server stays connected)
        if serverConfigStore.activeServer != nil {
            // Force-refresh backend config so sign-up/login/SSO options
            // reflect the latest server settings (e.g. admin disabled signup).
            backendConfig = nil
            await ensureBackendConfig()
            phase = .authMethodSelection
        } else {
            phase = .serverConnection
        }

        logger.info("User signed out")
    }

    /// Signs out and disconnects from the server entirely.
    func signOutAndDisconnect() async {
        await signOut()
        disconnect()
    }

    // MARK: - Token Refresh

    /// Starts a background timer that refreshes the auth token periodically.
    func startTokenRefreshTimer() {
        stopTokenRefreshTimer()
        tokenRefreshTask = Task { [weak self] in
            // Refresh every 45 minutes (JWT tokens typically expire in 1 hour)
            let interval: TimeInterval = 45 * 60
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refreshToken()
            }
        }
    }

    /// Stops the token refresh timer.
    func stopTokenRefreshTimer() {
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
    }

    /// Refreshes the authentication by re-fetching the current user.
    /// If the token is expired, triggers re-authentication.
    private func refreshToken() async {
        guard let client = dependencies?.apiClient else { return }

        do {
            currentUser = try await client.getCurrentUser()
            logger.debug("Token refresh: session still valid")
        } catch {
            let apiError = APIError.from(error)
            if apiError.requiresReauth {
                logger.warning("Token expired during refresh; user must re-authenticate")
                await MainActor.run {
                    self.currentUser = nil
                    self.phase = .authMethodSelection
                    self.errorMessage = "Your session has expired. Please sign in again."
                }
            }
        }
    }

    // MARK: - Navigation Helpers

    /// Navigates to a specific auth phase.
    func goToPhase(_ newPhase: AuthPhase) {
        errorMessage = nil
        phase = newPhase
    }

    /// Goes back from the current phase.
    func goBack() {
        errorMessage = nil
        switch phase {
        case .credentialLogin, .ldapLogin, .ssoLogin, .signUp:
            phase = .authMethodSelection
        case .authMethodSelection:
            // If we have a saved server, don't go back to a blank URL screen.
            // Only go to serverConnection if there truly is no server saved.
            if serverConfigStore.servers.isEmpty {
                phase = .serverConnection
            }
            // If servers are saved, stay on authMethodSelection — the user is on the
            // right server, they just need to pick a login method.
        default:
            break
        }
    }

    // MARK: - Onboarding

    /// Marks onboarding as seen.
    func markOnboardingSeen() {
        hasShownOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    /// Resets onboarding flag (for testing).
    func resetOnboarding() {
        hasShownOnboarding = false
        UserDefaults.standard.set(false, forKey: Self.onboardingKey)
    }

    // MARK: - Pending Approval

    /// Checks if the pending user has been approved by an admin.
    /// Uses /api/v1/users/user/status (authenticated) which returns the current user with role.
    /// If approved (role != pending), transitions to authenticated state.
    func checkApprovalStatus() async {
        guard let client = dependencies?.apiClient else { return }

        errorMessage = nil

        do {
            let user = try await client.getCurrentUser()
            currentUser = user
            logger.info("Approval check: role=\(user.role.rawValue) for \(user.email)")

            if user.role != .pending {
                // User has been approved — let them in!
                dependencies?.activeChatStore.clear()
                connectSocketWithToken()
                startTokenRefreshTimer()
                // New users should see onboarding
                hasShownOnboarding = false
                UserDefaults.standard.set(false, forKey: Self.onboardingKey)
                phase = .authenticated
                logger.info("Pending user approved: \(user.email), role=\(user.role.rawValue)")
            } else {
                // Still pending
                errorMessage = "Your account is still pending approval. Please try again later."
                logger.info("User still pending: \(user.email)")
            }
        } catch {
            let apiError = APIError.from(error)
            errorMessage = "Could not check approval status. \(String(describing: apiError.errorDescription))"
            logger.error("Approval status check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cloudflare Challenge Handling

    /// Called by `CloudflareChallengeView` when the `cf_clearance` cookie is obtained.
    /// Receives the cookie value, the WKWebView's User-Agent, and the cookie's expiry date.
    /// Cloudflare binds the clearance to the exact UA that solved the challenge, so we must
    /// send the same UA with every subsequent URLSession request or Cloudflare will re-challenge.
    func resumeAfterCloudflareClearance(_ clearanceValue: String, userAgent: String, expiry: Date?) {
        showCloudflareChallenge = false
        guard let urlString = pendingCloudflareURL else {
            errorMessage = "Could not resume connection after security check."
            pendingCloudflareURL = nil
            return
        }

        logger.info("☁️ Cloudflare cf_clearance obtained — injecting cookie + UA and resuming connection to \(urlString)")

        // Inject the cf_clearance cookie into URLSession's HTTPCookieStorage.
        // If the cookie has no expiry from Cloudflare, default to 30 minutes from now
        // so it persists across the session but isn't treated as a permanent cookie.
        let effectiveExpiry = expiry ?? Date().addingTimeInterval(30 * 60)
        Self.injectCFClearanceCookie(value: clearanceValue, urlString: urlString, expiry: effectiveExpiry)

        serverURL = urlString
        pendingCloudflareURL = nil

        // Skip the health check — we already know the server is reachable.
        Task { await connectSkippingHealthCheck(normalizedURL: urlString, cfClearance: clearanceValue, userAgent: userAgent, cfExpiry: effectiveExpiry) }
    }

    /// Injects (or refreshes) the `cf_clearance` cookie into `HTTPCookieStorage.shared`.
    /// Called both after a fresh challenge AND on app startup from persisted ServerConfig.
    static func injectCFClearanceCookie(value: String, urlString: String, expiry: Date) {
        guard let url = URL(string: urlString), let host = url.host else { return }
        let cookieProperties: [HTTPCookiePropertyKey: Any] = [
            .name: "cf_clearance",
            .value: value,
            .domain: host,
            .path: "/",
            .secure: url.scheme == "https" ? "TRUE" : "FALSE",
            .expires: expiry
        ]
        if let cookie = HTTPCookie(properties: cookieProperties) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Connects to a server directly, skipping the health check.
    /// Used after a successful Cloudflare challenge where we already know the server is up.
    private func connectSkippingHealthCheck(normalizedURL: String, cfClearance: String, userAgent: String, cfExpiry: Date) async {
        guard let url = URL(string: normalizedURL), url.host != nil else {
            errorMessage = "Invalid URL after security check."
            return
        }

        isConnecting = true
        errorMessage = nil

        // Inject the WKWebView User-Agent as a custom header.
        // Cloudflare ties cf_clearance to the UA that solved the challenge.
        var customHeaders: [String: String] = [:]
        if !userAgent.isEmpty {
            customHeaders["User-Agent"] = userAgent
        }

        // Persist all CF data in the ServerConfig so it survives app restarts.
        // On next launch, NetworkManager re-injects the cookie from these fields.
        let config = ServerConfig(
            name: url.host ?? "Server",
            url: normalizedURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            customHeaders: customHeaders,
            lastConnected: .now,
            isActive: true,
            allowSelfSignedCertificates: allowSelfSignedCerts,
            cfClearanceValue: cfClearance,
            cfClearanceExpiry: cfExpiry,
            cfUserAgent: userAgent.isEmpty ? nil : userAgent,
            isCloudflareBotProtected: true
        )

        let client = APIClient(serverConfig: config)

        if !apiKey.isEmpty {
            client.updateAuthToken(apiKey)
        }

        // Skip health check — go straight to verifying it's an OpenWebUI instance
        guard let configResult = await client.verifyAndGetConfig() else {
            errorMessage = "Server does not appear to be an OpenWebUI instance."
            isConnecting = false
            return
        }

        backendConfig = configResult
        logger.info("📋 [connectSkippingHealthCheck] Connected to '\(configResult.name ?? "unknown")' at \(normalizedURL)")

        // Upsert the CF-enabled config (preserves other saved servers).
        // addServer() deduplicates by URL so if this server was already saved
        // it gets updated with the CF headers; if new, it's appended.
        serverConfigStore.addServer(config)
        // Activate this server without destroying others
        if let saved = serverConfigStore.server(forURL: normalizedURL) {
            serverConfigStore.setActiveServer(id: saved.id)
        }
        dependencies?.refreshServices()

        if !apiKey.isEmpty {
            do {
                currentUser = try await client.getCurrentUser()
                cacheCurrentUser()
                phase = .authenticated
                startTokenRefreshTimer()
                markOnboardingSeen()
            } catch {
                logger.warning("API key auth failed after Cloudflare: \(error.localizedDescription)")
                phase = .authMethodSelection
            }
        } else {
            phase = .authMethodSelection
        }

        isConnecting = false
    }

    /// Triggers the Cloudflare challenge sheet for the currently active server.
    /// Used when a CF re-challenge is detected mid-session (cookie expired).
    func triggerCloudflareChallengeForActiveServer() {
        guard let active = serverConfigStore.activeServer else { return }
        pendingCloudflareURL = active.url
        serverURL = active.url
        showCloudflareChallenge = true
    }

    /// Called when the user dismisses the Cloudflare challenge without completing it.
    func dismissCloudflareChallenge() {
        showCloudflareChallenge = false
        pendingCloudflareURL = nil
        isConnecting = false
        errorMessage = "Security check cancelled. Please try again."
    }

    // MARK: - Auth Proxy Challenge Handling (Authelia, Authentik, Keycloak, etc.)

    /// Called by `ProxyAuthView` when the user has authenticated through the upstream
    /// proxy portal and we've captured the resulting session cookies.
    func resumeAfterProxyAuth(_ cookies: [String: String], userAgent: String) {
        showProxyAuthChallenge = false
        guard let urlString = pendingProxyAuthURL else {
            errorMessage = "Could not resume connection after proxy sign-in."
            pendingProxyAuthURL = nil
            return
        }

        logger.info("🔐 Proxy auth completed — injecting \(cookies.count) cookie(s) and resuming connection to \(urlString)")

        // Inject all captured cookies into HTTPCookieStorage.shared so URLSession
        // sends them automatically on every subsequent request.
        guard let url = URL(string: urlString), let host = url.host else {
            errorMessage = "Invalid server URL after proxy sign-in."
            pendingProxyAuthURL = nil
            return
        }
        for (name, value) in cookies {
            let cookieProperties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: "/",
                .secure: url.scheme == "https" ? "TRUE" : "FALSE"
            ]
            if let cookie = HTTPCookie(properties: cookieProperties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }

        serverURL = urlString
        pendingProxyAuthURL = nil

        Task { await connectSkippingProxyCheck(normalizedURL: urlString, proxyAuthCookies: cookies, userAgent: userAgent) }
    }

    /// Connects to a server directly, skipping the proxy health check.
    /// Used after a successful proxy auth challenge where the session cookies are already injected.
    private func connectSkippingProxyCheck(normalizedURL: String, proxyAuthCookies: [String: String], userAgent: String) async {
        guard let url = URL(string: normalizedURL), url.host != nil else {
            errorMessage = "Invalid URL after proxy sign-in."
            return
        }

        isConnecting = true
        errorMessage = nil

        // Persist the User-Agent as a custom header so the proxy session cookies
        // remain valid (some proxies bind sessions to the UA).
        var customHeaders: [String: String] = [:]
        if !userAgent.isEmpty {
            customHeaders["User-Agent"] = userAgent
        }

        // Persist all proxy auth data in ServerConfig so it survives app restarts.
        // On next launch, NetworkManager re-injects the cookies from these fields.
        let config = ServerConfig(
            name: url.host ?? "Server",
            url: normalizedURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            customHeaders: customHeaders,
            lastConnected: .now,
            isActive: true,
            allowSelfSignedCertificates: allowSelfSignedCerts,
            proxyAuthCookies: proxyAuthCookies,
            isAuthProxyProtected: true,
            proxyAuthPortalURL: normalizedURL
        )

        let client = APIClient(serverConfig: config)

        if !apiKey.isEmpty {
            client.updateAuthToken(apiKey)
        }

        // Skip health check — go straight to verifying it's an OpenWebUI instance
        guard let configResult = await client.verifyAndGetConfig() else {
            errorMessage = "Server does not appear to be an OpenWebUI instance."
            isConnecting = false
            return
        }

        backendConfig = configResult
        logger.info("📋 [connectSkippingProxyCheck] Connected to '\(configResult.name ?? "unknown")' at \(normalizedURL)")

        // Upsert the proxy-auth config (preserves other saved servers).
        serverConfigStore.addServer(config)
        if let saved = serverConfigStore.server(forURL: normalizedURL) {
            serverConfigStore.setActiveServer(id: saved.id)
        }
        dependencies?.refreshServices()

        if !apiKey.isEmpty {
            do {
                currentUser = try await client.getCurrentUser()
                cacheCurrentUser()
                phase = .authenticated
                startTokenRefreshTimer()
                markOnboardingSeen()
            } catch {
                logger.warning("API key auth failed after proxy sign-in: \(error.localizedDescription)")
                phase = .authMethodSelection
            }
        } else {
            phase = .authMethodSelection
        }

        isConnecting = false
    }

    /// Called when the user dismisses the proxy auth challenge without completing it.
    func dismissProxyAuthChallenge() {
        showProxyAuthChallenge = false
        pendingProxyAuthURL = nil
        isConnecting = false
        errorMessage = "Sign in cancelled. Please try again."
    }

    // MARK: - Private Helpers

    /// Public version of `ensureBackendConfig` — called by `RootView` on launch
    /// when the app starts in `.authMethodSelection` (signed-out state) so that
    /// login/SSO options are populated without requiring the user to tap anything.
    func fetchBackendConfigIfNeeded() async {
        await ensureBackendConfig()
    }

    /// Ensures `backendConfig` is populated by fetching it from the server.
    /// Called before transitioning to `authMethodSelection` so that OAuth providers,
    /// signup availability, etc. are all visible.
    private func ensureBackendConfig() async {
        guard backendConfig == nil else { return }
        guard let client = dependencies?.apiClient else { return }
        do {
            backendConfig = try await client.getBackendConfig()
        } catch {
            logger.warning("Failed to fetch backend config: \(error.localizedDescription)")
        }
    }

    private func connectSocketWithToken() {
        guard let client = dependencies?.apiClient,
              let token = client.network.authToken
        else { return }
        dependencies?.socketService?.updateAuthToken(token)
        dependencies?.socketService?.connect()

        // Send the user's timezone to the server (fire-and-forget).
        // The web client does this on every login so the server has correct
        // timezone context for date formatting and analytics.
        Task {
            await client.updateTimezone(TimeZone.current.identifier)
        }
    }

    // MARK: - User Cache (per-server, for optimistic auth)

    /// Persists the current user to Keychain scoped to the active server URL so the
    /// next launch can skip the "Connecting…" spinner and go straight to the chat screen.
    ///
    /// Key format: `cached_user_{normalizedServerURL}`
    ///
    /// **Security:** User data (email, role) is stored in the Keychain
    /// rather than plaintext UserDefaults to protect PII from unencrypted
    /// device backups.
    func cacheCurrentUser() {
        guard let user = currentUser else { return }
        let serverKey = serverConfigStore.activeServer?.url ?? Self.cachedUserKey
        do {
            let data = try JSONEncoder().encode(user)
            let dataString = data.base64EncodedString()
            KeychainService.shared.saveToken(dataString, forServer: "cached_user_\(serverKey)")
            // Also update server metadata in the store for the switcher UI
            serverConfigStore.updateActiveServerMetadata(
                userName: user.displayName,
                userEmail: user.email,
                profileImageURL: user.profileImageURL,
                authType: nil,
                hasActiveSession: true
            )
            logger.debug("Cached user '\(user.displayName)' for server '\(serverKey)'")
        } catch {
            logger.warning("Failed to cache user: \(error.localizedDescription)")
        }
    }

    /// Loads a previously cached user from Keychain for the given server URL.
    /// Falls back to the legacy global key for backwards compatibility on first update.
    static func loadCachedUser(forServer serverURL: String? = nil) -> User? {
        let key = serverURL ?? cachedUserKey
        // Try per-server key first
        if let dataString = KeychainService.shared.getToken(forServer: "cached_user_\(key)"),
           let data = Data(base64Encoded: dataString),
           let user = try? JSONDecoder().decode(User.self, from: data) {
            return user
        }
        // Legacy fallback: global key (migrates on first successful load)
        if let dataString = KeychainService.shared.getToken(forServer: "cached_user_\(cachedUserKey)"),
           let data = Data(base64Encoded: dataString) {
            return try? JSONDecoder().decode(User.self, from: data)
        }
        return nil
    }

    /// Clears SSO/OAuth cookies from WKWebsiteDataStore so the next sign-in
    /// doesn't auto-authenticate with the previous user's SSO session.
    /// SECURITY FIX: The SSO WebView uses `.default()` data store, so cookies
    /// persist across app launches unless explicitly cleared.
    private func clearSSOCookies() {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeLocalStorage
        ]
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                // Cookies cleared
            }
        }
        logger.debug("Cleared SSO cookies from WKWebsiteDataStore")
    }

    /// Removes the cached user (called on sign out).
    func clearCachedUser() {
        KeychainService.shared.deleteToken(forServer: "cached_user_\(Self.cachedUserKey)")
        // Also clean up legacy UserDefaults entry if present
        UserDefaults.standard.removeObject(forKey: Self.cachedUserKey)
        logger.debug("Cleared cached user")
    }

    // MARK: - Multi-Server Management

    /// Switches the active server to the given config, tears down existing services,
    /// and attempts to restore the saved session for the new server.
    ///
    /// Flow:
    /// 1. Save current user metadata to the outgoing server config.
    /// 2. Stop timers / disconnect socket for the old server.
    /// 3. Activate the new server in the store.
    /// 4. Rebuild all dependent services via `dependencies?.configureServicesForActiveServer`.
    /// 5. Attempt session restore from Keychain for the new server.
    func switchToServer(_ config: ServerConfig) async {
        logger.info("🔀 Switching to server: \(config.url)")

        // 1. Persist current user metadata before we tear down
        if let user = currentUser {
            serverConfigStore.updateActiveServerMetadata(
                userName: user.displayName,
                userEmail: user.email,
                profileImageURL: user.profileImageURL,
                authType: nil,
                hasActiveSession: false   // no longer the active session
            )
        }

        stopTokenRefreshTimer()
        dependencies?.socketService?.disconnect()
        dependencies?.activeChatStore.clear()

        // Clear SSO cookies so the next server's SSO can't inherit them
        clearSSOCookies()
        Task { await ImageCacheService.shared.evictProfileImages() }

        currentUser = nil
        backendConfig = nil
        email = ""
        password = ""
        ldapUsername = ""
        ldapPassword = ""
        errorMessage = nil

        // 2. Activate new server
        serverConfigStore.setActiveServer(id: config.id)
        serverURL = config.url

        // Reset navigation
        dependencies?.router?.resetAll()

        // 3. Rebuild all services for the new server
        dependencies?.configureServicesForActiveServer(isServerSwitch: true)

        // 4. Try to restore the saved session for this server
        let hasToken = KeychainService.shared.hasToken(forServer: config.url)

        if hasToken {
            // Check for a cached user for instant display while validating
            if let cachedUser = Self.loadCachedUser(forServer: config.url) {
                currentUser = cachedUser
                phase = .authenticated
                // Validate in background — same optimistic-auth pattern as app launch
                await validateSessionInBackground()
            } else {
                phase = .restoringSession
                await restoreSession()
            }
        } else {
            // No saved token — need to authenticate fresh
            await ensureBackendConfig()
            phase = .authMethodSelection
        }

        logger.info("🔀 Server switch complete — phase=\(String(describing: self.phase))")
    }

    /// Removes a saved server entirely (from the list, Keychain, and disk).
    ///
    /// If the removed server is currently active:
    /// - Switches to the next available server, or
    /// - Returns to the server connection screen if no others are saved.
    func removeServer(id: String) async {
        let isActive = serverConfigStore.activeServer?.id == id
        let remainingServers = serverConfigStore.servers.filter { $0.id != id }

        // If removing the active server, we need to switch away first
        if isActive {
            stopTokenRefreshTimer()
            dependencies?.socketService?.disconnect()
            dependencies?.activeChatStore.clear()
            clearSSOCookies()
            currentUser = nil
            backendConfig = nil
            errorMessage = nil
        }

        // Remove from store (also cleans up Keychain)
        serverConfigStore.removeServer(id: id)
        logger.info("🗑️ Removed server id=\(id)")

        guard isActive else { return }

        if let nextServer = remainingServers.first {
            // Switch to the next available server
            await switchToServer(nextServer)
        } else {
            // No more servers — go to the server connection screen
            dependencies?.refreshServices()
            serverURL = ""
            apiKey = ""
            phase = .serverConnection
        }
    }

    /// Accessible list of saved servers for the server switcher UI.
    var savedServers: [ServerConfig] {
        serverConfigStore.servers
    }

    // MARK: - Background Session Validation (for optimistic auth)

    /// Validates the current session in the background after an optimistic launch.
    /// If the token is genuinely invalid (401/403), kicks back to login.
    /// For transient errors (network, 5xx), silently retries — the user keeps
    /// using the app with the cached session.
    func validateSessionInBackground() async {
        guard let client = dependencies?.apiClient,
              client.network.authToken != nil else {
            return
        }

        // Connect socket immediately so chat works while we validate
        connectSocketWithToken()
        startTokenRefreshTimer()

        do {
            let freshUser = try await client.getCurrentUser()
            // Update with fresh data from server
            currentUser = freshUser
            cacheCurrentUser()
            backendConfig = try? await client.getBackendConfig()
            logger.info("✅ Background session validation succeeded for '\(freshUser.displayName)'")
        } catch {
            let apiError = APIError.from(error)

            if apiError.requiresReauth {
                // Token is truly dead — kick to login
                logger.warning("⚠️ Background validation: token invalid, signing out")
                client.updateAuthToken(nil)
                currentUser = nil
                clearCachedUser()
                if serverConfigStore.activeServer != nil {
                    await ensureBackendConfig()
                    phase = .authMethodSelection
                    errorMessage = "Your session has expired. Please sign in again."
                } else {
                    phase = .serverConnection
                }
            } else {
                // Transient error — keep the user in the app, they can still
                // browse cached data. Socket reconnect will handle recovery.
                logger.info("🔄 Background validation: transient error (\(apiError.localizedDescription)), keeping optimistic session")
            }
        }
    }
}
