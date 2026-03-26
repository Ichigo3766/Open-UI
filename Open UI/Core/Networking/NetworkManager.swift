import Foundation
import os.log

/// Handles low-level HTTP networking — authentication, multipart uploads, and SSE streaming.
final class NetworkManager: NSObject, Sendable {
    let serverConfig: ServerConfig
    private let keychain: KeychainService
    private let logger = Logger(subsystem: "com.openui", category: "Network")

    let session: URLSession
    private let certificateDelegate: CertificateTrustDelegate?

    var baseURL: URL? { serverConfig.apiBaseURL }

    var authToken: String? {
        keychain.getToken(forServer: serverConfig.url)
    }

    // MARK: - Initialisation

    init(serverConfig: ServerConfig, keychain: KeychainService = .shared) {
        self.serverConfig = serverConfig
        self.keychain = keychain

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true

        // Disable URLSession HTTP caching — the app is API-driven with its own
        // ImageCacheService, and the default URLCache causes unbounded disk growth.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Explicitly set the cookie storage so cf_clearance cookies injected
        // via HTTPCookieStorage.shared are sent on every request.
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true

        // Re-inject persisted cf_clearance cookie on startup. Session cookies
        // (no expiry) vanish when the app is terminated — we persist the value
        // in ServerConfig and re-create the cookie here with the saved expiry.
        if serverConfig.isCloudflareBotProtected,
           let cfValue = serverConfig.cfClearanceValue, !cfValue.isEmpty,
           let cfExpiry = serverConfig.cfClearanceExpiry, cfExpiry > Date() {
            if let url = URL(string: serverConfig.url), let host = url.host {
                let cookieProperties: [HTTPCookiePropertyKey: Any] = [
                    .name: "cf_clearance",
                    .value: cfValue,
                    .domain: host,
                    .path: "/",
                    .secure: url.scheme == "https" ? "TRUE" : "FALSE",
                    .expires: cfExpiry
                ]
                if let cookie = HTTPCookie(properties: cookieProperties) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                    logger.info("☁️ Re-injected persisted cf_clearance cookie for \(host) (expires \(cfExpiry))")
                }
            }
        }

        // Re-inject persisted auth proxy cookies on startup (Authelia, Authentik, etc.).
        // These are session cookies with no expiry — they vanish when the app terminates,
        // so we persist the values in ServerConfig and re-create them here on every launch.
        if serverConfig.isAuthProxyProtected,
           let proxyAuthCookies = serverConfig.proxyAuthCookies,
           !proxyAuthCookies.isEmpty,
           let url = URL(string: serverConfig.url),
           let host = url.host {
            for (name, value) in proxyAuthCookies {
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
            logger.info("🔐 Re-injected \(proxyAuthCookies.count) persisted proxy auth cookie(s) for \(host)")
        }

        var headers = configuration.httpAdditionalHeaders ?? [:]
        for (key, value) in serverConfig.customHeaders {
            headers[key] = value
        }
        configuration.httpAdditionalHeaders = headers

        if serverConfig.allowSelfSignedCertificates {
            let delegate = CertificateTrustDelegate(serverConfig: serverConfig)
            self.certificateDelegate = delegate
            self.session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
        } else {
            self.certificateDelegate = nil
            self.session = URLSession(configuration: configuration)
        }

        super.init()
    }

    // MARK: - Request Building

    func buildRequest(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String? = "application/json",
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard let baseURL else {
            throw APIError.invalidURL(serverConfig.url)
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + path
        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL(components.string ?? path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body

        if let timeout {
            request.timeoutInterval = timeout
        }

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if authenticated, let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        for (key, value) in serverConfig.customHeaders {
            let lower = key.lowercased()
            if lower != "authorization" && lower != "content-type" && lower != "accept" {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return request
    }

    // MARK: - Simple Requests

    func request<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Encodable? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let bodyData: Data?
        if let body {
            do {
                bodyData = try JSONEncoder().encode(body)
            } catch {
                throw APIError.requestEncoding(underlying: error)
            }
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequest(urlRequest)
        try validateHTTPResponse(response, data: data)

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.responseDecoding(underlying: error, data: data)
        }
    }

    func requestRaw(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        contentType: String? = "application/json",
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            contentType: contentType,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequest(urlRequest)
        try validateHTTPResponse(response, data: data)
        return (data, response as! HTTPURLResponse)
    }

    func requestVoid(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: Encodable? = nil,
        authenticated: Bool = true
    ) async throws {
        let bodyData: Data?
        if let body {
            bodyData = try JSONEncoder().encode(body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated
        )

        let (data, response) = try await performRequest(urlRequest)
        try validateHTTPResponse(response, data: data)
    }

    func requestVoidJSON(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated
        )

        let (data, response) = try await performRequest(urlRequest)
        try validateHTTPResponse(response, data: data)
    }

    func requestJSON(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequest(urlRequest)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected JSON object"]
                ),
                data: data
            )
        }
        return json
    }

    func requestJSONArray(
        path: String,
        method: HTTPMethod = .get,
        queryItems: [URLQueryItem]? = nil,
        body: [String: Any]? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> [[String: Any]] {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        let urlRequest = try buildRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            body: bodyData,
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequest(urlRequest)
        try validateHTTPResponse(response, data: data)

        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected JSON array"]
                ),
                data: data
            )
        }
        return arr
    }

    // MARK: - Streaming (SSE)

    /// Opens an SSE streaming connection. Uses a dedicated session with extended timeouts
    /// so pauses during tool execution don't kill the connection.
    func streamRequestBytes(
        path: String,
        method: HTTPMethod = .post,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> SSEStream {
        let bodyData: Data?
        if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } else {
            bodyData = nil
        }

        var urlRequest = try buildRequest(
            path: path,
            method: method,
            body: bodyData,
            authenticated: authenticated,
            timeout: 300
        )
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let streamSession = makeStreamingSession()
        let (bytes, response) = try await streamSession.bytes(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<400).contains(httpResponse.statusCode) {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 4096 { break }
            }
            throw parseHTTPError(statusCode: httpResponse.statusCode, data: errorBody)
        }

        return SSEStream(bytes: bytes)
    }

    /// Lock-protected lazy streaming session. Reused across all SSE requests to prevent leaks.
    private let _streamingSessionLock = NSLock()
    private var _streamingSessionBacking: URLSession?
    private var _streamingSession: URLSession {
        _streamingSessionLock.lock()
        defer { _streamingSessionLock.unlock() }
        if let existing = _streamingSessionBacking { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Allow cookie jar so cf_clearance is auto-sent (same as main session above)
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true

        var headers = config.httpAdditionalHeaders ?? [:]
        for (key, value) in serverConfig.customHeaders {
            headers[key] = value
        }
        config.httpAdditionalHeaders = headers

        let newSession: URLSession
        if serverConfig.allowSelfSignedCertificates, let delegate = certificateDelegate {
            newSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        } else {
            newSession = URLSession(configuration: config)
        }
        _streamingSessionBacking = newSession
        return newSession
    }

    private func makeStreamingSession() -> URLSession {
        _streamingSession
    }

    // MARK: - Multipart Form Data Upload

    func uploadMultipart(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        fileData: Data,
        fileName: String,
        mimeType: String,
        fieldName: String = "file",
        additionalFields: [String: String]? = nil,
        authenticated: Bool = true,
        timeout: TimeInterval? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> [String: Any] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        if let fields = additionalFields {
            for (key, value) in fields {
                body.append(Data("--\(boundary)\r\n".utf8))
                body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
                body.append(Data("\(value)\r\n".utf8))
            }
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        let urlRequest = try buildRequest(
            path: path,
            method: .post,
            queryItems: queryItems,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authenticated: authenticated,
            timeout: timeout
        )

        let (data, response) = try await performRequest(urlRequest)
        try validateHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.responseDecoding(
                underlying: NSError(
                    domain: "APIError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected JSON response from upload"]
                ),
                data: data
            )
        }
        return json
    }

    // MARK: - Auth Token Management

    @discardableResult
    func saveAuthToken(_ token: String) -> Bool {
        keychain.saveToken(token, forServer: serverConfig.url)
    }

    @discardableResult
    func deleteAuthToken() -> Bool {
        keychain.deleteToken(forServer: serverConfig.url)
    }

    // MARK: - Internal Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw APIError.from(error)
        }
    }

    /// Retries up to `maxRetries` times with exponential backoff for network errors and 5xx responses.
    /// Does not retry 4xx, cancelled requests, or SSL errors.
    func performRequestWithRetry(
        _ request: URLRequest,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 0.5
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await performRequest(request)

                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode >= 500 && attempt < maxRetries {
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    logger.warning("Server error \(httpResponse.statusCode) on attempt \(attempt + 1)/\(maxRetries + 1), retrying in \(delay)s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = parseHTTPError(statusCode: httpResponse.statusCode, data: data)
                    continue
                }

                return (data, response)
            } catch {
                lastError = error
                let apiError = APIError.from(error)

                guard apiError.isRetryable, attempt < maxRetries else {
                    throw error
                }

                let delay = baseDelay * pow(2.0, Double(attempt))
                logger.warning("Request failed (attempt \(attempt + 1)/\(maxRetries + 1)): \(apiError.localizedDescription), retrying in \(delay)s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? APIError.unknown(underlying: nil)
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        let statusCode = httpResponse.statusCode

        if [302, 307, 308].contains(statusCode) {
            let location = httpResponse.value(forHTTPHeaderField: "Location")
            throw APIError.redirectDetected(location: location)
        }

        guard (200..<400).contains(statusCode) else {
            throw parseHTTPError(statusCode: statusCode, data: data)
        }
    }

    private func parseHTTPError(statusCode: Int, data: Data) -> APIError {
        if statusCode == 401 {
            return .tokenExpired
        }

        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            message = json["detail"] as? String
                ?? json["error"] as? String
                ?? json["message"] as? String
        }
        if message == nil {
            message = String(data: data, encoding: .utf8)
        }

        return .httpError(statusCode: statusCode, message: message, data: data)
    }
}

// MARK: - HTTP Method

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - Certificate Trust Delegate

/// SSL delegate for self-signed certificate support. Extracted so `session` can be a `let`.
private final class CertificateTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    let serverConfig: ServerConfig

    init(serverConfig: ServerConfig) {
        self.serverConfig = serverConfig
        super.init()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard serverConfig.allowSelfSignedCertificates,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let baseURL = URL(string: serverConfig.url),
              challenge.protectionSpace.host.lowercased() == baseURL.host?.lowercased()
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if let configPort = baseURL.port,
           challenge.protectionSpace.port != configPort {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let credential = URLCredential(trust: serverTrust)
        completionHandler(.useCredential, credential)
    }
}
