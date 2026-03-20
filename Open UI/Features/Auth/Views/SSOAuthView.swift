import SwiftUI
import WebKit
import os.log

/// SSO Authentication view using WKWebView to handle OAuth/OIDC flows.
///
/// When a specific OAuth provider is selected (e.g. "google"), this view loads
/// `/oauth/{provider}/login` directly — bypassing the OpenWebUI `/auth` page and
/// taking the user straight to the provider's login screen.
///
/// For generic trusted-header SSO (no specific provider), `/auth` is loaded instead.
///
/// The view uses the **default persistent** WKWebsiteDataStore so that iCloud
/// Keychain autofill and saved passwords work correctly.
struct SSOAuthView: View {
    @Bindable var viewModel: AuthViewModel
    @Environment(\.theme) private var theme
    @State private var ssoState = SSOWebViewState()

    /// The OAuth provider key to use (e.g. "google", "microsoft").
    /// If nil, falls back to loading the generic /auth page.
    private var provider: String? { viewModel.selectedSSOProvider }

    /// Human-readable name for the nav title.
    private var providerDisplayName: String {
        guard let provider else { return "SSO Sign In" }
        return viewModel.oauthProviders?.displayName(for: provider)
            ?? provider.capitalized
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = ssoState.error {
                errorStateView(error)
            } else {
                ZStack {
                    SSOWebViewRepresentable(
                        serverURL: viewModel.serverURL,
                        provider: provider,
                        state: $ssoState,
                        onTokenCaptured: { token in
                            Task { await viewModel.loginWithSSOToken(token) }
                        }
                    )

                    if ssoState.isLoading {
                        loadingOverlay
                    }
                }
            }
        }
        .navigationTitle("Sign in with \(providerDisplayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    viewModel.selectedSSOProvider = nil
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    ssoState.shouldReload = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            theme.background.opacity(0.85)

            VStack(spacing: Spacing.md) {
                ProgressView()
                    .scaleEffect(1.2)

                Text(ssoState.tokenCaptured ? "Authenticating..." : "Loading login page...")
                    .scaledFont(size: 14)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "exclamationmark.circle")
                .scaledFont(size: 48)
                .foregroundStyle(theme.error)

            Text("Sign In Failed")
                .scaledFont(size: 20, weight: .semibold)
                .foregroundStyle(theme.textPrimary)

            Text(error)
                .scaledFont(size: 14)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Spacing.sm) {
                Button {
                    ssoState.error = nil
                    ssoState.shouldReload = true
                } label: {
                    Text("Retry")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.buttonPrimaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: TouchTarget.comfortable)
                }
                .background(theme.buttonPrimary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button))

                Button {
                    viewModel.selectedSSOProvider = nil
                    viewModel.goBack()
                } label: {
                    Text("Back")
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: TouchTarget.comfortable)
                }
                .background(theme.buttonSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button))
            }
            .padding(.horizontal, Spacing.screenPadding)

            Spacer()
        }
        .padding(Spacing.screenPadding)
    }
}

// MARK: - SSO WebView State

/// Observable state for the SSO WebView flow.
@Observable
final class SSOWebViewState {
    var isLoading: Bool = true
    var tokenCaptured: Bool = false
    var error: String?
    var shouldReload: Bool = false
}

// MARK: - SSO WebView Representable

/// UIViewRepresentable wrapping WKWebView for SSO authentication.
///
/// Uses the default persistent data store so that:
/// - iCloud Keychain autofill works
/// - Saved passwords are suggested by the system
/// - Session cookies persist across reloads within this view
struct SSOWebViewRepresentable: UIViewRepresentable {
    let serverURL: String
    /// Optional OAuth provider key. When set, loads `/oauth/{provider}/login`
    /// directly instead of the generic `/auth` page.
    let provider: String?
    @Binding var state: SSOWebViewState
    let onTokenCaptured: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: $state,
            onTokenCaptured: onTokenCaptured,
            serverURL: serverURL,
            provider: provider
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use the default persistent data store — this is what enables
        // iCloud Keychain autofill and saved password suggestions.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Set a realistic mobile Safari user agent for maximum OAuth compatibility.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        context.coordinator.webView = webView
        context.coordinator.loadLoginPage()

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if state.shouldReload {
            state.shouldReload = false
            state.tokenCaptured = false
            state.error = nil
            state.isLoading = true
            context.coordinator.loadLoginPage()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var state: SSOWebViewState
        let onTokenCaptured: (String) -> Void
        let serverURL: String
        let provider: String?
        weak var webView: WKWebView?
        private let logger = Logger(subsystem: "com.openui", category: "SSO")
        private var captureAttemptId: Int = 0

        init(
            state: Binding<SSOWebViewState>,
            onTokenCaptured: @escaping (String) -> Void,
            serverURL: String,
            provider: String?
        ) {
            _state = state
            self.onTokenCaptured = onTokenCaptured
            self.serverURL = serverURL
            self.provider = provider
        }

        /// Builds the login URL.
        /// - If a specific provider is set, loads `/oauth/{provider}/login` directly,
        ///   skipping the OpenWebUI auth page entirely.
        /// - Falls back to `/auth` for generic trusted-header SSO.
        func loadLoginPage() {
            let path: String
            if let provider, !provider.isEmpty {
                path = "/oauth/\(provider)/login"
            } else {
                path = "/auth"
            }

            guard let url = URL(string: "\(serverURL)\(path)") else {
                state.error = "Invalid server URL"
                return
            }

            logger.info("Loading SSO login page: \(url.absoluteString)")
            webView?.load(URLRequest(url: url))
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            captureAttemptId += 1
            state.isLoading = true
            state.error = nil
            logger.debug("SSO page started: \(webView.url?.absoluteString ?? "unknown")")
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            state.isLoading = false
            logger.debug("SSO page finished: \(webView.url?.absoluteString ?? "unknown")")

            guard !state.tokenCaptured else { return }
            guard let currentURL = webView.url else { return }

            // Check for error parameters in the URL
            if let components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false),
               let error = components.queryItems?.first(where: { $0.name == "error" })?.value,
               !error.isEmpty {
                state.error = error
                return
            }

            // Only attempt token capture once we're back on our server's pages
            // (after the OAuth provider has redirected back)
            guard isOurServer(currentURL) else { return }

            let attemptId = captureAttemptId
            Task { @MainActor in
                await attemptTokenCaptureWithRetry(attemptId: attemptId)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }

            state.isLoading = false
            state.error = error.localizedDescription
            logger.error("SSO navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }

            state.isLoading = false
            state.error = error.localizedDescription
            logger.error("SSO provisional navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Allow all navigation — required for OAuth redirect chains
            decisionHandler(.allow)
        }

        // MARK: - Token Capture

        private func isOurServer(_ url: URL) -> Bool {
            guard let serverURL = URL(string: serverURL) else { return false }
            return url.host?.lowercased() == serverURL.host?.lowercased()
        }

        /// Attempts token capture with retries to handle timing issues.
        private func attemptTokenCaptureWithRetry(
            attemptId: Int,
            maxAttempts: Int = 3
        ) async {
            for attempt in 0..<maxAttempts {
                guard !state.tokenCaptured, attemptId == captureAttemptId else { return }

                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    guard !state.tokenCaptured, attemptId == captureAttemptId else { return }
                }

                if await attemptTokenCapture(attemptId: attemptId) {
                    return
                }
            }

            logger.debug("No token found after \(maxAttempts) attempts")
        }

        /// Attempts to capture the JWT token from cookies or localStorage.
        @discardableResult
        private func attemptTokenCapture(attemptId: Int) async -> Bool {
            guard let webView, !state.tokenCaptured else { return false }
            guard attemptId == captureAttemptId else { return false }

            // Strategy 1: Check token cookie via JavaScript
            if let token = await evaluateJS(
                webView: webView,
                script: """
                (function() {
                    var cookies = document.cookie.split(";");
                    for (var i = 0; i < cookies.length; i++) {
                        var cookie = cookies[i].trim();
                        if (cookie.startsWith("token=")) {
                            return cookie.substring(6);
                        }
                    }
                    return "";
                })()
                """
            ), isValidJWT(token) {
                logger.info("Found valid token in cookie")
                await handleToken(token)
                return true
            }

            guard attemptId == captureAttemptId else { return false }

            // Strategy 2: Check localStorage
            if let token = await evaluateJS(
                webView: webView,
                script: "localStorage.getItem('token') || ''"
            ), isValidJWT(token) {
                logger.info("Found valid token in localStorage")
                await handleToken(token)
                return true
            }

            return false
        }

        /// Evaluates JavaScript in the webview and returns the string result.
        private func evaluateJS(webView: WKWebView, script: String) async -> String? {
            return await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { result, error in
                    if error != nil {
                        continuation.resume(returning: nil)
                        return
                    }
                    if let str = result as? String {
                        continuation.resume(returning: str)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }

        /// Checks if a string looks like a valid JWT token (3 dot-separated segments).
        private func isValidJWT(_ value: String) -> Bool {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed != "null",
                  trimmed != "undefined",
                  trimmed != "false"
            else { return false }

            var cleaned = trimmed
            if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
                cleaned = String(cleaned.dropFirst().dropLast())
            }

            let segments = cleaned.split(separator: ".")
            return segments.count == 3 && cleaned.count >= 50
        }

        /// Reads the `token` cookie directly from WKHTTPCookieStore.
        /// This works for HttpOnly cookies that JavaScript cannot access via `document.cookie`.
        private func attemptNativeCookieCapture(attemptId: Int) async -> Bool {
            guard let webView, !state.tokenCaptured, attemptId == captureAttemptId else { return false }

            return await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    // Look for an OpenWebUI token cookie
                    let tokenCookie = cookies.first { cookie in
                        cookie.name == "token" &&
                        (cookie.domain.contains(self.serverURL.components(separatedBy: "://").last?.components(separatedBy: "/").first ?? "") ||
                         self.serverURL.contains(cookie.domain))
                    }
                    guard let cookie = tokenCookie,
                          !cookie.value.isEmpty,
                          self.isValidJWT(cookie.value) else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.logger.info("Found valid token in native WKHTTPCookieStore (HttpOnly cookie)")
                    Task { @MainActor in
                        await self.handleToken(cookie.value)
                    }
                    continuation.resume(returning: true)
                }
            }
        }

        /// Handles a captured SSO token.
        @MainActor
        private func handleToken(_ rawToken: String) async {
            guard !state.tokenCaptured else { return }

            var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("\"") && token.hasSuffix("\"") {
                token = String(token.dropFirst().dropLast())
            }

            state.tokenCaptured = true
            state.isLoading = true

            logger.info("Handling captured SSO token")
            onTokenCaptured(token)
        }
    }
}
