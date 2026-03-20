import Foundation

/// Configuration for connecting to an OpenWebUI server instance.
///
/// **Security:** The `apiKey` is intentionally excluded from `Codable`
/// serialisation so it is never persisted in plaintext UserDefaults.
/// Use ``KeychainService`` to store/retrieve API keys instead.
struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var url: String
    var customHeaders: [String: String]
    var lastConnected: Date?
    var isActive: Bool
    var allowSelfSignedCertificates: Bool

    // MARK: - Cloudflare Bot Fight Mode persistence

    /// The `cf_clearance` cookie value obtained from the WKWebView challenge.
    /// Persisted so the cookie can be re-injected into `HTTPCookieStorage.shared`
    /// on app restart (session cookies are not persisted by the system).
    var cfClearanceValue: String?

    /// Expiry date of the `cf_clearance` cookie (from Cloudflare, typically 15–30 min).
    /// If nil or expired, the challenge must be re-presented.
    var cfClearanceExpiry: Date?

    /// The WKWebView User-Agent that solved the Cloudflare challenge.
    /// Cloudflare ties `cf_clearance` to the exact UA — every URLSession request
    /// must send this UA or Cloudflare will re-challenge.
    var cfUserAgent: String?

    /// Whether this server is behind Cloudflare Bot Fight Mode.
    /// Used to skip health check on reconnect and to gate CF-specific behaviour.
    var isCloudflareBotProtected: Bool

    // MARK: - Auth Proxy persistence (Authelia, Authentik, Keycloak, etc.)

    /// Cookies captured from WKWebView after the user authenticated through
    /// an upstream auth proxy (Authelia, Authentik, Keycloak, oauth2-proxy, etc.).
    /// Persisted as JSON-encoded `[name: value]` dictionary so they can be
    /// re-injected into `HTTPCookieStorage.shared` on app restart.
    var proxyAuthCookies: [String: String]?

    /// Whether this server is known to be behind an auth proxy.
    /// Used to re-inject proxy cookies on reconnect and to gate proxy-specific behaviour.
    var isAuthProxyProtected: Bool

    /// The URL the proxy redirected to (auth portal URL) — used to re-scope cookies.
    var proxyAuthPortalURL: String?

    /// API key — stored in Keychain, NOT serialised to UserDefaults.
    /// Populated transiently at runtime via ``KeychainService``.
    var apiKey: String?

    // MARK: - Per-server user metadata (for server switcher UI)

    /// Display name of the last authenticated user on this server.
    /// Shown in the server list so users can identify which account is associated.
    var lastUserName: String?

    /// Email of the last authenticated user on this server.
    var lastUserEmail: String?

    /// Profile image URL of the last authenticated user.
    var lastUserProfileImageURL: String?

    /// Auth type used for the last successful login.
    var lastAuthType: AuthType?

    /// Whether this server had a valid, confirmed session at last use.
    /// Used to show the "Connected" vs "Saved" vs "Expired" badge in the server list.
    var hasActiveSession: Bool

    // Exclude apiKey from Codable to prevent plaintext storage in UserDefaults.
    enum CodingKeys: String, CodingKey {
        case id, name, url, customHeaders, lastConnected, isActive, allowSelfSignedCertificates
        case cfClearanceValue, cfClearanceExpiry, cfUserAgent, isCloudflareBotProtected
        case proxyAuthCookies, isAuthProxyProtected, proxyAuthPortalURL
        case lastUserName, lastUserEmail, lastUserProfileImageURL, lastAuthType, hasActiveSession
    }

    /// Custom decoder so existing saved configs (without the new metadata fields)
    /// decode successfully instead of throwing `keyNotFound` and wiping the server list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        customHeaders = (try? c.decode([String: String].self, forKey: .customHeaders)) ?? [:]
        lastConnected = try? c.decode(Date.self, forKey: .lastConnected)
        isActive = (try? c.decode(Bool.self, forKey: .isActive)) ?? false
        allowSelfSignedCertificates = (try? c.decode(Bool.self, forKey: .allowSelfSignedCertificates)) ?? false
        cfClearanceValue = try? c.decode(String.self, forKey: .cfClearanceValue)
        cfClearanceExpiry = try? c.decode(Date.self, forKey: .cfClearanceExpiry)
        cfUserAgent = try? c.decode(String.self, forKey: .cfUserAgent)
        isCloudflareBotProtected = (try? c.decode(Bool.self, forKey: .isCloudflareBotProtected)) ?? false
        proxyAuthCookies = try? c.decode([String: String].self, forKey: .proxyAuthCookies)
        isAuthProxyProtected = (try? c.decode(Bool.self, forKey: .isAuthProxyProtected)) ?? false
        proxyAuthPortalURL = try? c.decode(String.self, forKey: .proxyAuthPortalURL)
        // New metadata fields — default gracefully when absent (backwards compat)
        lastUserName = try? c.decode(String.self, forKey: .lastUserName)
        lastUserEmail = try? c.decode(String.self, forKey: .lastUserEmail)
        lastUserProfileImageURL = try? c.decode(String.self, forKey: .lastUserProfileImageURL)
        lastAuthType = try? c.decode(AuthType.self, forKey: .lastAuthType)
        hasActiveSession = (try? c.decode(Bool.self, forKey: .hasActiveSession)) ?? false
        apiKey = nil // always nil from storage; loaded from Keychain at runtime
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        apiKey: String? = nil,
        customHeaders: [String: String] = [:],
        lastConnected: Date? = nil,
        isActive: Bool = false,
        allowSelfSignedCertificates: Bool = false,
        cfClearanceValue: String? = nil,
        cfClearanceExpiry: Date? = nil,
        cfUserAgent: String? = nil,
        isCloudflareBotProtected: Bool = false,
        proxyAuthCookies: [String: String]? = nil,
        isAuthProxyProtected: Bool = false,
        proxyAuthPortalURL: String? = nil,
        lastUserName: String? = nil,
        lastUserEmail: String? = nil,
        lastUserProfileImageURL: String? = nil,
        lastAuthType: AuthType? = nil,
        hasActiveSession: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
        self.customHeaders = customHeaders
        self.lastConnected = lastConnected
        self.isActive = isActive
        self.allowSelfSignedCertificates = allowSelfSignedCertificates
        self.cfClearanceValue = cfClearanceValue
        self.cfClearanceExpiry = cfClearanceExpiry
        self.cfUserAgent = cfUserAgent
        self.isCloudflareBotProtected = isCloudflareBotProtected
        self.proxyAuthCookies = proxyAuthCookies
        self.isAuthProxyProtected = isAuthProxyProtected
        self.proxyAuthPortalURL = proxyAuthPortalURL
        self.lastUserName = lastUserName
        self.lastUserEmail = lastUserEmail
        self.lastUserProfileImageURL = lastUserProfileImageURL
        self.lastAuthType = lastAuthType
        self.hasActiveSession = hasActiveSession
    }

    /// Whether the persisted `cf_clearance` cookie is still valid (not expired).
    var hasFreshCFClearance: Bool {
        guard let value = cfClearanceValue, !value.isEmpty,
              let expiry = cfClearanceExpiry else { return false }
        // Consider expired if within 60 seconds of expiry to avoid edge cases
        return expiry.timeIntervalSinceNow > 60
    }

    /// The base API URL derived from the server URL.
    var apiBaseURL: URL? {
        URL(string: url)
    }
}
