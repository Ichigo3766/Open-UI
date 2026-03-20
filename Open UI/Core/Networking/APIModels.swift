import Foundation

// MARK: - Authentication

/// Response from `/api/v1/auths/signin`.
struct AuthResponse: Codable, Sendable {
    let token: String
    let tokenType: String?
    let id: String?
    let email: String?
    let name: String?
    let role: String?
    let profileImageUrl: String?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case id, email, name, role
        case profileImageUrl = "profile_image_url"
    }
}

// MARK: - OAuth Providers

/// Represents the available OAuth providers configured on the server.
struct OAuthProviders: Codable, Sendable {
    let google: String?
    let microsoft: String?
    let github: String?
    let oidc: String?
    let feishu: String?

    /// Whether any OAuth provider is enabled.
    var hasAnyProvider: Bool {
        google != nil || microsoft != nil || github != nil
            || oidc != nil || feishu != nil
    }

    /// Returns the list of enabled provider keys.
    var enabledProviders: [String] {
        var providers: [String] = []
        if google != nil { providers.append("google") }
        if microsoft != nil { providers.append("microsoft") }
        if github != nil { providers.append("github") }
        if oidc != nil { providers.append("oidc") }
        if feishu != nil { providers.append("feishu") }
        return providers
    }

    /// Returns the display name for a provider key.
    func displayName(for key: String) -> String {
        switch key {
        case "google": return google ?? "Google"
        case "microsoft": return microsoft ?? "Microsoft"
        case "github": return github ?? "GitHub"
        case "oidc": return oidc ?? "SSO"
        case "feishu": return feishu ?? "Feishu"
        default: return key
        }
    }

    /// Returns the SF Symbol icon name for a provider key.
    static func iconName(for key: String) -> String {
        switch key {
        case "google": return "g.circle.fill"
        case "microsoft": return "rectangle.grid.2x2.fill"
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "oidc": return "lock.shield.fill"
        case "feishu": return "bubble.left.fill"
        default: return "arrow.right.circle.fill"
        }
    }
}

/// Wrapper for the `oauth` field in the backend config response.
struct OAuthConfig: Codable, Sendable {
    let providers: OAuthProviders?
}

// MARK: - Backend Configuration

/// Response from `/api/config` containing server version and features.
///
/// Uses a custom `init(from:)` so that unknown top-level keys
/// (e.g. `user_count`, `code`, `file`, `permissions`, etc.)
/// and nested decoding failures never prevent the config from loading.
struct BackendConfig: Codable, Sendable {
    let status: Bool?
    let version: String?
    let name: String?
    let features: BackendFeatures?
    let defaultModels: [String]?
    let defaultPromptSuggestions: [PromptSuggestion]?
    let audio: AudioConfig?
    let oauth: OAuthConfig?

    struct BackendFeatures: Codable, Sendable {
        let auth: Bool?
        let authTrustedHeader: Bool?
        let enableSignup: Bool?
        let enableSignupPasswordConfirmation: Bool?
        let enableLoginForm: Bool?
        let enableWebSearch: Bool?
        let enableImageGeneration: Bool?
        let enableCommunitySharing: Bool?
        let enableAdminExport: Bool?
        let enableAdminChatAccess: Bool?
        let enableLdap: Bool?
        let enableFolders: Bool?
        let enableNotes: Bool?
        let enableChannels: Bool?
        let enableCodeExecution: Bool?
        let enableCodeInterpreter: Bool?
        let enableWebsocket: Bool?

        // Backward compat aliases
        var authTrustedHeaderAuth: Bool? { authTrustedHeader }
        var enableLogin: Bool? { enableLoginForm }
        var enableAdminChat: Bool? { enableAdminChatAccess }

        enum CodingKeys: String, CodingKey {
            case auth
            case authTrustedHeader = "auth_trusted_header"
            case enableSignup = "enable_signup"
            case enableSignupPasswordConfirmation = "enable_signup_password_confirmation"
            case enableLoginForm = "enable_login_form"
            case enableWebSearch = "enable_web_search"
            case enableImageGeneration = "enable_image_generation"
            case enableCommunitySharing = "enable_community_sharing"
            case enableAdminExport = "enable_admin_export"
            case enableAdminChatAccess = "enable_admin_chat_access"
            case enableLdap = "enable_ldap"
            case enableFolders = "enable_folders"
            case enableNotes = "enable_notes"
            case enableChannels = "enable_channels"
            case enableCodeExecution = "enable_code_execution"
            case enableCodeInterpreter = "enable_code_interpreter"
            case enableWebsocket = "enable_websocket"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            auth = try container.decodeIfPresent(Bool.self, forKey: .auth)
            authTrustedHeader = try container.decodeIfPresent(Bool.self, forKey: .authTrustedHeader)
            enableSignup = try container.decodeIfPresent(Bool.self, forKey: .enableSignup)
            enableSignupPasswordConfirmation = try container.decodeIfPresent(Bool.self, forKey: .enableSignupPasswordConfirmation)
            enableLoginForm = try container.decodeIfPresent(Bool.self, forKey: .enableLoginForm)
            enableWebSearch = try container.decodeIfPresent(Bool.self, forKey: .enableWebSearch)
            enableImageGeneration = try container.decodeIfPresent(Bool.self, forKey: .enableImageGeneration)
            enableCommunitySharing = try container.decodeIfPresent(Bool.self, forKey: .enableCommunitySharing)
            enableAdminExport = try container.decodeIfPresent(Bool.self, forKey: .enableAdminExport)
            enableAdminChatAccess = try container.decodeIfPresent(Bool.self, forKey: .enableAdminChatAccess)
            enableLdap = try container.decodeIfPresent(Bool.self, forKey: .enableLdap)
            enableFolders = try container.decodeIfPresent(Bool.self, forKey: .enableFolders)
            enableNotes = try container.decodeIfPresent(Bool.self, forKey: .enableNotes)
            enableChannels = try container.decodeIfPresent(Bool.self, forKey: .enableChannels)
            enableCodeExecution = try container.decodeIfPresent(Bool.self, forKey: .enableCodeExecution)
            enableCodeInterpreter = try container.decodeIfPresent(Bool.self, forKey: .enableCodeInterpreter)
            enableWebsocket = try container.decodeIfPresent(Bool.self, forKey: .enableWebsocket)
        }
    }

    struct PromptSuggestion: Codable, Sendable {
        let title: [String]?
        let content: String?
    }

    struct AudioConfig: Codable, Sendable {
        let tts: TTSConfig?
        let stt: STTConfig?

        struct TTSConfig: Codable, Sendable {
            let engine: String?
            let voice: String?
            let splitOn: String?

            enum CodingKeys: String, CodingKey {
                case engine, voice
                case splitOn = "split_on"
            }
        }

        struct STTConfig: Codable, Sendable {
            let engine: String?
        }
    }

    enum CodingKeys: String, CodingKey {
        case status, version, name, features, audio, oauth
        case defaultModels = "default_models"
        case defaultPromptSuggestions = "default_prompt_suggestions"
    }

    /// Custom decoder that gracefully handles missing/malformed nested objects.
    /// If `features`, `audio`, `oauth`, or `defaultPromptSuggestions` fail to
    /// decode (e.g. due to unexpected field types from newer server versions),
    /// they are set to nil instead of failing the entire config.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(Bool.self, forKey: .status)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        features = try? container.decodeIfPresent(BackendFeatures.self, forKey: .features)
        defaultModels = try? container.decodeIfPresent([String].self, forKey: .defaultModels)
        defaultPromptSuggestions = try? container.decodeIfPresent([PromptSuggestion].self, forKey: .defaultPromptSuggestions)
        audio = try? container.decodeIfPresent(AudioConfig.self, forKey: .audio)
        oauth = try? container.decodeIfPresent(OAuthConfig.self, forKey: .oauth)
    }

    /// Whether this response looks like a valid OpenWebUI server.
    var isValidOpenWebUI: Bool {
        status == true
            && version != nil
            && !(version?.isEmpty ?? true)
            && features != nil
    }

    /// OAuth providers configured on the server.
    var oauthProviders: OAuthProviders? {
        oauth?.providers
    }

    /// Whether any OAuth/SSO provider is available.
    var hasSsoEnabled: Bool {
        oauth?.providers?.hasAnyProvider == true
    }

    /// Whether the login form (email/password) is enabled on the server.
    var isLoginFormEnabled: Bool {
        features?.enableLoginForm ?? features?.enableLogin ?? true
    }
}

// MARK: - Chat Completion

/// Request body for `/api/chat/completions`.
struct ChatCompletionRequest: Sendable {
    var model: String
    var messages: [[String: Any]]
    var stream: Bool = true
    var chatId: String?
    var sessionId: String?
    var messageId: String?
    var parentId: String?
    var toolIds: [String]?
    var filterIds: [String]?
    var features: ChatFeatures?
    var files: [[String: Any]]?
    var streamOptions: [String: Any]?
    var backgroundTasks: [String: Any]?
    /// The terminal server ID to enable Open Terminal tools for this request.
    /// When set, the backend injects terminal tools (execute_command, file management, etc.)
    /// into the model's tool-calling pipeline.
    var terminalId: String?
    /// OpenWebUI server-side parameters sent alongside the request.
    /// The server's `apply_params_to_form_data()` consumes these before forwarding
    /// to the LLM. Key use: `function_calling` — controls native vs default tool mode.
    /// Example: `["function_calling": "native"]` enables native tool calling.
    var params: [String: Any]?

    struct ChatFeatures: Sendable {
        var webSearch: Bool = false
        var imageGeneration: Bool = false
        var codeInterpreter: Bool = false
        var memory: Bool = false

        /// Whether any feature is enabled. Used to decide whether to include
        /// the `features` object in the request at all.
        var hasAnyEnabled: Bool {
            webSearch || imageGeneration || codeInterpreter || memory
        }
    }

    /// Serialises the request to a JSON dictionary.
    func toJSON() -> [String: Any] {
        var data: [String: Any] = [
            "stream": stream,
            "model": model,
            "messages": messages
        ]

        if let chatId { data["chat_id"] = chatId }
        if let sessionId { data["session_id"] = sessionId }
        if let messageId { data["id"] = messageId }
        if let parentId { data["parent_id"] = parentId }
        if let toolIds, !toolIds.isEmpty { data["tool_ids"] = toolIds }
        if let filterIds, !filterIds.isEmpty { data["filter_ids"] = filterIds }
        if let files, !files.isEmpty { data["files"] = files }
        if let streamOptions { data["stream_options"] = streamOptions }
        if let backgroundTasks, !backgroundTasks.isEmpty { data["background_tasks"] = backgroundTasks }
        if let terminalId, !terminalId.isEmpty { data["terminal_id"] = terminalId }

        // Include server-side params (e.g. function_calling mode).
        // The server's apply_params_to_form_data() consumes this dict and strips
        // OpenWebUI-specific keys before forwarding the rest to the LLM.
        if let params, !params.isEmpty { data["params"] = params }

        // Always include parent_message to prevent server NoneType errors
        // (matches Flutter: data['parent_message'] = {})
        data["parent_message"] = [String: Any]()

        if let features {
            // Always send all feature keys with explicit true/false values,
            // matching the web client behavior. If we only send `true` keys
            // (or omit `features` entirely when all are off), the server falls
            // back to the model's `defaultFeatureIds` and enables features the
            // user explicitly toggled OFF.
            var feat: [String: Any] = [:]
            feat["web_search"] = features.webSearch
            feat["image_generation"] = features.imageGeneration
            feat["code_interpreter"] = features.codeInterpreter
            // Always send memory explicitly (true/false) so the server never
            // falls back to model defaults. Matches web client behavior where
            // memory is sent based purely on the user's account setting.
            feat["memory"] = features.memory
            data["features"] = feat
        }

        return data
    }
}

// MARK: - File Info

/// Metadata about an uploaded file.
struct FileInfoResponse: Codable, Sendable {
    let id: String
    let filename: String?
    let contentType: String?
    let size: Int?
    let createdAt: Double?
    let updatedAt: Double?
    let hash: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, size, hash, path
        case contentType = "content_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Folder

/// A folder for organising conversations.
struct FolderResponse: Codable, Sendable {
    let id: String
    let name: String
    let parentId: String?
    let userId: String?
    let createdAt: Double?
    let updatedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, name
        case parentId = "parent_id"
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Task Configuration

/// Server-side task configuration from `GET /api/v1/tasks/config`.
///
/// Controls which AI-powered background tasks are enabled globally
/// by the admin. The app should respect these settings and not request
/// disabled tasks in `background_tasks`.
struct TaskConfig: Sendable {
    let taskModel: String?
    let taskModelExternal: String?
    let enableTitleGeneration: Bool
    let enableFollowUpGeneration: Bool
    let enableTagsGeneration: Bool
    let enableAutocompleteGeneration: Bool
    let autocompleteMaxInputLength: Int
    let enableSearchQueryGeneration: Bool
    let enableRetrievalQueryGeneration: Bool
    let titleGenerationPromptTemplate: String?
    let followUpGenerationPromptTemplate: String?
    let tagsGenerationPromptTemplate: String?
    let voiceModePromptTemplate: String?

    /// Creates a TaskConfig from a raw JSON dictionary (flexible parsing).
    init(from json: [String: Any]) {
        taskModel = json["TASK_MODEL"] as? String
        taskModelExternal = json["TASK_MODEL_EXTERNAL"] as? String
        enableTitleGeneration = json["ENABLE_TITLE_GENERATION"] as? Bool ?? true
        enableFollowUpGeneration = json["ENABLE_FOLLOW_UP_GENERATION"] as? Bool ?? true
        enableTagsGeneration = json["ENABLE_TAGS_GENERATION"] as? Bool ?? true
        enableAutocompleteGeneration = json["ENABLE_AUTOCOMPLETE_GENERATION"] as? Bool ?? false
        autocompleteMaxInputLength = json["AUTOCOMPLETE_GENERATION_INPUT_MAX_LENGTH"] as? Int ?? 256
        enableSearchQueryGeneration = json["ENABLE_SEARCH_QUERY_GENERATION"] as? Bool ?? true
        enableRetrievalQueryGeneration = json["ENABLE_RETRIEVAL_QUERY_GENERATION"] as? Bool ?? true
        titleGenerationPromptTemplate = json["TITLE_GENERATION_PROMPT_TEMPLATE"] as? String
        followUpGenerationPromptTemplate = json["FOLLOW_UP_GENERATION_PROMPT_TEMPLATE"] as? String
        tagsGenerationPromptTemplate = json["TAGS_GENERATION_PROMPT_TEMPLATE"] as? String
        voiceModePromptTemplate = json["VOICE_MODE_PROMPT_TEMPLATE"] as? String
    }

    /// Default config when the server endpoint is unavailable.
    static let `default` = TaskConfig(from: [:])
}

// MARK: - MIME Type Helper

/// Returns the MIME type for a given file extension.
func mimeType(for fileName: String) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()
    switch ext {
    case "m4a": return "audio/mp4"
    case "mp3": return "audio/mpeg"
    case "wav": return "audio/wav"
    case "aac": return "audio/aac"
    case "ogg": return "audio/ogg"
    case "webm": return "audio/webm"
    case "mp4": return "video/mp4"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic", "heif": return "image/jpeg" // Converted to JPEG before upload
    case "dng", "raw", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2": return "image/jpeg"
    case "pdf": return "application/pdf"
    case "txt": return "text/plain"
    case "json": return "application/json"
    default: return "application/octet-stream"
    }
}
