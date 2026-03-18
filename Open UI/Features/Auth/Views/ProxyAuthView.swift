import SwiftUI
import WebKit
import os.log

// MARK: - Proxy Auth WebView

/// A WKWebView that loads the server URL and detects when the user has successfully
/// authenticated through an upstream auth proxy (Authelia, Authentik, Keycloak,
/// oauth2-proxy, Pangolin, etc.).
///
/// The view works by:
/// 1. Loading the server URL — the proxy will redirect to its login portal
/// 2. The user authenticates through whatever UI the proxy shows
/// 3. The proxy redirects back to the app's server URL
/// 4. We detect arrival back on the server domain and poll until `/health` returns JSON
/// 5. All session cookies are captured and passed back for injection into URLSession
struct ProxyAuthWebView: UIViewRepresentable {
    let serverURL: String
    /// Called with all captured cookies (name→value) and the webView's User-Agent
    /// once the proxy auth is detected as complete.
    let onSuccess: ([String: String], String) -> Void
    let onFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(serverURL: serverURL, onSuccess: onSuccess, onFailed: onFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use a fresh ephemeral store so stale proxy sessions don't cause silent
        // auto-login — we want the user to actually go through the proxy portal.
        // NOTE: We use default() so that any saved passwords / autofill works,
        // making the experience smooth for the user.
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Use a realistic Mobile Safari UA for maximum proxy compatibility
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        context.coordinator.webView = webView

        if let url = URL(string: serverURL) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        let serverURL: String
        let onSuccess: ([String: String], String) -> Void
        let onFailed: () -> Void
        weak var webView: WKWebView?

        private var pollTimer: Timer?
        private var timeoutTimer: Timer?
        private var didSucceed = false
        private var isCheckingHealth = false
        private let logger = Logger(subsystem: "com.openui", category: "ProxyAuth")

        init(
            serverURL: String,
            onSuccess: @escaping ([String: String], String) -> Void,
            onFailed: @escaping () -> Void
        ) {
            self.serverURL = serverURL
            self.onSuccess = onSuccess
            self.onFailed = onFailed
        }

        deinit {
            pollTimer?.invalidate()
            timeoutTimer?.invalidate()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didSucceed else { return }
            guard let currentURL = webView.url else { return }

            logger.debug("ProxyAuth: page finished loading: \(currentURL.absoluteString)")

            // Check if we've landed back on the server domain
            if isOnServerDomain(currentURL) {
                logger.info("ProxyAuth: back on server domain, checking if auth succeeded")
                startPollingForSuccess()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            logger.warning("ProxyAuth: navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Block further navigation once we've successfully authenticated
            if didSucceed {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: - Domain Check

        private func isOnServerDomain(_ url: URL) -> Bool {
            guard let serverHost = URL(string: serverURL)?.host?.lowercased(),
                  let currentHost = url.host?.lowercased() else { return false }
            // Match exact host or same base domain (e.g. sub.example.com vs example.com)
            return currentHost == serverHost || currentHost.hasSuffix(".\(serverHost)")
        }

        // MARK: - Polling

        /// Poll by probing the server's `/health` endpoint directly from the
        /// WKWebView via `fetch()`. If it returns JSON with `{"status": true}`,
        /// the proxy session is active and cookies are valid.
        private func startPollingForSuccess() {
            guard !didSucceed, !isCheckingHealth else { return }

            // Start timeout (3 minutes max)
            if timeoutTimer == nil || !(timeoutTimer?.isValid ?? false) {
                timeoutTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
                    guard let self, !self.didSucceed else { return }
                    self.pollTimer?.invalidate()
                    self.logger.warning("ProxyAuth: timed out after 3 minutes")
                    DispatchQueue.main.async { self.onFailed() }
                }
            }

            // Check immediately, then poll every second
            checkHealthViaFetch()
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkHealthViaFetch()
            }
        }

        /// Uses WKWebView's `fetch()` to check `/health` — this runs with the webview's
        /// cookies so it works even before we inject them into URLSession.
        private func checkHealthViaFetch() {
            guard !didSucceed, !isCheckingHealth, let webView else { return }
            isCheckingHealth = true

            let healthURL = serverURL.hasSuffix("/")
                ? "\(serverURL)health"
                : "\(serverURL)/health"

            let script = """
            (async function() {
                try {
                    const r = await fetch('\(healthURL)', {
                        credentials: 'include',
                        cache: 'no-store'
                    });
                    if (!r.ok) return JSON.stringify({ok: false, status: r.status});
                    const contentType = r.headers.get('content-type') || '';
                    if (!contentType.includes('application/json')) {
                        return JSON.stringify({ok: false, status: r.status, html: true});
                    }
                    const data = await r.json();
                    return JSON.stringify({ok: true, status: data.status});
                } catch(e) {
                    return JSON.stringify({ok: false, error: e.message});
                }
            })()
            """

            webView.evaluateJavaScript(script) { [weak self] result, error in
                guard let self else { return }
                self.isCheckingHealth = false

                guard error == nil, let resultString = result as? String,
                      let data = resultString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }

                let isOK = json["ok"] as? Bool ?? false
                let status = json["status"]
                let isValidStatus = (status as? Bool) == true || (status as? Int) == 1

                if isOK && isValidStatus {
                    self.captureSessionAndSucceed()
                }
            }
        }

        // MARK: - Cookie Capture

        private func captureSessionAndSucceed() {
            guard !didSucceed, let webView else { return }
            didSucceed = true
            pollTimer?.invalidate()
            timeoutTimer?.invalidate()

            logger.info("ProxyAuth: health check passed — capturing cookies")

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
                guard let self else { return }

                // Build name→value dictionary of ALL cookies
                var cookieDict: [String: String] = [:]
                for cookie in cookies {
                    cookieDict[cookie.name] = cookie.value
                }

                self.logger.info("ProxyAuth: captured \(cookieDict.count) cookies")

                // Get the WebView User-Agent
                webView?.evaluateJavaScript("navigator.userAgent") { [weak self] ua, _ in
                    let userAgent = (ua as? String) ?? ""
                    DispatchQueue.main.async {
                        self?.onSuccess(cookieDict, userAgent)
                    }
                }
            }
        }
    }
}

// MARK: - Proxy Auth Sheet View

/// Full-screen sheet shown when the server is behind an authentication proxy.
/// Presents a WKWebView so the user can log in through the proxy portal
/// (Authelia, Authentik, Keycloak, etc.), then captures the session cookies
/// and resumes the connection automatically.
struct ProxyAuthView: View {
    let serverURL: String
    /// Called with all captured cookies and the webView's User-Agent on success.
    let onSuccess: ([String: String], String) -> Void
    let onDismiss: () -> Void

    @State private var isWaiting = true
    @State private var didFail = false
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ProxyAuthWebView(
                    serverURL: serverURL,
                    onSuccess: { cookies, userAgent in
                        isWaiting = false
                        onSuccess(cookies, userAgent)
                    },
                    onFailed: {
                        isWaiting = false
                        didFail = true
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                if isWaiting {
                    VStack(spacing: Spacing.sm) {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .tint(theme.brandPrimary)
                            Text("Sign in to continue — your login is being detected automatically.")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                        .padding(.top, Spacing.sm)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
            .alert("Sign In Timed Out", isPresented: $didFail) {
                Button("Try Again") {
                    didFail = false
                    isWaiting = true
                }
                Button("Cancel", role: .cancel) {
                    onDismiss()
                }
            } message: {
                Text("The sign-in process took too long. Please try again.")
            }
        }
    }
}
