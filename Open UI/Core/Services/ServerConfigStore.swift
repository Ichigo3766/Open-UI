import Foundation

/// Manages persistence and retrieval of server configurations.
@Observable
final class ServerConfigStore {
    private(set) var servers: [ServerConfig] = []

    private static let storageKey = "openui.server_configs"

    init() {
        loadServers()
    }

    /// The currently active server configuration.
    var activeServer: ServerConfig? {
        servers.first(where: \.isActive)
    }

    /// All servers that have a Keychain token (saved sessions).
    var serversWithSavedSessions: [ServerConfig] {
        servers.filter { KeychainService.shared.hasToken(forServer: $0.url) }
    }

    /// Adds or updates a server configuration.
    ///
    /// If a server with the same URL already exists, it is updated in place
    /// (preserving its `id` and accumulated metadata). Otherwise the new
    /// config is appended.  If this is the first server, it is made active.
    func addServer(_ config: ServerConfig) {
        if let index = servers.firstIndex(where: { $0.url.normalizedServerURL == config.url.normalizedServerURL }) {
            // Preserve accumulated metadata when updating
            var updated = config
            updated = updated.preservingMetadata(from: servers[index])
            if servers.isEmpty { updated.isActive = true }
            servers[index] = updated
        } else {
            var newConfig = config
            if servers.isEmpty {
                newConfig.isActive = true
            }
            servers.append(newConfig)
        }
        saveServers()
    }

    /// Updates an existing server configuration by ID.
    func updateServer(_ config: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        saveServers()
    }

    /// Removes a server configuration by ID.
    /// Also cleans up its Keychain token and cached user.
    func removeServer(id: String) {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        KeychainService.shared.deleteToken(forServer: config.url)
        KeychainService.shared.deleteToken(forServer: "cached_user_\(config.url)")
        servers.removeAll(where: { $0.id == id })
        saveServers()
    }

    /// Removes all server configurations and their Keychain data.
    func removeAllServers() {
        for server in servers {
            KeychainService.shared.deleteToken(forServer: server.url)
            KeychainService.shared.deleteToken(forServer: "cached_user_\(server.url)")
        }
        servers.removeAll()
        saveServers()
    }

    /// Sets a server as the active connection; deactivates all others.
    func setActiveServer(id: String) {
        for index in servers.indices {
            servers[index].isActive = (servers[index].id == id)
        }
        saveServers()
    }

    /// Returns the server config matching a URL (normalised comparison).
    func server(forURL url: String) -> ServerConfig? {
        let normalized = url.normalizedServerURL
        return servers.first { $0.url.normalizedServerURL == normalized }
    }

    /// Updates the user metadata fields on the active server without
    /// creating a full new config (used after successful login/restore).
    func updateActiveServerMetadata(
        userName: String?,
        userEmail: String?,
        profileImageURL: String?,
        authType: AuthType?,
        hasActiveSession: Bool
    ) {
        guard let index = servers.firstIndex(where: \.isActive) else { return }
        servers[index].lastUserName = userName
        servers[index].lastUserEmail = userEmail
        servers[index].lastUserProfileImageURL = profileImageURL
        servers[index].lastAuthType = authType
        servers[index].hasActiveSession = hasActiveSession
        servers[index].lastConnected = hasActiveSession ? .now : servers[index].lastConnected
        saveServers()
    }

    // MARK: - Persistence

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data)
        else { return }
        servers = decoded
    }
}

// MARK: - String helper

private extension String {
    /// Normalized server URL for deduplication comparisons.
    var normalizedServerURL: String {
        self.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }
}

// MARK: - ServerConfig metadata preservation

private extension ServerConfig {
    /// Returns a copy of `self` with accumulated metadata (user info, CF data,
    /// proxy data) carried over from `existing` where the new value is nil.
    func preservingMetadata(from existing: ServerConfig) -> ServerConfig {
        var result = self
        // Keep the original stable ID so downstream references don't break
        // Note: id is a let, so we rely on the caller passing the right config.
        // Preserve user metadata if the new config doesn't have it
        if result.lastUserName == nil { result.lastUserName = existing.lastUserName }
        if result.lastUserEmail == nil { result.lastUserEmail = existing.lastUserEmail }
        if result.lastUserProfileImageURL == nil { result.lastUserProfileImageURL = existing.lastUserProfileImageURL }
        if result.lastAuthType == nil { result.lastAuthType = existing.lastAuthType }
        // Preserve CF data if not overridden
        if result.cfClearanceValue == nil { result.cfClearanceValue = existing.cfClearanceValue }
        if result.cfClearanceExpiry == nil { result.cfClearanceExpiry = existing.cfClearanceExpiry }
        if result.cfUserAgent == nil { result.cfUserAgent = existing.cfUserAgent }
        // Preserve proxy data
        if result.proxyAuthCookies == nil { result.proxyAuthCookies = existing.proxyAuthCookies }
        if result.proxyAuthPortalURL == nil { result.proxyAuthPortalURL = existing.proxyAuthPortalURL }
        return result
    }
}
