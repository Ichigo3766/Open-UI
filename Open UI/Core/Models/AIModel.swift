import Foundation

/// Metadata about an AI model available on an OpenWebUI server.
struct AIModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String?
    var isMultimodal: Bool
    var supportsStreaming: Bool
    var supportsRAG: Bool
    var contextLength: Int?
    var capabilities: [String: String]?
    var profileImageURL: String?
    var toolIds: [String]
    /// Feature IDs that should be enabled by default for this model.
    /// Set by admin in the model editor (e.g., `["web_search", "image_generation"]`).
    var defaultFeatureIds: [String]
    /// The function calling mode configured for this model by the admin.
    /// Values: `"native"` for native tool calling, `nil`/absent for default (server-handled).
    /// Sourced from `info.params.function_calling` in the OpenWebUI model payload.
    var functionCallingMode: String?
    /// Builtin tools enabled for this model by the admin.
    /// Keys match OpenWebUI's `meta.builtinTools` object (e.g. `"memory"`, `"time"`,
    /// `"web_search"`, `"image_generation"`, `"code_interpreter"`, etc.).
    /// A `true` value means the tool is available; `false` means it's disabled.
    var builtinTools: [String: Bool]

    init(
        id: String,
        name: String,
        description: String? = nil,
        isMultimodal: Bool = false,
        supportsStreaming: Bool = true,
        supportsRAG: Bool = false,
        contextLength: Int? = nil,
        capabilities: [String: String]? = nil,
        profileImageURL: String? = nil,
        toolIds: [String] = [],
        defaultFeatureIds: [String] = [],
        functionCallingMode: String? = nil,
        builtinTools: [String: Bool] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isMultimodal = isMultimodal
        self.supportsStreaming = supportsStreaming
        self.supportsRAG = supportsRAG
        self.contextLength = contextLength
        self.capabilities = capabilities
        self.profileImageURL = profileImageURL
        self.toolIds = toolIds
        self.defaultFeatureIds = defaultFeatureIds
        self.functionCallingMode = functionCallingMode
        self.builtinTools = builtinTools
    }

    /// Whether the memory builtin tool is enabled for this model.
    var supportsMemory: Bool {
        builtinTools["memory"] == true
    }

    /// A short display name, extracting the model name after any provider prefix.
    var shortName: String {
        if let lastSlash = name.lastIndex(of: "/") {
            return String(name[name.index(after: lastSlash)...])
        }
        return name
    }

    // MARK: - Avatar URL Resolution

    /// Resolves the avatar URL for this model using the OpenWebUI dedicated endpoint.
    ///
    /// Matches the Flutter `resolveModelIconUrlForModel` logic:
    /// 1. If `profileImageURL` is an external URL or data URI, use it directly.
    /// 2. Otherwise, build the URL using the dedicated model avatar endpoint:
    ///    `/api/v1/models/model/profile/image?id={modelId}`
    ///
    /// This endpoint handles:
    /// - External URLs (returns 302 redirect)
    /// - Base64 data URIs (decodes and serves)
    /// - Fallback favicon.png
    func resolveAvatarURL(baseURL: String) -> URL? {
        // Check for legacy profile_image_url that's an external URL or data URI
        if let legacy = profileImageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            if legacy.hasPrefix("data:image") {
                // Data URIs can't be used as URL — use the dedicated endpoint instead
                return buildModelAvatarURL(baseURL: baseURL)
            }
            if legacy.hasPrefix("http://") || legacy.hasPrefix("https://") {
                return URL(string: legacy)
            }
        }

        // Use the dedicated OpenWebUI model avatar endpoint
        return buildModelAvatarURL(baseURL: baseURL)
    }

    /// Builds the model avatar URL using the OpenWebUI endpoint:
    /// `/api/v1/models/model/profile/image?id={modelId}`
    ///
    /// This endpoint requires authentication (handled by ``AuthenticatedImageView``
    /// or by appending the auth token as a query parameter / header).
    private func buildModelAvatarURL(baseURL: String) -> URL? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !id.isEmpty else { return nil }

        let normalizedBase = trimmedBase.hasSuffix("/")
            ? String(trimmedBase.dropLast())
            : trimmedBase

        var components = URLComponents(string: "\(normalizedBase)/api/v1/models/model/profile/image")
        components?.queryItems = [URLQueryItem(name: "id", value: id)]
        return components?.url
    }
}
