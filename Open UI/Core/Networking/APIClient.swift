import Foundation
import os.log

/// High-level client for the OpenWebUI REST API, built on top of `NetworkManager`.
final class APIClient: @unchecked Sendable {
    let network: NetworkManager
    private let logger = Logger(subsystem: "com.openui", category: "API")

    /// Callback invoked when the auth token is rejected (401). Thread-safe via lock.
    private let _authCallbackLock = NSLock()
    private var _onAuthTokenInvalid: (() -> Void)?
    var onAuthTokenInvalid: (() -> Void)? {
        get {
            _authCallbackLock.lock()
            defer { _authCallbackLock.unlock() }
            return _onAuthTokenInvalid
        }
        set {
            _authCallbackLock.lock()
            _onAuthTokenInvalid = newValue
            _authCallbackLock.unlock()
        }
    }

    init(serverConfig: ServerConfig, keychain: KeychainService = .shared) {
        self.network = NetworkManager(serverConfig: serverConfig, keychain: keychain)
    }

    var baseURL: String { network.serverConfig.url }

    // MARK: - Health & Configuration

    func checkHealth() async -> Bool {
        do {
            let (_, response) = try await network.requestRaw(
                path: "/health",
                authenticated: false
            )
            return response.statusCode == 200
        } catch {
            return false
        }
    }

    /// Checks server health with proxy detection. Also detects HTTP→HTTPS redirects
    /// and returns the final HTTPS URL so the caller can update the stored server URL.
    func checkHealthWithProxyDetection() async -> HealthCheckResult {
        await checkHealthWithProxyDetectionAndFinalURL().result
    }

    /// Extended health check that also returns the final (post-redirect) URL.
    /// Used during connect() to detect HTTP→HTTPS upgrades from a load balancer.
    func checkHealthWithProxyDetectionAndFinalURL() async -> (result: HealthCheckResult, finalURL: String?) {
        do {
            // Use a custom delegate to capture the final URL after redirects
            let redirectCapture = RedirectCapturingDelegate(
                allowSelfSigned: network.serverConfig.allowSelfSignedCertificates,
                serverConfig: network.serverConfig
            )
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            let session = URLSession(configuration: config, delegate: redirectCapture, delegateQueue: nil)

            let request = try network.buildRequest(
                path: "/health",
                authenticated: false,
                timeout: 15
            )
            let (healthData, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return (.unreachable, nil)
            }

            // Check if a redirect happened (HTTP→HTTPS upgrade)
            let finalURL = redirectCapture.finalURL.flatMap { url -> String? in
                guard let originalURL = URL(string: network.serverConfig.url),
                      url.host?.lowercased() == originalURL.host?.lowercased(),
                      url.scheme?.lowercased() != originalURL.scheme?.lowercased() else {
                    return nil
                }
                // Rebuild with the new scheme (https) but same host/path/port
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.path = ""
                components?.query = nil
                components?.fragment = nil
                return components.flatMap { c -> String? in
                    // Just return scheme + host (+ port if non-standard)
                    if let port = c.port, (c.scheme == "https" && port != 443) || (c.scheme == "http" && port != 80) {
                        return "\(c.scheme ?? "https")://\(c.host ?? ""):\(port)"
                    }
                    return "\(c.scheme ?? "https")://\(c.host ?? "")"
                }
            }

            let statusCode = httpResponse.statusCode

            if [302, 307, 308].contains(statusCode) {
                return (.proxyAuthRequired, nil)
            }

            if [401, 403].contains(statusCode) {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("text/html") {
                    // Could be a Cloudflare challenge — check before flagging as proxy
                    if isCloudflareChallenge(data: healthData, response: httpResponse) {
                        return (.cloudflareChallenge, nil)
                    }
                    return (.proxyAuthRequired, nil)
                }
            }

            if statusCode == 200 {
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("text/html") {
                    // Check if this is a Cloudflare JS/bot challenge page
                    if isCloudflareChallenge(data: healthData, response: httpResponse) {
                        return (.cloudflareChallenge, nil)
                    }
                    // Other HTML from CDN/WAF — probe /api/config to confirm
                    let configResult = await confirmServerReachableViaConfig()
                    return (configResult, finalURL)
                }
                return (.healthy, finalURL)
            }

            // 407 Proxy Authentication Required
            if statusCode == 407 {
                return (.proxyAuthRequired, nil)
            }

            return (.unhealthy, nil)
        } catch {
            let apiError = APIError.from(error)
            if case .sslError = apiError { return (.unreachable, nil) }
            if case .networkError = apiError { return (.unreachable, nil) }
            return (.unreachable, nil)
        }
    }

    /// Detects if an HTML response is a Cloudflare Bot Fight Mode / Browser Integrity Check
    /// challenge. These pages require JavaScript execution in a real browser.
    private func isCloudflareChallenge(data: Data, response: HTTPURLResponse) -> Bool {
        // Cloudflare sets these response headers on challenge pages
        let cfRay = response.value(forHTTPHeaderField: "CF-RAY")
        let server = response.value(forHTTPHeaderField: "Server") ?? ""
        let isCloudflareServer = server.lowercased().contains("cloudflare") || cfRay != nil

        guard isCloudflareServer else { return false }

        // Check the HTML body for Cloudflare challenge markers
        if let html = String(data: data, encoding: .utf8) {
            let challengeMarkers = [
                "_cf_chl_opt",          // Cloudflare JS challenge opt
                "cf-browser-verification", // Browser verification page
                "jschl-answer",         // JS challenge answer field
                "cf_clearance",         // Clearance cookie reference
                "Checking your browser", // Challenge page title text
                "Just a moment",        // Challenge page loading text
                "cf-please-wait",       // Please wait CSS class
                "cf-spinner",           // Spinner element
                "challenge-running",    // Challenge state
                "turnstile",            // Cloudflare Turnstile CAPTCHA
            ]
            for marker in challengeMarkers {
                if html.contains(marker) {
                    return true
                }
            }
        }
        return false
    }

    /// Secondary probe used when `/health` returns HTML (Cloudflare/WAF edge interference).
    /// Hits `/api/config` which is a pure JSON endpoint — if it returns valid JSON the
    /// server backend is reachable and the HTML from `/health` was just a CDN artefact.
    private func confirmServerReachableViaConfig() async -> HealthCheckResult {
        do {
            let request = try network.buildRequest(
                path: "/api/config",
                authenticated: false,
                timeout: 10
            )
            let (data, response) = try await network.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .proxyAuthRequired
            }

            let statusCode = httpResponse.statusCode
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

            // If /api/config returns JSON with a 200, the backend is real and reachable
            if statusCode == 200 && contentType.contains("application/json") {
                if (try? JSONSerialization.jsonObject(with: data)) != nil {
                    return .healthy
                }
            }

            // Check if /api/config is also blocked by a Cloudflare challenge
            if isCloudflareChallenge(data: data, response: httpResponse) {
                return .cloudflareChallenge
            }

            // /api/config returned HTML too — likely a proxy/WAF blocking all endpoints.
            return .proxyAuthRequired
        } catch {
            return .proxyAuthRequired
        }
    }

    func getBackendConfig() async throws -> BackendConfig {
        let (data, _) = try await network.requestRaw(path: "/api/config", authenticated: false)
        do {
            let config = try JSONDecoder().decode(BackendConfig.self, from: data)
            return config
        } catch {
            logger.error("❌ [getBackendConfig] Decode FAILED: \(error)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let ctx):
                    logger.error("  keyNotFound: \(key.stringValue) — \(ctx.debugDescription)")
                case .typeMismatch(let type, let ctx):
                    logger.error("  typeMismatch: \(type) — \(ctx.debugDescription) at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))")
                case .valueNotFound(let type, let ctx):
                    logger.error("  valueNotFound: \(type) — \(ctx.debugDescription)")
                case .dataCorrupted(let ctx):
                    logger.error("  dataCorrupted: \(ctx.debugDescription)")
                @unknown default:
                    logger.error("  unknown decoding error")
                }
            }
            throw error
        }
    }

    func verifyAndGetConfig() async -> BackendConfig? {
        guard let config = try? await getBackendConfig(),
              config.isValidOpenWebUI
        else { return nil }
        return config
    }

    func checkServerStatus() async -> [String: Any] {
        var result: [String: Any] = [
            "healthy": false,
            "modelsAvailable": false,
            "modelCount": 0
        ]

        let healthy = await checkHealth()
        result["healthy"] = healthy

        if healthy {
            if let models = try? await getModels() {
                result["modelsAvailable"] = !models.isEmpty
                result["modelCount"] = models.count
            }
        }

        return result
    }

    // MARK: - Authentication

    func login(email: String, password: String) async throws -> User {
        let response = try await network.request(
            AuthResponse.self,
            path: "/api/v1/auths/signin",
            method: .post,
            body: ["email": email, "password": password] as [String: String],
            authenticated: false
        )

        network.saveAuthToken(response.token)

        return User(
            id: response.id ?? "",
            username: response.name ?? email,
            email: response.email ?? email,
            name: response.name,
            profileImageURL: response.profileImageUrl,
            role: User.UserRole(rawValue: response.role ?? "user") ?? .user
        )
    }

    func ldapLogin(username: String, password: String) async throws -> User {
        let response = try await network.request(
            AuthResponse.self,
            path: "/api/v1/auths/ldap",
            method: .post,
            body: ["user": username, "password": password] as [String: String],
            authenticated: false
        )

        network.saveAuthToken(response.token)

        return User(
            id: response.id ?? "",
            username: response.name ?? username,
            email: response.email ?? "",
            name: response.name,
            profileImageURL: response.profileImageUrl,
            role: User.UserRole(rawValue: response.role ?? "user") ?? .user
        )
    }

    func signup(name: String, email: String, password: String) async throws -> User {
        let response = try await network.request(
            AuthResponse.self,
            path: "/api/v1/auths/signup",
            method: .post,
            body: ["name": name, "email": email, "password": password] as [String: String],
            authenticated: false
        )

        network.saveAuthToken(response.token)

        return User(
            id: response.id ?? "",
            username: response.name ?? name,
            email: response.email ?? email,
            name: response.name,
            profileImageURL: response.profileImageUrl,
            role: User.UserRole(rawValue: response.role ?? "user") ?? .user
        )
    }

    func logout() async throws {
        try await network.requestVoid(path: "/api/v1/auths/signout")
        network.deleteAuthToken()
    }

    func getCurrentUser() async throws -> User {
        try await network.request(User.self, path: "/api/v1/auths/")
    }

    func updateAuthToken(_ token: String?) {
        if let token {
            network.saveAuthToken(token)
        } else {
            network.deleteAuthToken()
        }
    }

    // MARK: - Models

    func getModels() async throws -> [AIModel] {
        let (data, _) = try await network.requestRaw(path: "/api/models")

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return parseModelArray(array)
            }
            return []
        }

        if let modelsArray = payload["data"] as? [[String: Any]] {
            return parseModelArray(modelsArray)
        }
        if let modelsArray = payload["models"] as? [[String: Any]] {
            return parseModelArray(modelsArray)
        }

        return []
    }

    func getDefaultModel() async -> String? {
        do {
            let settings = try await getUserSettings()
            if let ui = settings["ui"] as? [String: Any],
               let models = ui["models"] as? [String],
               let first = models.first {
                return first
            }
        } catch {}

        if let models = try? await getModels(), let first = models.first {
            return first.id
        }
        return nil
    }

    func getModelDetails(modelId: String) async throws -> [String: Any] {
        try await network.requestJSON(
            path: "/api/v1/models/model",
            queryItems: [URLQueryItem(name: "id", value: modelId)]
        )
    }

    /// Fetches full model configuration from `/api/v1/models/model?id={id}`.
    ///
    /// Unlike `/api/models` (which returns a lightweight list without `params`),
    /// this endpoint returns the complete model config including:
    /// - `params.function_calling` — "native" or absent (for default mode)
    /// - `meta.capabilities` — all capabilities
    /// - `meta.builtinTools` — which builtin tools are enabled
    /// - `meta.toolIds` — server-assigned tools
    /// - `meta.defaultFeatureIds` — default features like web_search, image_generation
    ///
    /// Called when a model is selected to get authoritative config for that model.
    func fetchModelConfig(modelId: String) async throws -> AIModel? {
        let raw = try await getModelDetails(modelId: modelId)
        return parseModelConfig(raw)
    }

    /// Parses a full model config response from `/api/v1/models/model`.
    /// The schema differs from the `/api/models` list — `params` and `meta` are top-level,
    /// not nested under `info`.
    func parseModelConfig(_ raw: [String: Any]) -> AIModel? {
        guard let id = raw["id"] as? String else { return nil }
        let name = raw["name"] as? String ?? id

        var isMultimodal = false
        var supportsRAG = false
        var capabilities: [String: String]?
        var profileImageURL: String?
        var toolIds: [String] = []
        var defaultFeatureIds: [String] = []
        var functionCallingMode: String?
        var builtinTools: [String: Bool] = [:]

        // Top-level `params` (present in single-model endpoint)
        if let params = raw["params"] as? [String: Any] {
            if let fc = params["function_calling"] as? String, !fc.isEmpty {
                functionCallingMode = fc
            }
        }

        // Helper to parse builtinTools from a meta dict
        let parseBuiltinTools: ([String: Any]) -> [String: Bool] = { meta in
            guard let bt = meta["builtinTools"] as? [String: Any] else { return [:] }
            var result: [String: Bool] = [:]
            for (key, value) in bt {
                if let boolVal = value as? Bool {
                    result[key] = boolVal
                } else if let intVal = value as? Int {
                    result[key] = intVal != 0
                }
            }
            return result
        }

        // Top-level `meta` (present in single-model endpoint)
        if let meta = raw["meta"] as? [String: Any] {
            profileImageURL = meta["profile_image_url"] as? String
            if let caps = meta["capabilities"] as? [String: Any] {
                isMultimodal = caps["vision"] as? Bool ?? false
                supportsRAG = caps["citations"] as? Bool ?? false
                capabilities = caps.compactMapValues { "\($0)" }
            }
            if let tools = meta["toolIds"] as? [String] {
                toolIds = tools
            }
            if let defaultFeatures = meta["defaultFeatureIds"] as? [String] {
                defaultFeatureIds = defaultFeatures
            }
            builtinTools = parseBuiltinTools(meta)
        }

        // Fallback: `info.meta` (present in list endpoint — allows reuse for both)
        if let info = raw["info"] as? [String: Any] {
            if let meta = info["meta"] as? [String: Any] {
                if profileImageURL == nil {
                    profileImageURL = meta["profile_image_url"] as? String
                }
                if capabilities == nil, let caps = meta["capabilities"] as? [String: Any] {
                    isMultimodal = caps["vision"] as? Bool ?? false
                    supportsRAG = caps["citations"] as? Bool ?? false
                    capabilities = caps.compactMapValues { "\($0)" }
                }
                if toolIds.isEmpty, let tools = meta["toolIds"] as? [String] {
                    toolIds = tools
                }
                if defaultFeatureIds.isEmpty, let defaultFeatures = meta["defaultFeatureIds"] as? [String] {
                    defaultFeatureIds = defaultFeatures
                }
                if builtinTools.isEmpty {
                    builtinTools = parseBuiltinTools(meta)
                }
            }
        }

        return AIModel(
            id: id,
            name: name,
            description: raw["description"] as? String,
            isMultimodal: isMultimodal,
            supportsStreaming: true,
            supportsRAG: supportsRAG,
            contextLength: raw["context_length"] as? Int,
            capabilities: capabilities,
            profileImageURL: profileImageURL,
            toolIds: toolIds,
            defaultFeatureIds: defaultFeatureIds,
            functionCallingMode: functionCallingMode,
            builtinTools: builtinTools
        )
    }

    // MARK: - Conversations

    /// Fetches conversations including pinned status.
    ///
    /// The list endpoint's `ChatTitleIdResponse` doesn't include a `pinned` field,
    /// so we parallel-fetch `/api/v1/chats/pinned` and merge the IDs in.
    func getConversations(limit: Int? = nil, skip: Int? = nil) async throws -> [Conversation] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "include_folders", value: "false"),
            URLQueryItem(name: "include_pinned", value: "true")
        ]

        if let limit, limit > 0 {
            let page = ((skip ?? 0) / limit) + 1
            queryItems.append(URLQueryItem(name: "page", value: "\(max(1, page))"))
        }

        let capturedQueryItems = queryItems

        async let conversationsRequest = network.requestRaw(
            path: "/api/v1/chats/",
            queryItems: capturedQueryItems
        )
        async let pinnedIdsRequest = getPinnedConversationIds()

        let (data, _) = try await conversationsRequest
        let pinnedIds = (try? await pinnedIdsRequest) ?? Set<String>()

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected array of chats"]
                ),
                data: data
            )
        }

        return array.compactMap { parseConversationSummary($0) }.map { conv in
            guard !pinnedIds.isEmpty, pinnedIds.contains(conv.id) else { return conv }
            var pinned = conv
            pinned.pinned = true
            return pinned
        }
    }

    /// Fetches a specific page of conversations.
    ///
    /// - Parameter page: 1-based page number.
    /// - Parameter pinnedIds: Pre-fetched set of pinned IDs to merge in. Pass `nil` to
    ///   skip pinned merging (used for pages > 1 where pinned IDs are already known).
    /// - Returns: Array of conversations on this page, or empty array if no more pages.
    func getConversationsPage(page: Int, pinnedIds: Set<String>? = nil) async throws -> [Conversation] {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "include_folders", value: "false"),
            URLQueryItem(name: "include_pinned", value: "true")
        ]

        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/",
            queryItems: queryItems
        )

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Some servers return null or a non-array — treat as end of pages
            return []
        }

        guard !array.isEmpty else { return [] }

        let knownPinnedIds = pinnedIds ?? Set<String>()
        return array.compactMap { parseConversationSummary($0) }.map { conv in
            guard !knownPinnedIds.isEmpty, knownPinnedIds.contains(conv.id) else { return conv }
            var pinned = conv
            pinned.pinned = true
            return pinned
        }
    }

    /// Fetches pinned conversation IDs from the dedicated `/api/v1/chats/pinned` endpoint.
    /// The list endpoint doesn't include pinned status in its response schema.
    func getPinnedConversationIds() async throws -> Set<String> {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/pinned")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let ids = array.compactMap { $0["id"] as? String }
        return Set(ids)
    }

    func getConversation(id: String) async throws -> Conversation {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/\(id)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected chat object"]
                ),
                data: data
            )
        }

        return parseFullConversation(json)
    }

    func createConversation(
        title: String,
        messages: [ChatMessage],
        model: String? = nil,
        systemPrompt: String? = nil,
        folderId: String? = nil
    ) async throws -> Conversation {
        let chatData = buildChatPayload(
            title: title,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )

        var body: [String: Any] = ["chat": chatData]
        body["folder_id"] = folderId

        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/new",
            method: .post,
            body: try JSONSerialization.data(withJSONObject: body)
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected chat object"]
                ),
                data: data
            )
        }

        return parseFullConversation(json)
    }

    func updateConversation(id: String, title: String? = nil, systemPrompt: String? = nil) async throws {
        var chatPayload: [String: Any] = [:]
        if let title { chatPayload["title"] = title }
        if let systemPrompt { chatPayload["system"] = systemPrompt }

        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(id)",
            method: .post,
            body: ["chat": chatPayload]
        )
    }

    func deleteConversation(id: String) async throws {
        try await network.requestVoid(path: "/api/v1/chats/\(id)", method: .delete)
    }

    func deleteAllConversations() async throws {
        try await network.requestVoid(path: "/api/v1/chats/", method: .delete)
    }

    func pinConversation(id: String, pinned: Bool) async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/\(id)/pin",
            method: .post,
            body: ["pinned": pinned] as [String: Bool]
        )
    }

    func archiveConversation(id: String, archived: Bool) async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/\(id)/archive",
            method: .post,
            body: ["archived": archived] as [String: Bool]
        )
    }

    func shareConversation(id: String) async throws -> String? {
        let json = try await network.requestJSON(
            path: "/api/v1/chats/\(id)/share",
            method: .post
        )
        return json["share_id"] as? String
    }

    func cloneConversation(id: String) async throws -> Conversation {
        let emptyBody = try JSONSerialization.data(withJSONObject: [String: Any]())
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/\(id)/clone",
            method: .post,
            body: emptyBody
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected chat object"]
                ),
                data: data
            )
        }

        return parseFullConversation(json)
    }

    func searchConversations(query: String) async throws -> [Conversation] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/search",
            queryItems: [URLQueryItem(name: "text", value: query)]
        )

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { parseConversationSummary($0) }
    }

    func moveConversationToFolder(conversationId: String, folderId: String?) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(conversationId)/folder",
            method: .post,
            body: ["folder_id": folderId as Any]
        )
    }

    // MARK: - Chat Completion (Streaming)

    func sendMessage(
        request: ChatCompletionRequest
    ) async throws -> (json: [String: Any], messageId: String, sessionId: String) {
        let body = request.toJSON()

        let responseJSON = try await network.requestJSON(
            path: "/api/chat/completions",
            method: .post,
            body: body,
            timeout: 30
        )

        return (
            json: responseJSON,
            messageId: request.messageId ?? UUID().uuidString,
            sessionId: request.sessionId ?? UUID().uuidString
        )
    }

    func sendMessageStreaming(request: ChatCompletionRequest) async throws -> SSEStream {
        try await network.streamRequestBytes(
            path: "/api/chat/completions",
            method: .post,
            body: request.toJSON()
        )
    }

    /// Sends a chat completion request via HTTP POST. Returns immediately;
    /// actual content is delivered via Socket.IO events.
    func sendMessageHTTP(request: ChatCompletionRequest) async throws -> [String: Any] {
        let body = request.toJSON()
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/chat/completions",
            method: .post,
            body: bodyData,
            timeout: 30
        )
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return ["raw": str]
        }
        return [:]
    }

    func syncConversationMessages(
        id: String,
        messages: [ChatMessage],
        model: String?,
        systemPrompt: String? = nil,
        title: String? = nil
    ) async throws {
        let chatData = buildChatPayload(
            title: title ?? "",
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(id)",
            method: .post,
            body: ["chat": chatData]
        )
    }

    func sendChatCompleted(
        chatId: String,
        messageId: String,
        model: String,
        sessionId: String,
        messages: [[String: Any]] = [],
        filterIds: [String] = []
    ) async {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "chat_id": chatId,
            "session_id": sessionId,
            "id": messageId
        ]
        if !filterIds.isEmpty {
            body["filter_ids"] = filterIds
        }

        try? await network.requestVoidJSON(
            path: "/api/chat/completed",
            method: .post,
            body: body
        )
    }

    func stopTask(taskId: String) async throws {
        try await network.requestVoid(
            path: "/api/tasks/stop/\(taskId)",
            method: .post
        )
    }

    func getTasksForChat(chatId: String) async throws -> [String] {
        let (data, _) = try await network.requestRaw(path: "/api/tasks/chat/\(chatId)")
        let parsed = try JSONSerialization.jsonObject(with: data)
        if let arr = parsed as? [[String: Any]] {
            return arr.compactMap { $0["id"] as? String }
        }
        if let arr = parsed as? [String] {
            return arr
        }
        if let dict = parsed as? [String: Any] {
            if let arr = dict["tasks"] as? [[String: Any]] {
                return arr.compactMap { $0["id"] as? String }
            }
            if let arr = dict["task_ids"] as? [String] {
                return arr
            }
        }
        return []
    }

    // MARK: - User Settings

    func getUserSettings() async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/users/user/settings")
    }

    func updateUserSettings(_ settings: [String: Any]) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/users/user/settings/update",
            method: .post,
            body: settings
        )
    }

    // MARK: - Folders

    /// Returns `(folders, featureEnabled)`. Returns `enabled: false` on 403.
    func getFolders() async throws -> (folders: [[String: Any]], enabled: Bool) {
        do {
            let (data, _) = try await network.requestRaw(path: "/api/v1/folders/")
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return ([], true)
            }
            return (array, true)
        } catch let error as APIError {
            if case .httpError(let code, _, _) = error, code == 403 {
                return ([], false)
            }
            throw error
        }
    }

    func createFolder(
        name: String,
        parentId: String? = nil,
        data folderData: [String: Any]? = nil,
        meta: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var body: [String: Any] = ["name": name]
        if let parentId { body["parent_id"] = parentId }
        if let folderData { body["data"] = folderData }
        if let meta { body["meta"] = meta }
        return try await network.requestJSON(
            path: "/api/v1/folders/",
            method: .post,
            body: body
        )
    }

    /// Fetches full folder details by ID, including `data` and `meta` fields.
    func getFolderById(id: String) async throws -> [String: Any] {
        return try await network.requestJSON(path: "/api/v1/folders/\(id)")
    }

    /// Full update: name, data (system prompt, models, knowledge), and meta (background image).
    /// Uses `FolderUpdateForm` schema: name?, data?, meta?.
    func updateFolder(
        id: String,
        name: String? = nil,
        data folderData: [String: Any]? = nil,
        meta: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let folderData { body["data"] = folderData }
        if let meta { body["meta"] = meta }
        return try await network.requestJSON(
            path: "/api/v1/folders/\(id)/update",
            method: .post,
            body: body
        )
    }

    /// Convenience: rename only (delegates to updateFolder).
    func renameFolder(id: String, name: String) async throws -> [String: Any] {
        return try await updateFolder(id: id, name: name)
    }

    /// Fire-and-forget — failures are silently ignored.
    func setFolderExpanded(id: String, expanded: Bool) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/folders/\(id)/update/expanded",
            method: .post,
            body: ["is_expanded": expanded]
        )
    }

    func moveFolderParent(id: String, parentId: String?) async throws {
        var body: [String: Any] = [:]
        if let parentId {
            body["parent_id"] = parentId
        } else {
            body["parent_id"] = NSNull()
        }
        try await network.requestVoidJSON(
            path: "/api/v1/folders/\(id)/update/parent",
            method: .post,
            body: body
        )
    }

    /// Deletes a folder. When `deleteContents` is true, also deletes all chats inside.
    func deleteFolder(id: String, deleteContents: Bool = false) async throws {
        if deleteContents {
            try await network.requestVoid(
                path: "/api/v1/folders/\(id)",
                method: .delete,
                queryItems: [URLQueryItem(name: "delete_contents", value: "true")]
            )
        } else {
            try await network.requestVoid(path: "/api/v1/folders/\(id)", method: .delete)
        }
    }

    func getChatsInFolder(folderId: String, page: Int = 1) async throws -> [Conversation] {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)")
        ]
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/folder/\(folderId)/list",
            queryItems: queryItems
        )

        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { parseFolderChatItem($0, folderId: folderId) }
        }
        return []
    }

    /// Handles both summary (`title` at root) and full (`chat.title` nested) formats.
    private func parseFolderChatItem(_ json: [String: Any], folderId: String) -> Conversation? {
        guard let id = json["id"] as? String else { return nil }

        var title = json["title"] as? String ?? ""
        if title.isEmpty, let chat = json["chat"] as? [String: Any] {
            title = chat["title"] as? String ?? ""
        }
        if title.isEmpty { title = "Untitled Chat" }

        var createdAt = Date()
        var updatedAt = Date()
        if let ts = json["created_at"] as? Double { createdAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["created_at"] as? Int { createdAt = Date(timeIntervalSince1970: Double(ts)) }
        if let ts = json["updated_at"] as? Double { updatedAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["updated_at"] as? Int { updatedAt = Date(timeIntervalSince1970: Double(ts)) }

        let pinned = json["pinned"] as? Bool ?? false
        let archived = json["archived"] as? Bool ?? false
        let tags = json["tags"] as? [String] ?? []

        var model: String?
        if let chat = json["chat"] as? [String: Any],
           let models = chat["models"] as? [String],
           let first = models.first {
            model = first
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            pinned: pinned,
            archived: archived,
            folderId: folderId,
            tags: tags
        )
    }

    // MARK: - Tags

    func getAllTags() async throws -> [String] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/all/tags")

        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { $0["name"] as? String }
        }
        if let array = try JSONSerialization.jsonObject(with: data) as? [String] {
            return array
        }
        return []
    }

    func addTag(to conversationId: String, tag: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(conversationId)/tags",
            method: .post,
            body: ["tag_name": tag]
        )
    }

    func removeTag(from conversationId: String, tag: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/chats/\(conversationId)/tags",
            method: .delete,
            body: ["tag_name": tag]
        )
    }

    // MARK: - Files

    /// Uploads a file with server-side processing for non-image files.
    ///
    /// For documents (PDF, txt, etc.), waits for text extraction/embeddings
    /// via SSE polling before returning — required before using the file in RAG.
    ///
    /// - Parameters:
    ///   - onUploaded: Called after the multipart upload succeeds but before processing
    ///     begins. Receives the file ID. Use this to transition UI from "uploading" to
    ///     "processing" state while the SSE poll runs.
    func uploadFile(
        data fileData: Data,
        fileName: String,
        onUploaded: ((String) -> Void)? = nil
    ) async throws -> String {
        let mime = mimeType(for: fileName)
        let isImage = mime.hasPrefix("image/")

        let queryItems: [URLQueryItem]? = isImage ? nil : [
            URLQueryItem(name: "process", value: "true")
        ]

        let response = try await network.uploadMultipart(
            path: "/api/v1/files/",
            queryItems: queryItems,
            fileData: fileData,
            fileName: fileName,
            mimeType: mime,
            timeout: 300
        )

        guard let fileId = response["id"] as? String else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing file ID in response"]
                ),
                data: nil
            )
        }

        if !isImage {
            // Notify caller that file is uploaded — processing is about to start
            onUploaded?(fileId)
            try await waitForFileProcessing(fileId: fileId)
        }

        return fileId
    }

    /// Polls `GET /api/v1/files/{id}/process/status?stream=true` via SSE
    /// until status is `"completed"` or an error/timeout occurs.
    /// Throws `APIError.httpError` if the server reports a processing failure.
    private func waitForFileProcessing(fileId: String, timeout: TimeInterval = 300) async throws {
        let queryItems = [URLQueryItem(name: "stream", value: "true")]

        var request = try network.buildRequest(
            path: "/api/v1/files/\(fileId)/process/status",
            method: .get,
            queryItems: queryItems,
            authenticated: true,
            timeout: timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 60
        config.waitsForConnectivity = true

        let session: URLSession
        if network.serverConfig.allowSelfSignedCertificates {
            session = network.session
        } else {
            session = URLSession(configuration: config)
        }

        let (bytes, response) = try await session.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 4096 { break }
            }
            logger.error("File processing status check failed with \(httpResponse.statusCode)")
            throw APIError.httpError(
                statusCode: httpResponse.statusCode,
                message: "File processing check failed (HTTP \(httpResponse.statusCode))",
                data: errorBody
            )
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let jsonString: String
            if trimmed.hasPrefix("data: ") {
                jsonString = String(trimmed.dropFirst(6))
            } else if trimmed.hasPrefix("{") {
                jsonString = trimmed
            } else {
                continue
            }

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let status = json["status"] as? String else {
                continue
            }

            logger.debug("File \(fileId) processing status: \(status)")

            switch status {
            case "completed":
                logger.info("File \(fileId) processing completed")
                return
            case "failed", "error":
                // Extract the server-provided error message and surface it to the user
                let rawError = json["error"] as? String ?? "File processing failed on the server."
                // Strip verbose internal prefixes to keep the message readable
                let errorMsg = rawError
                    .replacingOccurrences(of: "Error transcribing chunk: External: ", with: "")
                    .replacingOccurrences(of: "External: ", with: "")
                logger.error("File \(fileId) processing error: \(rawError)")
                throw APIError.httpError(
                    statusCode: 422,
                    message: errorMsg,
                    data: nil
                )
            default:
                continue
            }
        }

        logger.info("File \(fileId) processing stream ended (assuming completed)")
    }

    func getFileInfo(id: String) async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/files/\(id)")
    }

    func getFileContent(id: String) async throws -> (Data, String) {
        let (data, response) = try await network.requestRaw(
            path: "/api/v1/files/\(id)/content"
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, contentType)
    }

    func getUserFiles() async throws -> [FileInfoResponse] {
        try await network.request([FileInfoResponse].self, path: "/api/v1/files/")
    }

    func deleteFile(id: String) async throws {
        try await network.requestVoid(path: "/api/v1/files/\(id)", method: .delete)
    }

    func fileContentURL(for fileId: String) -> URL? {
        network.baseURL?.appendingPathComponent("api/v1/files/\(fileId)/content")
    }

    // MARK: - Audio

    func transcribeSpeech(audioData: Data, fileName: String) async throws -> [String: Any] {
        let mime = mimeType(for: fileName)
        return try await network.uploadMultipart(
            path: "/api/v1/audio/transcriptions",
            fileData: audioData,
            fileName: fileName,
            mimeType: mime
        )
    }

    func generateSpeech(text: String, voice: String? = nil) async throws -> (Data, String) {
        var body: [String: Any] = ["input": text]
        if let voice { body["voice"] = voice }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await network.requestRaw(
            path: "/api/v1/audio/speech",
            method: .post,
            body: bodyData
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"
        return (data, contentType)
    }

    // MARK: - Knowledge Base

    func getKnowledgeBases() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/knowledge/")
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            return items
        }
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    func getKnowledgeItems() async throws -> [KnowledgeItem] {
        let raw = try await getKnowledgeBases()
        return raw.compactMap { entry -> KnowledgeItem? in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else { return nil }
            let description = entry["description"] as? String
            let files = entry["files"] as? [[String: Any]]
            return KnowledgeItem(
                id: id,
                name: name,
                description: description,
                type: .collection,
                fileCount: files?.count
            )
        }
    }

    /// Fetches files belonging to knowledge bases (not raw user uploads).
    /// These appear in the `#` picker alongside collections and folders.
    func getKnowledgeFileItems() async throws -> [KnowledgeItem] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/knowledge/search/files"
        )
        let parseEntry: ([String: Any]) -> KnowledgeItem? = { entry in
            guard let id = entry["id"] as? String else { return nil }
            let filename = entry["filename"] as? String
            let meta = entry["meta"] as? [String: Any]
            let name = meta?["name"] as? String ?? filename ?? id
            return KnowledgeItem(id: id, name: name, description: nil, type: .file, fileCount: nil)
        }
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            return items.compactMap(parseEntry)
        }
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap(parseEntry)
        }
        return []
    }

    func getFolderItems() async throws -> [KnowledgeItem] {
        let (folders, _) = try await getFolders()
        return folders.compactMap { entry -> KnowledgeItem? in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else { return nil }
            return KnowledgeItem(id: id, name: name, description: nil, type: .folder, fileCount: nil)
        }
    }

    // MARK: - Prompts

    func getPrompts() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/prompts/")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    // MARK: - Tools

    func getTools() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/tools/")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    // MARK: - Terminal Servers

    func listTerminalServers() async throws -> [TerminalServer] {
        do {
            let (data, _) = try await network.requestRaw(path: "/api/v1/terminals/")
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return array.compactMap { item -> TerminalServer? in
                guard let id = item["id"] as? String else { return nil }
                let name = item["name"] as? String ?? id
                return TerminalServer(id: id, name: name)
            }
        } catch {
            return []
        }
    }

    func getTerminalConfig(serverId: String) async throws -> TerminalConfig {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/api/config"
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TerminalConfig(from: [:])
        }
        return TerminalConfig(from: json)
    }

    func terminalListFiles(serverId: String, path: String) async throws -> [TerminalFileItem] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/files/list",
            queryItems: [URLQueryItem(name: "directory", value: path)]
        )
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = json["entries"] as? [[String: Any]] {
            let dir = json["dir"] as? String ?? path
            return entries.map { TerminalFileItem(from: $0, basePath: dir) }
        }
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.map { TerminalFileItem(from: $0, basePath: path) }
        }
        return []
    }

    func terminalReadFile(serverId: String, path: String) async throws -> String {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/files/read",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? String {
            return content
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func terminalMkdir(serverId: String, path: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/terminals/\(serverId)/files/mkdir",
            method: .post,
            body: ["path": path]
        )
    }

    func terminalDeleteFile(serverId: String, path: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/terminals/\(serverId)/files/delete",
            method: .delete,
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
    }

    func terminalDownloadFile(serverId: String, path: String) async throws -> (Data, String) {
        let (data, response) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/files/view",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, contentType)
    }

    func terminalWriteFile(serverId: String, path: String, content: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "path": path,
            "content": content
        ])
        try await network.requestVoid(
            path: "/api/v1/terminals/\(serverId)/files/write",
            method: .post,
            body: body
        )
    }

    /// Executes a command. Uses `wait=10` so short commands complete inline
    /// without requiring polling. Returns the process ID for long-running commands.
    func terminalExecute(serverId: String, command: String, cwd: String? = nil) async throws -> TerminalCommandResult {
        var body: [String: Any] = ["command": command]
        if let cwd { body["cwd"] = cwd }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/execute",
            method: .post,
            queryItems: [URLQueryItem(name: "wait", value: "10")],
            body: bodyData
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.unknown(underlying: NSError(domain: "Terminal", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid execute response"]))
        }
        return TerminalCommandResult(from: json)
    }

    /// Polls command status. `wait=5` blocks up to 5s for new output,
    /// and `offset` enables incremental reads.
    func terminalGetCommandStatus(serverId: String, processId: String, offset: Int = 0) async throws -> TerminalCommandResult {
        var queryItems = [URLQueryItem(name: "offset", value: "\(offset)")]
        queryItems.append(URLQueryItem(name: "wait", value: "5"))
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/terminals/\(serverId)/execute/\(processId)/status",
            queryItems: queryItems
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.unknown(underlying: NSError(domain: "Terminal", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid status response"]))
        }
        return TerminalCommandResult(from: json)
    }

    func terminalUploadFile(serverId: String, fileData: Data, fileName: String, destinationPath: String) async throws {
        let boundary = UUID().uuidString
        var body = Data()

        let mime = mimeType(for: fileName)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = try network.buildRequest(
            path: "/api/v1/terminals/\(serverId)/files/upload",
            method: .post,
            queryItems: [URLQueryItem(name: "directory", value: destinationPath)],
            authenticated: true,
            timeout: 120
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await network.session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: "Upload failed", data: nil)
        }
    }

    // MARK: - Notes

    /// Returns `(notes, featureEnabled)`. Returns `enabled: false` on 401/403.
    func getNotes() async throws -> (notes: [[String: Any]], featureEnabled: Bool) {
        do {
            let (data, _) = try await network.requestRaw(path: "/api/v1/notes/")
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return ([], true)
            }
            return (array, true)
        } catch let error as APIError {
            if case .httpError(let code, _, _) = error, code == 401 || code == 403 {
                return ([], false)
            }
            throw error
        }
    }

    func getNoteById(_ id: String) async throws -> [String: Any] {
        try await network.requestJSON(path: "/api/v1/notes/\(id)")
    }

    func createNote(
        title: String,
        markdownContent: String = "",
        htmlContent: String = ""
    ) async throws -> [String: Any] {
        let noteData: [String: Any] = [
            "content": [
                "json": NSNull(),
                "html": htmlContent,
                "md": markdownContent
            ],
            "versions": [] as [Any],
            "files": NSNull()
        ]

        let body: [String: Any] = [
            "title": title,
            "data": noteData,
            "access_control": [String: Any]()
        ]

        return try await network.requestJSON(
            path: "/api/v1/notes/create",
            method: .post,
            body: body
        )
    }

    func updateNote(
        id: String,
        title: String? = nil,
        markdownContent: String? = nil,
        htmlContent: String? = nil
    ) async throws -> [String: Any] {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }

        if markdownContent != nil || htmlContent != nil {
            body["data"] = [
                "content": [
                    "json": NSNull(),
                    "html": htmlContent ?? "",
                    "md": markdownContent ?? ""
                ]
            ]
        }

        return try await network.requestJSON(
            path: "/api/v1/notes/\(id)/update",
            method: .post,
            body: body
        )
    }

    func deleteNote(id: String) async throws -> Bool {
        do {
            try await network.requestVoid(
                path: "/api/v1/notes/\(id)/delete",
                method: .delete
            )
            return true
        } catch {
            return false
        }
    }

    func searchNotes(query: String) async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/notes/search",
            queryItems: [URLQueryItem(name: "query", value: query)]
        )
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    // MARK: - Profile & Account

    func updateProfile(name: String, profileImageUrl: String? = nil) async throws {
        var body: [String: String] = ["name": name]
        if let url = profileImageUrl { body["profile_image_url"] = url }
        try await network.requestVoidJSON(
            path: "/api/v1/auths/update/profile",
            method: .post,
            body: body
        )
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/auths/update/password",
            method: .post,
            body: [
                "password": currentPassword,
                "new_password": newPassword
            ]
        )
    }

    /// Fire-and-forget — sends timezone context to server after login.
    func updateTimezone(_ timezone: String) async {
        try? await network.requestVoidJSON(
            path: "/api/v1/auths/update/timezone",
            method: .post,
            body: ["timezone": timezone]
        )
    }

    // MARK: - Audio (Extended)

    func getVoices() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/audio/voices")
        if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let voices = dict["voices"] as? [[String: Any]] {
            return voices
        }
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    // MARK: - Chat Extended Operations

    func unshareConversation(id: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/\(id)/share",
            method: .delete
        )
    }

    /// Fetches a shared chat by its share ID.
    /// Used to display the read-only shared chat view in-app.
    func getSharedConversation(shareId: String) async throws -> Conversation {
        let (data, _) = try await network.requestRaw(path: "/api/v1/chats/share/\(shareId)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected shared chat object"]
                ),
                data: data
            )
        }
        return parseFullConversation(json)
    }

    func archiveAllConversations() async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/archive/all",
            method: .post
        )
    }

    func unarchiveAllConversations() async throws {
        try await network.requestVoid(
            path: "/api/v1/chats/unarchive/all",
            method: .post
        )
    }

    // MARK: - Memories

    func getMemories() async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/memories/")
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        return []
    }

    func addMemory(content: String) async throws -> [String: Any] {
        try await network.requestJSON(
            path: "/api/v1/memories/add",
            method: .post,
            body: ["content": content]
        )
    }

    func updateMemory(id: String, content: String) async throws -> [String: Any] {
        try await network.requestJSON(
            path: "/api/v1/memories/\(id)/update",
            method: .post,
            body: ["content": content]
        )
    }

    func deleteMemory(id: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/memories/\(id)",
            method: .delete
        )
    }

    func resetMemories() async throws {
        try await network.requestVoid(
            path: "/api/v1/memories/delete/user",
            method: .delete
        )
    }

    // MARK: - Title Generation

    /// Generates a title via `POST /api/v1/tasks/title/completions`.
    /// Handles multiple response formats across OpenWebUI versions.
    func generateTitle(model: String, messages: [[String: Any]], chatId: String? = nil) async throws -> String? {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false
        ]
        if let chatId { body["chat_id"] = chatId }

        let json = try await network.requestJSON(
            path: "/api/v1/tasks/title/completions",
            method: .post,
            body: body,
            timeout: 15
        )

        if let title = json["title"] as? String, !title.isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let jsonData = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let parsedTitle = parsed["title"] as? String, !parsedTitle.isEmpty {
                return parsedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
        if let response = json["response"] as? String, !response.isEmpty {
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               let jsonData = trimmed.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let parsedTitle = parsed["title"] as? String {
                return parsedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
        return nil
    }

    // MARK: - Util APIs

    /// Downloads a chat as PDF. Fetches the full conversation from the server
    /// and walks the history tree to get ordered messages in the format
    /// the PDF renderer expects.
    func downloadChatAsPDF(chatId: String) async throws -> Data {
        let (chatData, _) = try await network.requestRaw(path: "/api/v1/chats/\(chatId)")
        guard let chatJson = try JSONSerialization.jsonObject(with: chatData) as? [String: Any] else {
            throw APIError.responseDecoding(underlying: NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid chat data"]), data: chatData)
        }

        let chat = chatJson["chat"] as? [String: Any] ?? [:]
        let title = chat["title"] as? String ?? chatJson["title"] as? String ?? "Chat"

        var orderedMessages: [[String: Any]] = []

        if let history = chat["history"] as? [String: Any],
           let messagesMap = history["messages"] as? [String: [String: Any]],
           let currentId = history["currentId"] as? String {
            var chain: [[String: Any]] = []
            var cursor: String? = currentId
            while let id = cursor, let msg = messagesMap[id] {
                var m = msg
                m["id"] = id
                chain.append(m)
                cursor = msg["parentId"] as? String
            }
            chain.reverse()
            orderedMessages = chain
        } else {
            orderedMessages = chat["messages"] as? [[String: Any]] ?? []
        }

        let safeMessages: [[String: Any]] = orderedMessages.map { msg in
            var m = msg
            if m["content"] == nil || m["content"] is NSNull {
                m["content"] = ""
            }
            return m
        }

        let body: [String: Any] = ["title": title, "messages": safeMessages]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/utils/pdf",
            method: .post,
            body: bodyData,
            timeout: 120
        )
        return data
    }

    // MARK: - AI Note Features

    func generateNoteTitle(content: String, modelId: String) async throws -> String? {
        let prompt = """
        ### Task:
        Generate a concise, 3-5 word title with an emoji summarizing the content in the content's primary language.
        ### Guidelines:
        - The title should clearly represent the main theme or subject of the content.
        - Use emojis that enhance understanding of the topic, but avoid quotation marks or special formatting.
        - Write the title in the content's primary language.
        - Prioritize accuracy over excessive creativity; keep it clear and simple.
        - Your entire response must consist solely of the JSON object, without any introductory or concluding text.
        - The output must be a single, raw JSON object, without any markdown code fences or other encapsulating text.
        ### Output:
        JSON format: { "title": "your concise title here" }
        ### Content:
        <content>
        \(content)
        </content>
        """

        let body: [String: Any] = [
            "model": modelId,
            "stream": false,
            "messages": [["role": "user", "content": prompt]]
        ]

        let json = try await network.requestJSON(
            path: "/api/chat/completions",
            method: .post,
            body: body
        )

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let responseText = message["content"] as? String
        else { return nil }

        if let jsonStart = responseText.range(of: "{"),
           let jsonEnd = responseText.range(of: "}", options: .backwards) {
            let jsonStr = String(responseText[jsonStart.lowerBound...jsonEnd.lowerBound])
            if let data = jsonStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = parsed["title"] as? String {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    func enhanceNoteContent(content: String, modelId: String) async throws -> String? {
        let systemPrompt = """
        Enhance existing notes using the content's primary language. Your task is to make the notes more useful and comprehensive.

        # Output Format

        Provide the enhanced notes in markdown format. Use markdown syntax for headings, lists, task lists ([ ]) where tasks or checklists are strongly implied, and emphasis to improve clarity and presentation. Ensure that all integrated content is accurately reflected. Return only the markdown formatted note.
        """

        let body: [String: Any] = [
            "model": modelId,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "<notes>\(content)</notes>"]
            ]
        ]

        let json = try await network.requestJSON(
            path: "/api/chat/completions",
            method: .post,
            body: body
        )

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let responseText = message["content"] as? String
        else { return nil }

        return responseText
    }

    // MARK: - Private Helpers

    private func parseModelArray(_ models: [[String: Any]]) -> [AIModel] {
        models.compactMap { raw -> AIModel? in
            guard let id = raw["id"] as? String else { return nil }
            let name = raw["name"] as? String ?? id

            var isMultimodal = false
            var supportsRAG = false
            var capabilities: [String: String]?
            var profileImageURL: String?
            var toolIds: [String] = []
            var defaultFeatureIds: [String] = []
            var functionCallingMode: String?
            var builtinTools: [String: Bool] = [:]

            if let info = raw["info"] as? [String: Any] {
                if let meta = info["meta"] as? [String: Any] {
                    profileImageURL = meta["profile_image_url"] as? String
                    if let caps = meta["capabilities"] as? [String: Any] {
                        isMultimodal = caps["vision"] as? Bool ?? false
                        supportsRAG = caps["citations"] as? Bool ?? false
                        capabilities = caps.compactMapValues { "\($0)" }
                    }
                    if let tools = meta["toolIds"] as? [String] {
                        toolIds = tools
                    }
                    if let defaultFeatures = meta["defaultFeatureIds"] as? [String] {
                        defaultFeatureIds = defaultFeatures
                    }
                    // Parse builtinTools — e.g. {"memory":true,"time":true,"web_search":true}
                    if let bt = meta["builtinTools"] as? [String: Any] {
                        for (key, value) in bt {
                            if let boolVal = value as? Bool {
                                builtinTools[key] = boolVal
                            } else if let intVal = value as? Int {
                                builtinTools[key] = intVal != 0
                            }
                        }
                    }
                }
                // Parse function_calling mode from info.params.
                // OpenWebUI stores this as: info.params.function_calling = "native" | ""
                // When "native", the model performs native tool calling.
                // When absent/empty, the server uses its default (non-native) handling.
                if let params = info["params"] as? [String: Any] {
                    if let fc = params["function_calling"] as? String, !fc.isEmpty {
                        functionCallingMode = fc
                    }
                }
            }

            return AIModel(
                id: id,
                name: name,
                description: raw["description"] as? String,
                isMultimodal: isMultimodal,
                supportsStreaming: true,
                supportsRAG: supportsRAG,
                contextLength: raw["context_length"] as? Int,
                capabilities: capabilities,
                profileImageURL: profileImageURL,
                toolIds: toolIds,
                defaultFeatureIds: defaultFeatureIds,
                functionCallingMode: functionCallingMode,
                builtinTools: builtinTools
            )
        }
    }

    private func parseConversationSummary(_ json: [String: Any]) -> Conversation? {
        guard let id = json["id"] as? String else { return nil }
        let title = json["title"] as? String ?? "New Chat"

        var createdAt = Date()
        var updatedAt = Date()
        if let ts = json["created_at"] as? Double { createdAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["created_at"] as? Int { createdAt = Date(timeIntervalSince1970: Double(ts)) }
        if let ts = json["updated_at"] as? Double { updatedAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["updated_at"] as? Int { updatedAt = Date(timeIntervalSince1970: Double(ts)) }

        let pinned = json["pinned"] as? Bool ?? false
        let archived = json["archived"] as? Bool ?? false
        let folderId = json["folder_id"] as? String
        let tags = json["tags"] as? [String] ?? []

        var model: String?
        if let chat = json["chat"] as? [String: Any],
           let models = chat["models"] as? [String],
           let first = models.first {
            model = first
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            pinned: pinned,
            archived: archived,
            folderId: folderId,
            tags: tags
        )
    }

    private func parseFullConversation(_ json: [String: Any]) -> Conversation {
        let id = json["id"] as? String ?? UUID().uuidString
        let title = (json["chat"] as? [String: Any])?["title"] as? String
            ?? json["title"] as? String
            ?? "New Chat"

        var createdAt = Date()
        var updatedAt = Date()
        if let ts = json["created_at"] as? Double { createdAt = Date(timeIntervalSince1970: ts) }
        if let ts = json["updated_at"] as? Double { updatedAt = Date(timeIntervalSince1970: ts) }

        let pinned = json["pinned"] as? Bool ?? false
        let archived = json["archived"] as? Bool ?? false
        let folderId = json["folder_id"] as? String
        let shareId = json["share_id"] as? String
        let tags = json["tags"] as? [String] ?? []

        var model: String?
        var systemPrompt: String?
        var messages: [ChatMessage] = []

        if let chat = json["chat"] as? [String: Any] {
            if let models = chat["models"] as? [String], let first = models.first {
                model = first
            }
            systemPrompt = chat["system"] as? String
            messages = parseMessages(from: chat)
        }

        return Conversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            pinned: pinned,
            archived: archived,
            shareId: shareId,
            folderId: folderId,
            tags: tags
        )
    }

    private func parseMessages(from chat: [String: Any]) -> [ChatMessage] {
        guard let history = chat["history"] as? [String: Any],
              let messagesMap = history["messages"] as? [String: [String: Any]],
              let currentId = history["currentId"] as? String
        else {
            if let msgArray = chat["messages"] as? [[String: Any]] {
                return msgArray.compactMap { parseSingleMessage($0) }
            }
            return []
        }

        // Walk the parent chain from currentId to root, then reverse
        var ordered: [[String: Any]] = []
        var cursor: String? = currentId
        while let id = cursor, let msg = messagesMap[id] {
            var msgWithId = msg
            msgWithId["id"] = id
            ordered.append(msgWithId)
            cursor = msg["parentId"] as? String
        }
        ordered.reverse()

        return ordered.compactMap { msgData -> ChatMessage? in
            guard var message = parseSingleMessage(msgData) else { return nil }

            // Attach sibling versions (OpenWebUI regeneration history)
            let parentId = msgData["parentId"] as? String
            let msgId = msgData["id"] as? String
            let msgRole = msgData["role"] as? String

            if let parentId, !parentId.isEmpty,
               let parent = messagesMap[parentId],
               let childrenIds = parent["childrenIds"] as? [String],
               childrenIds.count > 1 {

                var versions: [ChatMessageVersion] = []
                for siblingId in childrenIds {
                    guard siblingId != msgId,
                          let sibling = messagesMap[siblingId],
                          (sibling["role"] as? String) == msgRole
                    else { continue }

                    if let version = parseSiblingAsVersion(sibling, id: siblingId) {
                        versions.append(version)
                    }
                }

                if !versions.isEmpty {
                    message.versions = versions
                }
            }

            return message
        }
    }

    /// Parses a sibling message (alternative response from regeneration) as a version snapshot.
    private func parseSiblingAsVersion(_ msg: [String: Any], id: String) -> ChatMessageVersion? {
        let content = msg["content"] as? String ?? ""
        var timestamp = Date()
        if let ts = msg["timestamp"] as? Double {
            timestamp = ts > 1_000_000_000_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }
        let model = msg["model"] as? String

        var error: ChatMessageError?
        if let errObj = msg["error"] as? [String: Any] {
            error = ChatMessageError(content: errObj["content"] as? String)
        }

        var files: [ChatMessageFile] = []
        if let rawFiles = msg["files"] as? [[String: Any]] {
            for file in rawFiles {
                let fileType = file["type"] as? String
                let fileUrl = file["url"] as? String ?? file["id"] as? String
                let fileName = file["name"] as? String
                let contentType = file["content_type"] as? String
                    ?? (file["meta"] as? [String: Any])?["content_type"] as? String
                files.append(ChatMessageFile(
                    type: fileType, url: fileUrl, name: fileName, contentType: contentType
                ))
            }
        }

        var sources: [ChatSourceReference] = []
        if let rawSources = msg["sources"] as? [[String: Any]] {
            for src in rawSources {
                let srcUrl = (src["url"] as? String) ?? (src["source"] as? String)
                let srcTitle = (src["name"] as? String) ?? (src["title"] as? String)
                let srcId = src["id"] as? String
                sources.append(ChatSourceReference(id: srcId, title: srcTitle, url: srcUrl))
            }
        }

        let followUps = msg["followUps"] as? [String] ?? msg["follow_ups"] as? [String] ?? []

        return ChatMessageVersion(
            id: id,
            content: content,
            timestamp: timestamp,
            model: model,
            error: error,
            files: files,
            sources: sources,
            followUps: followUps
        )
    }

    private func parseSingleMessage(_ msg: [String: Any]) -> ChatMessage? {
        guard let id = msg["id"] as? String,
              let roleStr = msg["role"] as? String,
              let role = MessageRole(rawValue: roleStr)
        else { return nil }

        let content = msg["content"] as? String ?? ""

        var timestamp = Date()
        if let ts = msg["timestamp"] as? Double {
            // OpenWebUI may send seconds or milliseconds
            timestamp = ts > 1_000_000_000_000
                ? Date(timeIntervalSince1970: ts / 1000)
                : Date(timeIntervalSince1970: ts)
        }

        let model = msg["model"] as? String ?? msg["modelName"] as? String
        let attachmentIds = msg["attachment_ids"] as? [String] ?? []

        var error: ChatMessageError?
        if let errObj = msg["error"] as? [String: Any] {
            error = ChatMessageError(content: errObj["content"] as? String)
        }

        var sources: [ChatSourceReference] = []
        if let rawSources = msg["sources"] as? [[String: Any]] {
            for src in rawSources {
                var baseSource = (src["source"] as? [String: Any]) ?? [:]
                for key in ["id", "name", "title", "url", "link", "type"] {
                    if let value = src[key], baseSource[key] == nil { baseSource[key] = value }
                }

                let metadataRaw = src["metadata"]
                let metadataList: [[String: Any]]
                if let list = metadataRaw as? [[String: Any]] { metadataList = list }
                else if let single = metadataRaw as? [String: Any] { metadataList = [single] }
                else { metadataList = [] }

                let documents = (src["document"] as? [Any]) ?? []
                let loopCount = max(1, max(documents.count, metadataList.count))

                for i in 0..<loopCount {
                    let meta = i < metadataList.count ? metadataList[i] : [:]
                    let document = i < documents.count ? documents[i] : nil

                    var url: String?
                    for k in ["source", "url", "link"] {
                        if let v = meta[k] as? String, v.hasPrefix("http") { url = v; break }
                    }
                    if url == nil, let v = baseSource["url"] as? String, v.hasPrefix("http") { url = v }

                    let title: String? = (meta["name"] as? String) ?? (meta["title"] as? String)
                        ?? (baseSource["name"] as? String) ?? (baseSource["title"] as? String)

                    let snippet: String? = (document as? String)?.trimmingCharacters(in: .whitespaces)
                    let srcId = (meta["source"] as? String) ?? (meta["id"] as? String) ?? (baseSource["id"] as? String)

                    let isDuplicate = sources.contains { ($0.url != nil && $0.url == url) || ($0.id != nil && $0.id == srcId) }
                    if !isDuplicate {
                        var metaDict: [String: String] = [:]
                        for (k, v) in meta { if let s = v as? String { metaDict[k] = s } }

                        sources.append(ChatSourceReference(
                            id: srcId, title: title, url: url,
                            snippet: (snippet?.isEmpty ?? true) ? nil : snippet,
                            type: (baseSource["type"] as? String) ?? (meta["type"] as? String),
                            metadata: metaDict.isEmpty ? nil : metaDict
                        ))
                    }
                }
            }
        }

        let followUps = msg["followUps"] as? [String] ?? msg["follow_ups"] as? [String] ?? []

        var files: [ChatMessageFile] = []
        if let rawFiles = msg["files"] as? [[String: Any]] {
            for file in rawFiles {
                let fileType = file["type"] as? String
                let fileUrl = file["url"] as? String ?? file["id"] as? String
                let fileName = file["name"] as? String
                let contentType = file["content_type"] as? String
                    ?? (file["meta"] as? [String: Any])?["content_type"] as? String
                files.append(ChatMessageFile(
                    type: fileType, url: fileUrl, name: fileName, contentType: contentType
                ))
            }
        }

        return ChatMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            model: model,
            attachmentIds: attachmentIds,
            files: files,
            sources: sources,
            followUps: followUps,
            error: error
        )
    }

    private func buildChatPayload(
        title: String,
        messages: [ChatMessage],
        model: String?,
        systemPrompt: String?
    ) -> [String: Any] {
        var messagesMap: [String: Any] = [:]
        var messagesArray: [[String: Any]] = []
        var previousId: String?
        var lastUserId: String?
        var currentId: String?

        for msg in messages {
            let parentId: String?
            if msg.role == .assistant {
                parentId = lastUserId ?? previousId
            } else {
                parentId = previousId
            }

            var msgDict: [String: Any] = [
                "id": msg.id,
                "parentId": (parentId as Any?) ?? NSNull(),
                "childrenIds": [String](),
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": Int(msg.timestamp.timeIntervalSince1970)
            ]

            if msg.role == .assistant {
                if let m = msg.model { msgDict["model"] = m; msgDict["modelName"] = m }
                msgDict["modelIdx"] = 0
                msgDict["done"] = true
            }

            if msg.role == .user, let m = model {
                msgDict["models"] = [m]
            }

            if !msg.files.isEmpty {
                let filesArray: [[String: Any]] = msg.files.compactMap { file -> [String: Any]? in
                    guard let url = file.url else { return nil }
                    var dict: [String: Any] = [
                        "type": file.type ?? "file",
                        "id": url,
                        "url": url
                    ]
                    if let name = file.name { dict["name"] = name }
                    if let ct = file.contentType { dict["content_type"] = ct }
                    return dict
                }
                if !filesArray.isEmpty { msgDict["files"] = filesArray }
            } else if !msg.attachmentIds.isEmpty {
                let filesArray: [[String: Any]] = msg.attachmentIds.map { id in
                    ["type": "file", "id": id, "url": id, "name": "file"]
                }
                msgDict["files"] = filesArray
            }

            // Sources must be preserved on sync so they survive reload from server.
            if !msg.sources.isEmpty {
                let sourcesArray: [[String: Any]] = msg.sources.map { source in
                    var dict: [String: Any] = [:]
                    if let id = source.id { dict["id"] = id }
                    if let title = source.title { dict["name"] = title }
                    if let url = source.url { dict["url"] = url; dict["source"] = url }
                    if let snippet = source.snippet { dict["snippet"] = snippet }
                    if let type = source.type { dict["type"] = type }
                    if let meta = source.metadata {
                        var metaDict: [String: Any] = [:]
                        for (k, v) in meta { metaDict[k] = v }
                        if !metaDict.isEmpty { dict["metadata"] = [metaDict] }
                    }
                    // `document` array is required — the web client crashes if it's missing.
                    if let snippet = source.snippet, !snippet.isEmpty {
                        dict["document"] = [snippet]
                    } else {
                        dict["document"] = [] as [String]
                    }
                    return dict
                }
                msgDict["sources"] = sourcesArray
            }

            if !msg.followUps.isEmpty {
                msgDict["followUps"] = msg.followUps
            }

            if let error = msg.error {
                if let content = error.content {
                    msgDict["error"] = ["content": content]
                } else {
                    msgDict["error"] = ["content": ""]
                }
            }

            messagesMap[msg.id] = msgDict

            // Write version siblings into the history tree BEFORE the current message.
            // OpenWebUI stores regeneration history as siblings: multiple children of
            // the same parent with the same role. The active message must be LAST in
            // childrenIds so the web UI shows it as the current version (N/N).
            if !msg.versions.isEmpty, let pid = parentId {
                for version in msg.versions {
                    let siblingId = version.id
                    guard messagesMap[siblingId] == nil else { continue }

                    var siblingDict: [String: Any] = [
                        "id": siblingId,
                        "parentId": pid,
                        "childrenIds": [String](),
                        "role": msg.role.rawValue,
                        "content": version.content,
                        "timestamp": Int(version.timestamp.timeIntervalSince1970),
                        "done": true
                    ]

                    if let m = version.model ?? msg.model {
                        siblingDict["model"] = m
                        siblingDict["modelName"] = m
                    }
                    if msg.role == .assistant {
                        siblingDict["modelIdx"] = 0
                    }

                    if !version.files.isEmpty {
                        let filesArr: [[String: Any]] = version.files.compactMap { file -> [String: Any]? in
                            guard let url = file.url else { return nil }
                            var dict: [String: Any] = ["type": file.type ?? "file", "id": url, "url": url]
                            if let name = file.name { dict["name"] = name }
                            if let ct = file.contentType { dict["content_type"] = ct }
                            return dict
                        }
                        if !filesArr.isEmpty { siblingDict["files"] = filesArr }
                    }

                    if !version.sources.isEmpty {
                        let sourcesArr: [[String: Any]] = version.sources.map { source in
                            var dict: [String: Any] = [:]
                            if let id = source.id { dict["id"] = id }
                            if let title = source.title { dict["name"] = title }
                            if let url = source.url { dict["url"] = url; dict["source"] = url }
                            if let snippet = source.snippet { dict["snippet"] = snippet }
                            if let type = source.type { dict["type"] = type }
                            if let meta = source.metadata {
                                var metaDict: [String: Any] = [:]
                                for (k, v) in meta { metaDict[k] = v }
                                if !metaDict.isEmpty { dict["metadata"] = [metaDict] }
                            }
                            return dict
                        }
                        siblingDict["sources"] = sourcesArr
                    }

                    if !version.followUps.isEmpty {
                        siblingDict["followUps"] = version.followUps
                    }

                    if let error = version.error, let content = error.content {
                        siblingDict["error"] = ["content": content]
                    }

                    messagesMap[siblingId] = siblingDict

                    if var parent = messagesMap[pid] as? [String: Any] {
                        var children = parent["childrenIds"] as? [String] ?? []
                        if !children.contains(siblingId) {
                            children.append(siblingId)
                            parent["childrenIds"] = children
                            messagesMap[pid] = parent
                        }
                    }
                }
            }

            // Add the active message LAST so it's shown as current (N/N) on the web UI.
            if let pid = parentId, var parent = messagesMap[pid] as? [String: Any] {
                var children = parent["childrenIds"] as? [String] ?? []
                children.append(msg.id)
                parent["childrenIds"] = children
                messagesMap[pid] = parent
            }

            messagesArray.append(msgDict)
            previousId = msg.id
            currentId = msg.id
            if msg.role == .user { lastUserId = msg.id }
        }

        var chat: [String: Any] = [
            "id": "",
            "title": title,
            "models": model.map { [$0] } ?? [],
            "params": [String: Any](),
            "history": [
                "messages": messagesMap,
                "currentId": (currentId as Any?) ?? NSNull()
            ],
            "messages": messagesArray,
            "tags": [String](),
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]

        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            chat["system"] = systemPrompt
        }

        return chat
    }

    // MARK: - Task Configuration & AI Tasks

    /// Fetches server task config (title generation, follow-ups, tags, etc.)
    /// so the app can respect admin-disabled tasks.
    func getTaskConfig() async throws -> TaskConfig {
        let json = try await network.requestJSON(path: "/api/v1/tasks/config")
        return TaskConfig(from: json)
    }

    /// Checks which of the given chat IDs have active (in-progress) tasks on the server.
    func checkActiveChats(chatIds: [String]) async throws -> Set<String> {
        guard !chatIds.isEmpty else { return [] }
        let json = try await network.requestJSON(
            path: "/api/v1/tasks/active/chats",
            method: .post,
            body: ["chat_ids": chatIds]
        )
        if let activeIds = json["chat_ids"] as? [String] {
            return Set(activeIds)
        }
        var active = Set<String>()
        for (key, value) in json {
            if let isActive = value as? Bool, isActive {
                active.insert(key)
            }
        }
        return active
    }

    func generateAutocompletion(
        model: String,
        messages: [[String: Any]],
        prompt: String
    ) async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "prompt": prompt,
            "stream": false
        ]

        let json = try await network.requestJSON(
            path: "/api/v1/tasks/auto/completions",
            method: .post,
            body: body,
            timeout: 10
        )

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let content = json["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    func generateEmoji(model: String, prompt: String) async throws -> String? {
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]

        let json = try await network.requestJSON(
            path: "/api/v1/tasks/emoji/completions",
            method: .post,
            body: body,
            timeout: 10
        )

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let content = json["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    func getArchivedChats(
        page: Int = 1,
        query: String? = nil,
        orderBy: String? = nil,
        direction: String? = nil
    ) async throws -> [Conversation] {
        var queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "order_by", value: orderBy))
        }
        if let direction {
            queryItems.append(URLQueryItem(name: "direction", value: direction))
        }
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/archived",
            queryItems: queryItems
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { parseConversationSummary($0) }.map { conv in
            var archived = conv
            archived.archived = true
            return archived
        }
    }

    // MARK: - Admin APIs

    func getAdminUsers(
        page: Int = 1,
        query: String? = nil,
        orderBy: String? = nil,
        direction: String? = nil
    ) async throws -> [AdminUser] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)")
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "order_by", value: orderBy))
        }
        if let direction {
            queryItems.append(URLQueryItem(name: "direction", value: direction))
        }

        let capturedQueryItems = queryItems
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/users/",
            queryItems: capturedQueryItems
        )

        let decoder = JSONDecoder()

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usersArray = json["users"] {
            let usersData = try JSONSerialization.data(withJSONObject: usersArray)
            if let users = try? decoder.decode([AdminUser].self, from: usersData) {
                return users
            }
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let usersArray = json["data"] {
            let usersData = try JSONSerialization.data(withJSONObject: usersArray)
            if let users = try? decoder.decode([AdminUser].self, from: usersData) {
                return users
            }
        }

        if let users = try? decoder.decode([AdminUser].self, from: data) {
            return users
        }

        if let rawString = String(data: data, encoding: .utf8) {
            logger.error("Failed to decode admin users. Raw response (first 500 chars): \(String(rawString.prefix(500)))")
        }
        return []
    }

    func getAdminUserById(_ userId: String) async throws -> AdminUser {
        let (data, _) = try await network.requestRaw(path: "/api/v1/users/\(userId)")
        return try JSONDecoder().decode(AdminUser.self, from: data)
    }

    func updateAdminUser(userId: String, form: AdminUserUpdateForm) async throws -> AdminUser {
        let formData = try JSONEncoder().encode(form)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/users/\(userId)/update",
            method: .post,
            body: formData
        )
        return try JSONDecoder().decode(AdminUser.self, from: data)
    }

    func deleteAdminUser(userId: String) async throws {
        try await network.requestVoid(path: "/api/v1/users/\(userId)", method: .delete)
    }

    /// Bypasses standard `requestRaw` to avoid mapping 401 → tokenExpired (logout).
    /// Provides admin-specific error messages instead.
    func getAdminChatById(chatId: String) async throws -> Conversation {
        let request = try network.buildRequest(
            path: "/api/v1/chats/share/\(chatId)",
            method: .get,
            authenticated: true
        )
        let (data, response) = try await network.session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            if statusCode == 401 || statusCode == 403 {
                throw APIError.httpError(
                    statusCode: statusCode,
                    message: "Unable to access this chat. Ensure admin chat access is enabled on your server (Settings → Admin → Enable Admin Chat Access).",
                    data: data
                )
            }
            if !(200..<400).contains(statusCode) {
                var message: String?
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    message = json["detail"] as? String ?? json["error"] as? String
                }
                throw APIError.httpError(
                    statusCode: statusCode,
                    message: message ?? "Failed to load chat (HTTP \(statusCode)).",
                    data: data
                )
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.httpError(statusCode: 500, message: "Unable to parse chat data.", data: data)
        }

        return parseFullConversation(json)
    }

    func deleteAdminChat(chatId: String) async throws {
        let request = try network.buildRequest(
            path: "/api/v1/chats/\(chatId)",
            method: .delete,
            authenticated: true
        )
        let (data, response) = try await network.session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            let statusCode = httpResponse.statusCode
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["detail"] as? String ?? json["error"] as? String
            }
            throw APIError.httpError(
                statusCode: statusCode,
                message: message ?? "Failed to delete chat.",
                data: data
            )
        }
    }

    func cloneAdminChat(chatId: String) async throws -> Conversation {
        let request = try network.buildRequest(
            path: "/api/v1/chats/\(chatId)/clone/shared",
            method: .post,
            authenticated: true
        )
        let (data, response) = try await network.session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            let statusCode = httpResponse.statusCode
            var message: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                message = json["detail"] as? String ?? json["error"] as? String
            }
            throw APIError.httpError(
                statusCode: statusCode,
                message: message ?? "Failed to clone chat.",
                data: data
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.httpError(statusCode: 500, message: "Failed to parse cloned chat.", data: data)
        }

        return parseFullConversation(json)
    }

    func getAdminUserChats(
        userId: String,
        page: Int = 1,
        query: String? = nil,
        orderBy: String? = nil,
        direction: String? = nil
    ) async throws -> [AdminChatItem] {
        var queryItems: [URLQueryItem] = []
        queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        if let orderBy {
            queryItems.append(URLQueryItem(name: "order_by", value: orderBy))
        }
        if let direction {
            queryItems.append(URLQueryItem(name: "direction", value: direction))
        }

        let capturedQueryItems = queryItems
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/chats/list/user/\(userId)",
            queryItems: capturedQueryItems
        )

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { json -> AdminChatItem? in
            guard let id = json["id"] as? String,
                  let title = json["title"] as? String else { return nil }
            let updatedAt: Int
            if let ts = json["updated_at"] as? Int { updatedAt = ts }
            else if let ts = json["updated_at"] as? Double { updatedAt = Int(ts) }
            else { updatedAt = 0 }
            let createdAt: Int
            if let ts = json["created_at"] as? Int { createdAt = ts }
            else if let ts = json["created_at"] as? Double { createdAt = Int(ts) }
            else { createdAt = 0 }
            return AdminChatItem(id: id, title: title, updatedAt: updatedAt, createdAt: createdAt)
        }
    }

    // MARK: - Channels

    /// Fetches channels accessible to the current user.
    func getChannels() async throws -> [Channel] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/channels/")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { Channel.fromJSON($0) }
    }

    /// Fetches all channels (admin endpoint).
    func getAllChannels() async throws -> [Channel] {
        let (data, _) = try await network.requestRaw(path: "/api/v1/channels/list")
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { Channel.fromJSON($0) }
    }

    /// Fetches full channel details by ID.
    func getChannel(id: String) async throws -> Channel {
        let (data, _) = try await network.requestRaw(path: "/api/v1/channels/\(id)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = Channel.fromJSON(json) else {
            throw APIError.responseDecoding(
                underlying: NSError(domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode channel"]),
                data: data
            )
        }
        return channel
    }

    /// Creates a new channel.
    /// Matches `CreateChannelForm` schema and web UI wire format:
    /// - Standard: type="" (empty string), is_private=null
    /// - DM: type="dm", is_private=null
    /// - Group: type="group", is_private=true/false
    func createChannel(
        name: String,
        description: String? = nil,
        type: String = "",
        isPrivate: Bool? = nil,
        data channelData: [String: Any]? = nil,
        meta: [String: Any]? = nil,
        accessGrants: [[String: Any]]? = nil,
        groupIds: [String]? = nil,
        userIds: [String]? = nil
    ) async throws -> Channel {
        var body: [String: Any] = ["name": name, "type": type]
        if let description { body["description"] = description }
        // Only include is_private when explicitly set — null matches web UI default
        if let isPrivate { body["is_private"] = isPrivate }
        if let channelData { body["data"] = channelData }
        if let meta { body["meta"] = meta }
        
        // Server requires these arrays to be present (even empty) for DM/Group types.
        // Match the exact web UI payload: {"type":"dm","name":"","is_private":null,"access_grants":[],"group_ids":[],"user_ids":["..."]}
        body["access_grants"] = accessGrants ?? []
        body["group_ids"] = groupIds ?? []
        body["user_ids"] = userIds ?? []

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/create",
            method: .post,
            body: bodyData
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = Channel.fromJSON(json) else {
            throw APIError.responseDecoding(
                underlying: NSError(domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode created channel"]),
                data: data
            )
        }
        return channel
    }

    /// Updates a channel.
    func updateChannel(id: String, name: String? = nil, description: String? = nil, isPrivate: Bool? = nil, data channelData: [String: Any]? = nil, accessControl: [String: Any]? = nil, accessGrants: [[String: Any]]? = nil) async throws -> Channel {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let description { body["description"] = description }
        if let isPrivate { body["is_private"] = isPrivate }
        if let channelData { body["data"] = channelData }
        if let accessControl { body["access_control"] = accessControl }
        if let accessGrants { body["access_grants"] = accessGrants }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(id)/update",
            method: .post,
            body: bodyData
        )
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = Channel.fromJSON(json) else {
            throw APIError.responseDecoding(
                underlying: NSError(domain: "APIError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode updated channel"]),
                data: data
            )
        }
        return channel
    }

    /// Deletes a channel.
    func deleteChannel(id: String) async throws {
        try await network.requestVoid(path: "/api/v1/channels/\(id)/delete", method: .delete)
    }

    /// Gets or creates a DM channel with the specified user.
    func getDMChannel(userId: String) async throws -> Channel? {
        let (data, _) = try await network.requestRaw(path: "/api/v1/channels/users/\(userId)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Channel.fromJSON(json)
    }

    // MARK: - Channel Members

    /// Fetches members of a channel with pagination.
    /// API returns `UserListResponse`: `{users: UserModelResponse[], total: int}`
    func getChannelMembers(id: String, query: String? = nil, page: Int = 1) async throws -> [ChannelMember] {
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "page", value: "\(page)")]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(id)/members",
            queryItems: queryItems
        )
        // UserListResponse schema: {users: [...], total: N}
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let usersArray = json["users"] as? [[String: Any]] {
                return usersArray.compactMap { ChannelMember.fromJSON($0) }
            }
            // Fallback: try "data" wrapper
            if let usersArray = json["data"] as? [[String: Any]] {
                return usersArray.compactMap { ChannelMember.fromJSON($0) }
            }
        }
        // Fallback: direct array
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { ChannelMember.fromJSON($0) }
        }
        return []
    }

    /// Adds members to a channel.
    func addChannelMembers(id: String, userIds: [String]) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/channels/\(id)/update/members/add",
            method: .post,
            body: ["user_ids": userIds]
        )
    }

    /// Removes members from a channel.
    func removeChannelMembers(id: String, userIds: [String]) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/channels/\(id)/update/members/remove",
            method: .post,
            body: ["user_ids": userIds]
        )
    }

    /// Updates a member's active status in a channel.
    func updateMemberActiveStatus(channelId: String, isActive: Bool) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/channels/\(channelId)/members/active",
            method: .post,
            body: ["is_active": isActive]
        )
    }

    // MARK: - Channel Messages

    /// Fetches channel messages with pagination.
    func getChannelMessages(id: String, skip: Int = 0, limit: Int = 50) async throws -> [ChannelMessage] {
        let queryItems = [
            URLQueryItem(name: "skip", value: "\(skip)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(id)/messages",
            queryItems: queryItems
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { ChannelMessage.fromJSON($0) }
    }

    /// Posts a new message to a channel.
    func postChannelMessage(
        channelId: String,
        content: String,
        replyToId: String? = nil,
        parentId: String? = nil,
        data msgData: [String: Any]? = nil
    ) async throws -> ChannelMessage? {
        var body: [String: Any] = ["content": content]
        if let replyToId { body["reply_to_id"] = replyToId }
        if let parentId { body["parent_id"] = parentId }
        if let msgData { body["data"] = msgData }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/messages/post",
            method: .post,
            body: bodyData
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ChannelMessage.fromJSON(json)
    }

    /// Gets a single channel message.
    func getChannelMessage(channelId: String, messageId: String) async throws -> ChannelMessage? {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)"
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ChannelMessage.fromJSON(json)
    }

    /// Gets message data/metadata.
    func getChannelMessageData(channelId: String, messageId: String) async throws -> [String: Any]? {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)/data"
        )
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Updates a channel message.
    func updateChannelMessage(channelId: String, messageId: String, content: String, data msgData: [String: Any]? = nil) async throws -> ChannelMessage? {
        var body: [String: Any] = ["content": content]
        if let msgData { body["data"] = msgData }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)/update",
            method: .post,
            body: bodyData
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ChannelMessage.fromJSON(json)
    }

    /// Deletes a channel message.
    func deleteChannelMessage(channelId: String, messageId: String) async throws {
        try await network.requestVoid(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)/delete",
            method: .delete
        )
    }

    /// Pins or unpins a channel message.
    func pinChannelMessage(channelId: String, messageId: String, isPinned: Bool) async throws -> ChannelMessage? {
        let bodyData = try JSONSerialization.data(withJSONObject: ["is_pinned": isPinned])
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)/pin",
            method: .post,
            body: bodyData
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ChannelMessage.fromJSON(json)
    }

    /// Gets pinned messages for a channel.
    func getPinnedChannelMessages(channelId: String, page: Int = 1) async throws -> [ChannelMessage] {
        let queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/messages/pinned",
            queryItems: queryItems
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { ChannelMessage.fromJSON($0) }
    }

    // MARK: - Channel Threads

    /// Gets thread replies for a message.
    func getChannelThreadMessages(channelId: String, messageId: String, skip: Int = 0, limit: Int = 50) async throws -> [ChannelMessage] {
        let queryItems = [
            URLQueryItem(name: "skip", value: "\(skip)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)/thread",
            queryItems: queryItems
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { ChannelMessage.fromJSON($0) }
    }

    // MARK: - Channel Reactions

    /// Adds an emoji reaction to a message.
    func addChannelReaction(channelId: String, messageId: String, emoji: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)/reactions/add",
            method: .post,
            body: ["name": emoji]
        )
    }

    /// Removes an emoji reaction from a message.
    func removeChannelReaction(channelId: String, messageId: String, emoji: String) async throws {
        try await network.requestVoidJSON(
            path: "/api/v1/channels/\(channelId)/messages/\(messageId)/reactions/remove",
            method: .post,
            body: ["name": emoji]
        )
    }

    // MARK: - Channel Webhooks

    /// Gets webhooks for a channel.
    func getChannelWebhooks(channelId: String) async throws -> [[String: Any]] {
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/channels/\(channelId)/webhooks"
        )
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    /// Searches users (for @mention picker and access management).
    func searchUsers(query: String? = nil, page: Int = 1) async throws -> [ChannelMember] {
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "page", value: "\(page)")]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        let (data, _) = try await network.requestRaw(
            path: "/api/v1/users/search",
            queryItems: queryItems
        )
        // Server returns: {"users": [...], "total": N}
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let usersArray = json["users"] as? [[String: Any]] {
                return usersArray.compactMap { ChannelMember.fromJSON($0) }
            }
            if let usersArray = json["data"] as? [[String: Any]] {
                return usersArray.compactMap { ChannelMember.fromJSON($0) }
            }
        }
        // Fallback: direct array
        if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { ChannelMember.fromJSON($0) }
        }
        return []
    }

    func addAdminUser(form: AdminAddUserForm) async throws -> AdminUser {
        let formData = try JSONEncoder().encode(form)
        guard let formDict = try JSONSerialization.jsonObject(with: formData) as? [String: Any] else {
            throw APIError.unknown(underlying: NSError(domain: "APIError", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode add user form"]))
        }

        let response = try await network.requestJSON(
            path: "/api/v1/auths/add",
            method: .post,
            body: formDict
        )

        let jsonData = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(AdminUser.self, from: jsonData)
    }
}

// MARK: - Redirect Capturing Delegate

/// URLSessionDelegate that captures the final URL after all redirects.
/// Used to detect HTTP→HTTPS upgrades performed by a load balancer so
/// the app can update the stored server URL to the correct HTTPS address.
private final class RedirectCapturingDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowSelfSigned: Bool
    private let serverConfig: ServerConfig
    private let lock = NSLock()
    private var _finalURL: URL?

    var finalURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _finalURL
    }

    init(allowSelfSigned: Bool, serverConfig: ServerConfig) {
        self.allowSelfSigned = allowSelfSigned
        self.serverConfig = serverConfig
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Capture the redirect destination URL
        lock.lock()
        _finalURL = request.url
        lock.unlock()
        // Allow the redirect to proceed
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard allowSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let baseURL = URL(string: serverConfig.url),
              challenge.protectionSpace.host.lowercased() == baseURL.host?.lowercased()
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
