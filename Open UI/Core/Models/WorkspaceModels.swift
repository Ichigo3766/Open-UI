import Foundation

// MARK: - Prompt Detail (full CRUD model)

/// Full prompt model used for create/edit flows.
struct PromptDetail: Identifiable, Sendable {
    let id: String
    var command: String          // without leading "/"
    var name: String
    var content: String
    var isActive: Bool
    var tags: [String]
    var accessGrants: [AccessGrant]
    var meta: [String: Any]
    let userId: String
    let createdAt: Date?
    var updatedAt: Date?
    /// The ID of the currently active/live history version (matches a PromptVersion.id).
    var versionId: String?

    init(id: String = UUID().uuidString,
         command: String = "",
         name: String = "",
         content: String = "",
         isActive: Bool = true,
         tags: [String] = [],
         accessGrants: [AccessGrant] = [],
         meta: [String: Any] = [:],
         userId: String = "",
         createdAt: Date? = nil,
         updatedAt: Date? = nil,
         versionId: String? = nil) {
        self.id = id
        self.command = command
        self.name = name
        self.content = content
        self.isActive = isActive
        self.tags = tags
        self.accessGrants = accessGrants
        self.meta = meta
        self.userId = userId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versionId = versionId
    }

    init?(json: [String: Any]) {
        guard let command = json["command"] as? String,
              let name = json["name"] as? String else { return nil }

        self.id = json["id"] as? String ?? UUID().uuidString
        self.command = command.hasPrefix("/") ? String(command.dropFirst()) : command
        self.name = name
        self.content = json["content"] as? String ?? ""
        self.isActive = json["is_active"] as? Bool ?? true
        self.tags = json["tags"] as? [String] ?? []
        self.userId = json["user_id"] as? String ?? ""
        self.meta = json["meta"] as? [String: Any] ?? [:]

        // Parse access_grants array — merge read+write entries into one grant per user
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            self.accessGrants = AccessGrant.mergedByUser(raw)
        } else {
            self.accessGrants = []
        }

        if let ts = json["created_at"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["created_at"] as? Int {
            self.createdAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.createdAt = nil
        }

        if let ts = json["updated_at"] as? Double {
            self.updatedAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["updated_at"] as? Int {
            self.updatedAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.updatedAt = nil
        }

        self.versionId = json["version_id"] as? String
    }

    var displayCommand: String { "/\(command)" }

    func toPromptItem() -> PromptItem? {
        var json: [String: Any] = [
            "id": id,
            "command": command,
            "name": name,
            "content": content,
            "is_active": isActive,
            "tags": tags,
            "user_id": userId
        ]
        if let cd = createdAt { json["created_at"] = cd.timeIntervalSince1970 }
        if let ud = updatedAt { json["updated_at"] = ud.timeIntervalSince1970 }
        return PromptItem(json: json)
    }

    func toCreatePayload(commitMessage: String = "") -> [String: Any] {
        var body: [String: Any] = [
            "command": command,
            "name": name,
            "content": content,
            "tags": tags,
            "is_active": isActive,
            "access_grants": buildGrantsPayload()
        ]
        if !commitMessage.isEmpty {
            body["meta"] = ["commit_message": commitMessage]
        }
        return body
    }

    func toUpdatePayload(commitMessage: String = "") -> [String: Any] {
        // Note: access_grants are managed via the dedicated /access/update endpoint.
        // Including them here would create a new version history entry.
        var body: [String: Any] = [
            "command": command,
            "name": name,
            "content": content,
            "tags": tags,
            "is_active": isActive
        ]
        var metaPayload = meta
        if !commitMessage.isEmpty { metaPayload["commit_message"] = commitMessage }
        if !metaPayload.isEmpty { body["meta"] = metaPayload }
        return body
    }

    /// Builds the access_grants array for the dedicated /access/update endpoint.
    /// Write access = TWO entries (one "read" + one "write") matching the web UI format.
    func buildGrantsPayload() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for grant in accessGrants {
            guard let userId = grant.userId else { continue }
            // Always include a "read" entry
            result.append([
                "principal_type": "user",
                "principal_id": userId,
                "permission": "read"
            ])
            // For write access, also include a "write" entry
            if grant.write {
                result.append([
                    "principal_type": "user",
                    "principal_id": userId,
                    "permission": "write"
                ])
            }
        }
        return result
    }
}

// MARK: - Prompt Version History

struct PromptVersion: Identifiable, Sendable {
    let id: String
    let promptId: String
    let content: String
    let name: String
    let command: String
    let commitMessage: String?
    let userId: String
    let createdAt: Date?
    let isLive: Bool
    /// Short hash identifier shown in the web UI (e.g. "78db464")
    let hash: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        self.promptId = json["prompt_id"] as? String ?? ""
        self.userId = json["user_id"] as? String ?? ""
        self.isLive = json["is_live"] as? Bool ?? false
        self.hash = json["hash"] as? String

        // The API nests all prompt content inside a "snapshot" object.
        // Fall back to root-level keys for forward-compatibility.
        let snapshot = json["snapshot"] as? [String: Any] ?? json
        self.content = snapshot["content"] as? String ?? ""
        self.name = snapshot["name"] as? String ?? ""
        self.command = snapshot["command"] as? String ?? ""
        let meta = snapshot["meta"] as? [String: Any] ?? [:]
        self.commitMessage = meta["commit_message"] as? String

        if let ts = json["created_at"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["created_at"] as? Int {
            self.createdAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.createdAt = nil
        }
    }

    /// Short 7-char display hash (like git), e.g. "78db464"
    var displayHash: String? {
        guard let h = hash, !h.isEmpty else { return nil }
        return String(h.prefix(7))
    }
}

// MARK: - Knowledge Detail (full CRUD model)

struct KnowledgeDetail: Identifiable, Sendable {
    let id: String
    var name: String
    var description: String
    var accessGrants: [AccessGrant]
    var files: [KnowledgeFileEntry]
    let userId: String
    let createdAt: Date?
    var updatedAt: Date?

    init(id: String = UUID().uuidString,
         name: String = "",
         description: String = "",
         accessGrants: [AccessGrant] = [],
         files: [KnowledgeFileEntry] = [],
         userId: String = "",
         createdAt: Date? = nil,
         updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.accessGrants = accessGrants
        self.files = files
        self.userId = userId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }

        self.id = id
        self.name = name
        self.description = json["description"] as? String ?? ""
        self.userId = json["user_id"] as? String ?? ""

        // Parse access_grants array — merge read+write entries into one grant per user
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            self.accessGrants = AccessGrant.mergedByUser(raw)
        } else {
            self.accessGrants = []
        }

        // Files may be null in the detail endpoint — they come from a separate /files endpoint
        let rawFiles = json["files"] as? [[String: Any]] ?? []
        self.files = rawFiles.compactMap { KnowledgeFileEntry(json: $0) }

        if let ts = json["created_at"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["created_at"] as? Int {
            self.createdAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.createdAt = nil
        }

        if let ts = json["updated_at"] as? Double {
            self.updatedAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["updated_at"] as? Int {
            self.updatedAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.updatedAt = nil
        }
    }

    func toCreatePayload() -> [String: Any] {
        return [
            "name": name,
            "description": description,
            "access_grants": buildGrantsPayload()
        ]
    }

    func toUpdatePayload() -> [String: Any] {
        return [
            "name": name,
            "description": description,
            "access_grants": buildGrantsPayload()
        ]
    }

    /// Builds the access_grants array for the API payload.
    /// Write access = TWO entries (one "read" + one "write") matching the web UI format.
    func buildGrantsPayload() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for grant in accessGrants {
            guard let userId = grant.userId else { continue }
            // Always include a "read" entry
            result.append([
                "principal_type": "user",
                "principal_id": userId,
                "permission": "read"
            ])
            // For write access, also include a "write" entry
            if grant.write {
                result.append([
                    "principal_type": "user",
                    "principal_id": userId,
                    "permission": "write"
                ])
            }
        }
        return result
    }

    func toKnowledgeItem() -> KnowledgeItem {
        KnowledgeItem(
            id: id,
            name: name,
            description: description.isEmpty ? nil : description,
            type: .collection,
            fileCount: files.count
        )
    }
}

// MARK: - Skill Detail (full CRUD model)

struct SkillDetail: Identifiable, Sendable {
    let id: String
    var name: String
    var slug: String          // the "id" field in the API (URL-safe slug)
    var description: String
    var content: String       // markdown instruction text
    var isActive: Bool
    var accessGrants: [AccessGrant]
    let userId: String
    let createdAt: Date?
    var updatedAt: Date?

    init(id: String = UUID().uuidString,
         name: String = "",
         slug: String = "",
         description: String = "",
         content: String = "",
         isActive: Bool = true,
         accessGrants: [AccessGrant] = [],
         userId: String = "",
         createdAt: Date? = nil,
         updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.description = description
        self.content = content
        self.isActive = isActive
        self.accessGrants = accessGrants
        self.userId = userId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }

        self.id = id
        self.name = name
        // The API uses "id" as the slug field; we store separately to avoid confusion.
        self.slug = json["id"] as? String ?? id
        self.description = json["description"] as? String ?? ""
        self.content = json["content"] as? String ?? ""
        self.isActive = json["is_active"] as? Bool ?? true
        self.userId = json["user_id"] as? String ?? ""

        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            self.accessGrants = AccessGrant.mergedByUser(raw)
        } else {
            self.accessGrants = []
        }

        if let ts = json["created_at"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["created_at"] as? Int {
            self.createdAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.createdAt = nil
        }

        if let ts = json["updated_at"] as? Double {
            self.updatedAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["updated_at"] as? Int {
            self.updatedAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.updatedAt = nil
        }
    }

    func toCreatePayload() -> [String: Any] {
        return [
            "id": slug,
            "name": name,
            "description": description,
            "content": content,
            "is_active": isActive,
            "access_grants": buildGrantsPayload()
        ]
    }

    func toUpdatePayload() -> [String: Any] {
        return [
            "id": slug,
            "name": name,
            "description": description,
            "content": content,
            "is_active": isActive
        ]
    }

    /// Builds the access_grants array for API payloads (same pattern as Knowledge/Prompts).
    func buildGrantsPayload() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for grant in accessGrants {
            guard let userId = grant.userId else { continue }
            result.append([
                "principal_type": "user",
                "principal_id": userId,
                "permission": "read"
            ])
            if grant.write {
                result.append([
                    "principal_type": "user",
                    "principal_id": userId,
                    "permission": "write"
                ])
            }
        }
        return result
    }

    func toSkillItem() -> SkillItem {
        SkillItem(
            id: id,
            name: name,
            description: description.isEmpty ? nil : description,
            isActive: isActive
        )
    }
}

// MARK: - Tool Detail (full CRUD model)

struct ToolDetail: Identifiable, Sendable {
    let id: String           // API slug (e.g. "weather_tool")
    var name: String
    var content: String      // Python code
    var description: String  // from meta.description
    var manifest: ToolManifest
    var specs: [ToolSpec]
    var hasUserValves: Bool
    var accessGrants: [AccessGrant]
    let userId: String
    var userName: String?
    var userEmail: String?
    let createdAt: Date?
    var updatedAt: Date?

    init(id: String = "",
         name: String = "",
         content: String = "",
         description: String = "",
         manifest: ToolManifest = ToolManifest(),
         specs: [ToolSpec] = [],
         hasUserValves: Bool = false,
         accessGrants: [AccessGrant] = [],
         userId: String = "",
         userName: String? = nil,
         userEmail: String? = nil,
         createdAt: Date? = nil,
         updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.content = content
        self.description = description
        self.manifest = manifest
        self.specs = specs
        self.hasUserValves = hasUserValves
        self.accessGrants = accessGrants
        self.userId = userId
        self.userName = userName
        self.userEmail = userEmail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }

        self.id = id
        self.name = name
        self.content = json["content"] as? String ?? ""
        self.hasUserValves = json["has_user_valves"] as? Bool ?? false
        self.userId = json["user_id"] as? String ?? ""

        // Parse nested user object
        if let userObj = json["user"] as? [String: Any] {
            self.userName = userObj["name"] as? String
            self.userEmail = userObj["email"] as? String
        } else {
            self.userName = nil
            self.userEmail = nil
        }

        // Parse meta (description + manifest)
        let meta = json["meta"] as? [String: Any] ?? [:]
        self.description = meta["description"] as? String ?? ""

        if let manifestDict = meta["manifest"] as? [String: Any] {
            self.manifest = ToolManifest(json: manifestDict)
        } else {
            self.manifest = ToolManifest()
        }

        // Parse specs
        if let specsArray = json["specs"] as? [[String: Any]] {
            self.specs = specsArray.compactMap { ToolSpec(json: $0) }
        } else {
            self.specs = []
        }

        // Parse access_grants
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            self.accessGrants = AccessGrant.mergedByUser(raw)
        } else {
            self.accessGrants = []
        }

        if let ts = json["created_at"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["created_at"] as? Int {
            self.createdAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.createdAt = nil
        }

        if let ts = json["updated_at"] as? Double {
            self.updatedAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["updated_at"] as? Int {
            self.updatedAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.updatedAt = nil
        }
    }

    func toCreatePayload() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "content": content,
            "meta": [
                "description": description,
                "manifest": manifest.toJSON()
            ],
            "access_grants": buildGrantsPayload()
        ]
    }

    func toUpdatePayload() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "content": content,
            "meta": [
                "description": description,
                "manifest": manifest.toJSON()
            ]
        ]
    }

    func buildGrantsPayload() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for grant in accessGrants {
            guard let userId = grant.userId else { continue }
            result.append(["principal_type": "user", "principal_id": userId, "permission": "read"])
            if grant.write {
                result.append(["principal_type": "user", "principal_id": userId, "permission": "write"])
            }
        }
        return result
    }

    func toWorkspaceToolItem() -> WorkspaceToolItem {
        WorkspaceToolItem(
            id: id,
            name: name,
            description: description.isEmpty ? nil : description,
            version: manifest.version,
            authorName: manifest.author
        )
    }
}

// MARK: - Tool Manifest

struct ToolManifest: Sendable {
    var title: String
    var author: String
    var authorUrl: String
    var fundingUrl: String
    var version: String
    var license: String
    var requirements: String
    var homepage: String

    init(title: String = "", author: String = "", authorUrl: String = "",
         fundingUrl: String = "", version: String = "", license: String = "",
         requirements: String = "", homepage: String = "") {
        self.title = title
        self.author = author
        self.authorUrl = authorUrl
        self.fundingUrl = fundingUrl
        self.version = version
        self.license = license
        self.requirements = requirements
        self.homepage = homepage
    }

    init(json: [String: Any]) {
        self.title = json["title"] as? String ?? ""
        self.author = json["author"] as? String ?? ""
        self.authorUrl = json["author_url"] as? String ?? ""
        self.fundingUrl = json["funding_url"] as? String ?? ""
        self.version = json["version"] as? String ?? ""
        self.license = json["license"] as? String ?? ""
        self.requirements = json["requirements"] as? String ?? ""
        self.homepage = json["homepage"] as? String ?? ""
    }

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = [:]
        if !title.isEmpty { dict["title"] = title }
        if !author.isEmpty { dict["author"] = author }
        if !authorUrl.isEmpty { dict["author_url"] = authorUrl }
        if !fundingUrl.isEmpty { dict["funding_url"] = fundingUrl }
        if !version.isEmpty { dict["version"] = version }
        if !license.isEmpty { dict["license"] = license }
        if !requirements.isEmpty { dict["requirements"] = requirements }
        if !homepage.isEmpty { dict["homepage"] = homepage }
        return dict
    }
}

// MARK: - Tool Spec

struct ToolSpec: Identifiable, Sendable {
    let id: String          // name acts as ID
    var name: String
    var description: String
    var parameters: [String: String]   // simplified: key → type/description

    init(name: String = "", description: String = "", parameters: [String: String] = [:]) {
        self.id = name
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        self.id = name
        self.name = name
        self.description = json["description"] as? String ?? ""
        // Parse parameters dict — accept both String values and nested objects
        if let paramsDict = json["parameters"] as? [String: Any] {
            var simplified: [String: String] = [:]
            for (k, v) in paramsDict {
                if let s = v as? String {
                    simplified[k] = s
                } else if let d = v as? [String: Any] {
                    simplified[k] = d["type"] as? String ?? d["description"] as? String ?? "\(v)"
                }
            }
            self.parameters = simplified
        } else {
            self.parameters = [:]
        }
    }
}

// MARK: - WorkspaceToolItem (lightweight list model for workspace Tools tab)

struct WorkspaceToolItem: Identifiable, Sendable {
    let id: String
    var name: String
    var description: String?
    var version: String?
    var authorName: String?

    init(id: String, name: String, description: String? = nil,
         version: String? = nil, authorName: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.authorName = authorName
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        let meta = json["meta"] as? [String: Any] ?? [:]
        self.description = meta["description"] as? String
        let manifest = meta["manifest"] as? [String: Any] ?? [:]
        self.version = manifest["version"] as? String
        self.authorName = manifest["author"] as? String
        // Fallback for description at root
        if self.description == nil {
            self.description = json["description"] as? String
        }
    }
}

// MARK: - ValvesSheetItem (Identifiable wrapper for item-based sheet presentation)

/// Used with `.sheet(item:)` to atomically pass a tool ID into ValvesSheet,
/// avoiding the SwiftUI race condition that occurs with `.sheet(isPresented:)` + a separate @State string.
struct ValvesSheetItem: Identifiable {
    let id: String
}

// MARK: - Skill Item (lightweight list model)

struct SkillItem: Identifiable, Sendable {
    let id: String
    var name: String
    var description: String?
    var isActive: Bool

    init(id: String, name: String, description: String? = nil, isActive: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.isActive = isActive
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.description = json["description"] as? String
        self.isActive = json["is_active"] as? Bool ?? true
    }
}

// MARK: - Knowledge File Entry

struct KnowledgeFileEntry: Identifiable, Sendable {
    let id: String
    var name: String
    let filename: String?
    var size: Int?
    let createdAt: Date?
    var updatedAt: Date?

    init(id: String, name: String, filename: String? = nil,
         size: Int? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.filename = filename
        self.size = size
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id

        // Server response has: id, hash, filename, meta.{name, size, content_type}, data.status
        let meta = json["meta"] as? [String: Any] ?? [:]
        let filename = json["filename"] as? String
        self.filename = filename

        // Name: prefer meta.name, then filename, then id
        self.name = meta["name"] as? String ?? filename ?? id
        self.size = meta["size"] as? Int

        if let ts = json["created_at"] as? Double {
            self.createdAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["created_at"] as? Int {
            self.createdAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.createdAt = nil
        }

        if let ts = json["updated_at"] as? Double {
            self.updatedAt = Date(timeIntervalSince1970: ts)
        } else if let ts = json["updated_at"] as? Int {
            self.updatedAt = Date(timeIntervalSince1970: Double(ts))
        } else {
            self.updatedAt = nil
        }
    }

    var formattedSize: String? {
        guard let size, size > 0 else { return nil }
        if size < 1024 { return "\(size) B" }
        if size < 1_048_576 { return String(format: "%.1f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", Double(size) / 1_048_576)
    }
}

// MARK: - Suggestion Prompt

/// A single suggestion prompt entry matching the API format:
/// `{"content": "prompt text", "title": ["titleText", "subtitleText"]}`
struct SuggestionPrompt: Identifiable, Sendable {
    var id: String = UUID().uuidString
    var content: String
    var title: String
    var subtitle: String

    init(id: String = UUID().uuidString, content: String = "", title: String = "", subtitle: String = "") {
        self.id = id
        self.content = content
        self.title = title
        self.subtitle = subtitle
    }

    init?(json: [String: Any]) {
        guard let content = json["content"] as? String else { return nil }
        self.id = UUID().uuidString
        self.content = content
        let titleArr = json["title"] as? [String] ?? []
        self.title = titleArr.count > 0 ? titleArr[0] : ""
        self.subtitle = titleArr.count > 1 ? titleArr[1] : ""
    }

    func toJSON() -> [String: Any] {
        return [
            "content": content,
            "title": [title, subtitle]
        ]
    }
}

// MARK: - Model Knowledge Entry

/// An entry in meta.knowledge — can be a collection or a file.
struct ModelKnowledgeEntry: Identifiable, Sendable {
    let id: String
    var name: String
    var description: String?
    var type: EntryType

    enum EntryType: String, Sendable { case collection, file }

    init(id: String, name: String, description: String? = nil, type: EntryType) {
        self.id = id; self.name = name; self.description = description; self.type = type
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id; self.name = name; self.description = json["description"] as? String
        self.type = (json["type"] as? String) == "file" ? .file : .collection
    }

    var icon: String { type == .file ? "doc.text" : "cylinder.split.1x2" }
}

// MARK: - Model Item (lightweight list model)

struct ModelItem: Identifiable, Sendable {
    let id: String
    var name: String
    var description: String?
    var isActive: Bool
    var profileImageURL: String?
    var baseModelId: String?
    var tags: [String]
    var writeAccess: Bool
    var userId: String
    var createdAt: Date?
    var updatedAt: Date?

    init(id: String, name: String, description: String? = nil, isActive: Bool = true,
         profileImageURL: String? = nil, baseModelId: String? = nil, tags: [String] = [],
         writeAccess: Bool = true, userId: String = "", createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.description = description; self.isActive = isActive
        self.profileImageURL = profileImageURL; self.baseModelId = baseModelId; self.tags = tags
        self.writeAccess = writeAccess; self.userId = userId; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id; self.name = name
        self.isActive = json["is_active"] as? Bool ?? true
        self.writeAccess = json["write_access"] as? Bool ?? true
        self.userId = json["user_id"] as? String ?? ""
        self.baseModelId = json["base_model_id"] as? String
        let meta = json["meta"] as? [String: Any] ?? [:]
        self.description = meta["description"] as? String
        self.profileImageURL = meta["profile_image_url"] as? String
        if let tagArray = meta["tags"] as? [[String: Any]] {
            self.tags = tagArray.compactMap { $0["name"] as? String }
        } else if let tagArray = meta["tags"] as? [String] {
            self.tags = tagArray
        } else { self.tags = [] }
        if let ts = json["created_at"] as? Double { self.createdAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["created_at"] as? Int { self.createdAt = Date(timeIntervalSince1970: Double(ts)) }
        else { self.createdAt = nil }
        if let ts = json["updated_at"] as? Double { self.updatedAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["updated_at"] as? Int { self.updatedAt = Date(timeIntervalSince1970: Double(ts)) }
        else { self.updatedAt = nil }
    }
}

// MARK: - Model Detail (full CRUD model)

struct ModelDetail: Identifiable, Sendable {
    let id: String
    var name: String
    var baseModelId: String?
    var description: String?
    var profileImageURL: String?
    var tags: [String]
    var isActive: Bool
    var accessGrants: [AccessGrant]
    var writeAccess: Bool
    let userId: String
    let createdAt: Date?
    var updatedAt: Date?

    // System Prompt (params.system)
    var systemPrompt: String

    // Capabilities (meta.capabilities)
    var capVision: Bool
    var capFileUpload: Bool
    var capFileContext: Bool
    var capWebSearch: Bool
    var capImageGeneration: Bool
    var capCodeInterpreter: Bool
    var capUsage: Bool
    var capCitations: Bool
    var capStatusUpdates: Bool
    var capBuiltinTools: Bool

    // Default Features (meta.defaultFeatureIds)
    var defaultFeatureWebSearch: Bool
    var defaultFeatureImageGen: Bool
    var defaultFeatureCodeInterpreter: Bool

    // Builtin Tools (meta.builtinTools)
    var builtinTime: Bool
    var builtinMemory: Bool
    var builtinChats: Bool
    var builtinNotes: Bool
    var builtinKnowledge: Bool
    var builtinChannels: Bool
    var builtinWebSearch: Bool
    var builtinImageGen: Bool
    var builtinCodeInterpreter: Bool

    // Knowledge (meta.knowledge)
    var knowledgeItems: [ModelKnowledgeEntry]

    // Suggestion Prompts (meta.suggestion_prompts)
    var suggestionPrompts: [SuggestionPrompt]

    // TTS Voice (meta.tts_voice)
    var ttsVoice: String

    // Advanced Params — nil = Default (not sent), non-nil = Custom (sent)
    var advStreamResponse: Bool?
    var advStreamDeltaChunkSize: Int?
    var advFunctionCalling: String?
    var advReasoningEffort: String?
    var advReasoningTagStart: String?
    var advReasoningTagEnd: String?
    var advSeed: Int?
    var advStopSequences: [String]?
    var advTemperature: Double?
    var advLogitBias: String?
    var advMaxTokens: Int?
    var advTopK: Int?
    var advTopP: Double?
    var advMinP: Double?
    var advFrequencyPenalty: Double?
    var advPresencePenalty: Double?
    var advMirostat: Int?
    var advMirostatEta: Double?
    var advMirostatTau: Double?
    var advRepeatLastN: Int?
    var advTfsZ: Double?
    var advRepeatPenalty: Double?
    var advUseMmap: Bool?
    var advUseMlock: Bool?
    var advThink: Bool?
    var advFormat: String?
    var advNumKeep: Int?
    var advNumCtx: Int?
    var advNumBatch: Int?
    var advNumThread: Int?
    var advNumGpu: Int?
    var advKeepAlive: String?
    var customParams: [(key: String, value: String)]

    // MARK: - Default Init

    init(id: String = UUID().uuidString, name: String = "", baseModelId: String? = nil,
         description: String? = nil, profileImageURL: String? = nil, tags: [String] = [],
         isActive: Bool = true, accessGrants: [AccessGrant] = [], writeAccess: Bool = true,
         userId: String = "", createdAt: Date? = nil, updatedAt: Date? = nil,
         systemPrompt: String = "",
         capVision: Bool = true, capFileUpload: Bool = true, capFileContext: Bool = true,
         capWebSearch: Bool = true, capImageGeneration: Bool = true, capCodeInterpreter: Bool = true,
         capUsage: Bool = true, capCitations: Bool = true, capStatusUpdates: Bool = true,
         capBuiltinTools: Bool = true,
         defaultFeatureWebSearch: Bool = true, defaultFeatureImageGen: Bool = false,
         defaultFeatureCodeInterpreter: Bool = false,
         builtinTime: Bool = true, builtinMemory: Bool = true, builtinChats: Bool = true,
         builtinNotes: Bool = true, builtinKnowledge: Bool = true, builtinChannels: Bool = true,
         builtinWebSearch: Bool = true, builtinImageGen: Bool = true, builtinCodeInterpreter: Bool = true,
         knowledgeItems: [ModelKnowledgeEntry] = [], suggestionPrompts: [SuggestionPrompt] = [],
         ttsVoice: String = "") {
        self.id = id; self.name = name; self.baseModelId = baseModelId; self.description = description
        self.profileImageURL = profileImageURL; self.tags = tags; self.isActive = isActive
        self.accessGrants = accessGrants; self.writeAccess = writeAccess; self.userId = userId
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.systemPrompt = systemPrompt
        self.capVision = capVision; self.capFileUpload = capFileUpload; self.capFileContext = capFileContext
        self.capWebSearch = capWebSearch; self.capImageGeneration = capImageGeneration
        self.capCodeInterpreter = capCodeInterpreter; self.capUsage = capUsage
        self.capCitations = capCitations; self.capStatusUpdates = capStatusUpdates
        self.capBuiltinTools = capBuiltinTools
        self.defaultFeatureWebSearch = defaultFeatureWebSearch
        self.defaultFeatureImageGen = defaultFeatureImageGen
        self.defaultFeatureCodeInterpreter = defaultFeatureCodeInterpreter
        self.builtinTime = builtinTime; self.builtinMemory = builtinMemory; self.builtinChats = builtinChats
        self.builtinNotes = builtinNotes; self.builtinKnowledge = builtinKnowledge
        self.builtinChannels = builtinChannels; self.builtinWebSearch = builtinWebSearch
        self.builtinImageGen = builtinImageGen; self.builtinCodeInterpreter = builtinCodeInterpreter
        self.knowledgeItems = knowledgeItems; self.suggestionPrompts = suggestionPrompts
        self.ttsVoice = ttsVoice; self.customParams = []
        self.advStreamResponse = nil; self.advStreamDeltaChunkSize = nil; self.advFunctionCalling = nil
        self.advReasoningEffort = nil; self.advReasoningTagStart = nil; self.advReasoningTagEnd = nil
        self.advSeed = nil; self.advStopSequences = nil; self.advTemperature = nil; self.advLogitBias = nil
        self.advMaxTokens = nil; self.advTopK = nil; self.advTopP = nil; self.advMinP = nil
        self.advFrequencyPenalty = nil; self.advPresencePenalty = nil; self.advMirostat = nil
        self.advMirostatEta = nil; self.advMirostatTau = nil; self.advRepeatLastN = nil
        self.advTfsZ = nil; self.advRepeatPenalty = nil; self.advUseMmap = nil; self.advUseMlock = nil
        self.advThink = nil; self.advFormat = nil; self.advNumKeep = nil; self.advNumCtx = nil
        self.advNumBatch = nil; self.advNumThread = nil; self.advNumGpu = nil; self.advKeepAlive = nil
    }

    // MARK: - JSON Init

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id; self.name = name
        self.baseModelId = json["base_model_id"] as? String
        self.isActive = json["is_active"] as? Bool ?? true
        self.writeAccess = json["write_access"] as? Bool ?? true
        self.userId = json["user_id"] as? String ?? ""

        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            self.accessGrants = AccessGrant.mergedByUser(raw)
        } else { self.accessGrants = [] }

        if let ts = json["created_at"] as? Double { self.createdAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["created_at"] as? Int { self.createdAt = Date(timeIntervalSince1970: Double(ts)) }
        else { self.createdAt = nil }
        if let ts = json["updated_at"] as? Double { self.updatedAt = Date(timeIntervalSince1970: ts) }
        else if let ts = json["updated_at"] as? Int { self.updatedAt = Date(timeIntervalSince1970: Double(ts)) }
        else { self.updatedAt = nil }

        let meta = json["meta"] as? [String: Any] ?? [:]
        self.description = meta["description"] as? String
        self.profileImageURL = meta["profile_image_url"] as? String
        self.ttsVoice = meta["tts_voice"] as? String ?? ""

        if let tagArray = meta["tags"] as? [[String: Any]] {
            self.tags = tagArray.compactMap { $0["name"] as? String }
        } else if let tagArray = meta["tags"] as? [String] {
            self.tags = tagArray
        } else { self.tags = [] }

        if let arr = meta["suggestion_prompts"] as? [[String: Any]] {
            self.suggestionPrompts = arr.compactMap { SuggestionPrompt(json: $0) }
        } else { self.suggestionPrompts = [] }

        if let kArr = meta["knowledge"] as? [[String: Any]] {
            self.knowledgeItems = kArr.compactMap { ModelKnowledgeEntry(json: $0) }
        } else { self.knowledgeItems = [] }

        let caps = meta["capabilities"] as? [String: Any] ?? [:]
        self.capVision = caps["vision"] as? Bool ?? true
        self.capFileUpload = caps["file_upload"] as? Bool ?? true
        self.capFileContext = caps["file_context"] as? Bool ?? true
        self.capWebSearch = caps["web_search"] as? Bool ?? true
        self.capImageGeneration = caps["image_generation"] as? Bool ?? true
        self.capCodeInterpreter = caps["code_interpreter"] as? Bool ?? true
        self.capUsage = caps["usage"] as? Bool ?? true
        self.capCitations = caps["citations"] as? Bool ?? true
        self.capStatusUpdates = caps["status_updates"] as? Bool ?? true
        self.capBuiltinTools = caps["builtin_tools"] as? Bool ?? true

        let defF = meta["defaultFeatureIds"] as? [String] ?? []
        self.defaultFeatureWebSearch = defF.contains("web_search")
        self.defaultFeatureImageGen = defF.contains("image_generation")
        self.defaultFeatureCodeInterpreter = defF.contains("code_interpreter")

        let bt = meta["builtinTools"] as? [String: Any] ?? [:]
        self.builtinTime = bt["time"] as? Bool ?? true
        self.builtinMemory = bt["memory"] as? Bool ?? true
        self.builtinChats = bt["chats"] as? Bool ?? true
        self.builtinNotes = bt["notes"] as? Bool ?? true
        self.builtinKnowledge = bt["knowledge"] as? Bool ?? true
        self.builtinChannels = bt["channels"] as? Bool ?? true
        self.builtinWebSearch = bt["web_search"] as? Bool ?? true
        self.builtinImageGen = bt["image_generation"] as? Bool ?? true
        self.builtinCodeInterpreter = bt["code_interpreter"] as? Bool ?? true

        let params = json["params"] as? [String: Any] ?? [:]
        self.systemPrompt = params["system"] as? String ?? ""
        self.advStreamResponse = params["stream_response"] as? Bool
        self.advStreamDeltaChunkSize = params["stream_delta_chunk_size"] as? Int
        self.advFunctionCalling = params["function_calling"] as? String
        self.advReasoningEffort = params["reasoning_effort"] as? String
        if let rtags = params["reasoning_tags"] as? [String], rtags.count >= 2 {
            self.advReasoningTagStart = rtags[0]; self.advReasoningTagEnd = rtags[1]
        } else {
            self.advReasoningTagStart = params["reasoning_tag_start"] as? String
            self.advReasoningTagEnd = params["reasoning_tag_end"] as? String
        }
        self.advSeed = params["seed"] as? Int
        self.advStopSequences = params["stop"] as? [String]
        self.advTemperature = params["temperature"] as? Double
        self.advLogitBias = params["logit_bias"] as? String
        self.advMaxTokens = params["max_tokens"] as? Int
        self.advTopK = params["top_k"] as? Int
        self.advTopP = params["top_p"] as? Double
        self.advMinP = params["min_p"] as? Double
        self.advFrequencyPenalty = params["frequency_penalty"] as? Double
        self.advPresencePenalty = params["presence_penalty"] as? Double
        self.advMirostat = params["mirostat"] as? Int
        self.advMirostatEta = params["mirostat_eta"] as? Double
        self.advMirostatTau = params["mirostat_tau"] as? Double
        self.advRepeatLastN = params["repeat_last_n"] as? Int
        self.advTfsZ = params["tfs_z"] as? Double
        self.advRepeatPenalty = params["repeat_penalty"] as? Double
        self.advUseMmap = params["use_mmap"] as? Bool
        self.advUseMlock = params["use_mlock"] as? Bool
        self.advThink = params["think"] as? Bool
        self.advFormat = params["format"] as? String
        self.advNumKeep = params["num_keep"] as? Int
        self.advNumCtx = params["num_ctx"] as? Int
        self.advNumBatch = params["num_batch"] as? Int
        self.advNumThread = params["num_thread"] as? Int
        self.advNumGpu = params["num_gpu"] as? Int
        self.advKeepAlive = params["keep_alive"] as? String

        let knownParamKeys: Set<String> = [
            "system", "stream_response", "stream_delta_chunk_size", "function_calling",
            "reasoning_effort", "reasoning_tags", "reasoning_tag_start", "reasoning_tag_end",
            "seed", "stop", "temperature", "logit_bias", "max_tokens", "top_k", "top_p",
            "min_p", "frequency_penalty", "presence_penalty", "mirostat", "mirostat_eta",
            "mirostat_tau", "repeat_last_n", "tfs_z", "repeat_penalty", "use_mmap", "use_mlock",
            "think", "format", "num_keep", "num_ctx", "num_batch", "num_thread", "num_gpu", "keep_alive"
        ]
        self.customParams = params.filter { !knownParamKeys.contains($0.key) }
            .map { (key: $0.key, value: "\($0.value)") }.sorted { $0.key < $1.key }
    }

    // MARK: - Payload Builders

    func buildParamsPayload() -> [String: Any] {
        var p: [String: Any] = [:]
        if !systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty { p["system"] = systemPrompt }
        if let v = advStreamResponse { p["stream_response"] = v }
        if let v = advStreamDeltaChunkSize { p["stream_delta_chunk_size"] = v }
        if let v = advFunctionCalling, !v.isEmpty { p["function_calling"] = v }
        if let v = advReasoningEffort, !v.isEmpty { p["reasoning_effort"] = v }
        if let s = advReasoningTagStart, let e = advReasoningTagEnd { p["reasoning_tags"] = [s, e] }
        if let v = advSeed { p["seed"] = v }
        if let stops = advStopSequences, !stops.isEmpty { p["stop"] = stops }
        if let v = advTemperature { p["temperature"] = v }
        if let v = advLogitBias, !v.isEmpty { p["logit_bias"] = v }
        if let v = advMaxTokens { p["max_tokens"] = v }
        if let v = advTopK { p["top_k"] = v }
        if let v = advTopP { p["top_p"] = v }
        if let v = advMinP { p["min_p"] = v }
        if let v = advFrequencyPenalty { p["frequency_penalty"] = v }
        if let v = advPresencePenalty { p["presence_penalty"] = v }
        if let v = advMirostat { p["mirostat"] = v }
        if let v = advMirostatEta { p["mirostat_eta"] = v }
        if let v = advMirostatTau { p["mirostat_tau"] = v }
        if let v = advRepeatLastN { p["repeat_last_n"] = v }
        if let v = advTfsZ { p["tfs_z"] = v }
        if let v = advRepeatPenalty { p["repeat_penalty"] = v }
        if let v = advUseMmap { p["use_mmap"] = v }
        if let v = advUseMlock { p["use_mlock"] = v }
        if let v = advThink { p["think"] = v }
        if let v = advFormat, !v.isEmpty { p["format"] = v }
        if let v = advNumKeep { p["num_keep"] = v }
        if let v = advNumCtx { p["num_ctx"] = v }
        if let v = advNumBatch { p["num_batch"] = v }
        if let v = advNumThread { p["num_thread"] = v }
        if let v = advNumGpu { p["num_gpu"] = v }
        if let v = advKeepAlive, !v.isEmpty { p["keep_alive"] = v }
        for cp in customParams where !cp.key.isEmpty { p[cp.key] = cp.value }
        return p
    }

    func buildMetaPayload() -> [String: Any] {
        var meta: [String: Any] = [:]
        meta["profile_image_url"] = profileImageURL ?? "/static/favicon.png"
        meta["description"] = description.flatMap { $0.isEmpty ? nil : $0 } as Any? ?? NSNull()
        meta["tags"] = tags.map { ["name": $0] }
        meta["capabilities"] = [
            "vision": capVision, "file_upload": capFileUpload, "file_context": capFileContext,
            "web_search": capWebSearch, "image_generation": capImageGeneration,
            "code_interpreter": capCodeInterpreter, "usage": capUsage,
            "citations": capCitations, "status_updates": capStatusUpdates, "builtin_tools": capBuiltinTools
        ]
        var defF: [String] = []
        if defaultFeatureWebSearch { defF.append("web_search") }
        if defaultFeatureImageGen { defF.append("image_generation") }
        if defaultFeatureCodeInterpreter { defF.append("code_interpreter") }
        meta["defaultFeatureIds"] = defF
        meta["builtinTools"] = [
            "time": builtinTime, "memory": builtinMemory, "chats": builtinChats,
            "notes": builtinNotes, "knowledge": builtinKnowledge, "channels": builtinChannels,
            "web_search": builtinWebSearch, "image_generation": builtinImageGen,
            "code_interpreter": builtinCodeInterpreter
        ]
        meta["knowledge"] = knowledgeItems.map { ["type": $0.type.rawValue, "id": $0.id, "name": $0.name] }
        meta["suggestion_prompts"] = suggestionPrompts.isEmpty
            ? NSNull()
            : suggestionPrompts.map { $0.toJSON() }
        if !ttsVoice.trimmingCharacters(in: .whitespaces).isEmpty { meta["tts_voice"] = ttsVoice }
        return meta
    }

    func toCreatePayload() -> [String: Any] {
        var body: [String: Any] = [
            "id": id, "name": name,
            "meta": buildMetaPayload(),
            "params": buildParamsPayload(),
            "is_active": isActive,
            "access_grants": buildGrantsPayload()
        ]
        if let base = baseModelId, !base.isEmpty { body["base_model_id"] = base }
        return body
    }

    func toUpdatePayload() -> [String: Any] { toCreatePayload() }

    func buildGrantsPayload() -> [[String: Any]] {
        var result: [[String: Any]] = []
        for grant in accessGrants {
            guard let uid = grant.userId else { continue }
            result.append(["principal_type": "user", "principal_id": uid, "permission": "read"])
            if grant.write {
                result.append(["principal_type": "user", "principal_id": uid, "permission": "write"])
            }
        }
        return result
    }

    func toModelItem() -> ModelItem {
        ModelItem(id: id, name: name, description: description, isActive: isActive,
                  profileImageURL: profileImageURL, baseModelId: baseModelId, tags: tags,
                  writeAccess: writeAccess, userId: userId, createdAt: createdAt, updatedAt: updatedAt)
    }
}
