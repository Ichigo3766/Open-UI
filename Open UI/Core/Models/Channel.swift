import Foundation

// MARK: - Channel Types

/// The type of channel (standard topic-based, group membership, or direct message).
enum ChannelType: String, Codable, Sendable {
    case standard
    case group
    case dm
    
    /// Display label for UI.
    var displayName: String {
        switch self {
        case .standard: return "Channel"
        case .group: return "Group"
        case .dm: return "Direct Message"
        }
    }
    
    /// SF Symbol icon for the channel type.
    var iconName: String {
        switch self {
        case .standard: return "number"
        case .group: return "person.3"
        case .dm: return "person.crop.circle"
        }
    }
}

// MARK: - Channel Model

/// Represents a Channel in Open WebUI — a persistent, topic-based room
/// where multiple users and AI models can interact in a shared timeline.
struct Channel: Identifiable, Hashable, Sendable {
    let id: String
    let userId: String
    var type: ChannelType
    var name: String
    var description: String?
    var isPrivate: Bool
    var data: [String: Any]?
    var meta: [String: Any]?
    var accessGrants: [AccessGrant]
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: String?
    var archivedAt: Date?
    /// Server-computed write access — `true` means the current user can post. Nil if not yet loaded.
    var writeAccess: Bool?
    
    // Local-only state
    var unreadCount: Int = 0
    var lastMessage: ChannelMessage?
    /// For DM channels: the other participants' info
    var dmParticipants: [ChannelMember] = []
    /// Whether this DM is hidden from the sidebar (preserves message history).
    var isHiddenDM: Bool = false
    
    init(
        id: String,
        userId: String,
        type: ChannelType = .standard,
        name: String,
        description: String? = nil,
        isPrivate: Bool = false,
        data: [String: Any]? = nil,
        meta: [String: Any]? = nil,
        accessGrants: [AccessGrant] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        updatedBy: String? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.type = type
        self.name = name
        self.description = description
        self.isPrivate = isPrivate
        self.data = data
        self.meta = meta
        self.accessGrants = accessGrants
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.archivedAt = archivedAt
    }
    
    /// Display name for the channel — DMs show participant names.
    var displayName: String {
        if type == .dm && !dmParticipants.isEmpty {
            return dmParticipants.map { $0.name ?? $0.email }.joined(separator: ", ")
        }
        return name
    }
    
    /// Icon name for sidebar display.
    var sidebarIcon: String {
        if isPrivate { return "lock" }
        return type.iconName
    }
    
    /// Whether the current user has write access.
    /// Trusts the server-computed `write_access` field exclusively.
    /// Returns `true` (permissive default) only when the server hasn't sent the field yet.
    var canWrite: Bool {
        writeAccess ?? true
    }
    
    // MARK: - Hashable (consistent == and hash)
    // R-019: Align == and hash(into:) to use the same fields.
    
    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
            && lhs.type == rhs.type
            && lhs.name == rhs.name
            && lhs.updatedAt == rhs.updatedAt
            && lhs.unreadCount == rhs.unreadCount
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(type)
        hasher.combine(name)
        hasher.combine(updatedAt)
        hasher.combine(unreadCount)
    }
    
    // MARK: - Parsing
    
    static func fromJSON(_ json: [String: Any]) -> Channel? {
        guard let id = json["id"] as? String,
              let userId = json["user_id"] as? String,
              let name = json["name"] as? String
        else { return nil }
        
        let typeStr = json["type"] as? String ?? "standard"
        let type = ChannelType(rawValue: typeStr) ?? .standard
        
        let description = json["description"] as? String
        let isPrivate = json["is_private"] as? Bool ?? false
        let data = json["data"] as? [String: Any]
        let meta = json["meta"] as? [String: Any]
        
        var accessGrants: [AccessGrant] = []
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            accessGrants = grantsArray.compactMap { AccessGrant.fromJSON($0) }
        }
        
        // R-013: Use shared TimestampParser
        let createdAt = TimestampParser.parse(json["created_at"])
        let updatedAt = TimestampParser.parse(json["updated_at"])
        let updatedBy = json["updated_by"] as? String
        let archivedAt = TimestampParser.parseOptional(json["archived_at"])
        
        let unreadCount = json["unread_count"] as? Int ?? 0
        let lastMessage = (json["last_message"] as? [String: Any]).flatMap { ChannelMessage.fromJSON($0) }
        
        var channel = Channel(
            id: id,
            userId: userId,
            type: type,
            name: name,
            description: description,
            isPrivate: isPrivate,
            data: data,
            meta: meta,
            accessGrants: accessGrants,
            createdAt: createdAt,
            updatedAt: updatedAt,
            updatedBy: updatedBy,
            archivedAt: archivedAt
        )
        channel.unreadCount = unreadCount
        channel.lastMessage = lastMessage
        // Trust server's computed write permission directly
        channel.writeAccess = json["write_access"] as? Bool
        return channel
    }
}

// MARK: - Access Grant

struct AccessGrant: Identifiable, Hashable, Sendable {
    let id: String
    let userId: String?
    let groupId: String?
    let read: Bool
    let write: Bool
    
    static func fromJSON(_ json: [String: Any]) -> AccessGrant? {
        let id = json["id"] as? String ?? UUID().uuidString
        
        // Server returns "principal_id" + "principal_type" for access grants.
        // Fall back to legacy "user_id" / "group_id" keys for compatibility.
        let principalType = json["principal_type"] as? String
        let principalId = json["principal_id"] as? String
        
        let userId: String?
        let groupId: String?
        
        if principalType == "group" {
            userId = json["user_id"] as? String
            groupId = principalId ?? (json["group_id"] as? String)
        } else {
            // Default to "user" principal type
            userId = principalId ?? (json["user_id"] as? String)
            groupId = json["group_id"] as? String
        }
        
        // Parse permission string ("read" / "write") or legacy booleans
        let permission = json["permission"] as? String
        let read: Bool
        let write: Bool
        if let permission {
            write = permission == "write"
            read = true
        } else {
            read = json["read"] as? Bool ?? true
            write = json["write"] as? Bool ?? true
        }
        
        return AccessGrant(id: id, userId: userId, groupId: groupId, read: read, write: write)
    }

    /// Merges a flat list of access grant entries into one `AccessGrant` per user.
    /// The server uses two entries (one "read" + one "write") to represent write access.
    /// This collapses them: a user gets `write = true` if ANY entry has permission "write".
    static func mergedByUser(_ grants: [AccessGrant]) -> [AccessGrant] {
        var byUser: [String: AccessGrant] = [:]
        for grant in grants {
            guard let uid = grant.userId else { continue }
            if let existing = byUser[uid] {
                if grant.write && !existing.write {
                    byUser[uid] = AccessGrant(id: existing.id, userId: uid, groupId: existing.groupId, read: true, write: true)
                }
            } else {
                byUser[uid] = grant
            }
        }
        return Array(byUser.values)
    }
}

// MARK: - Channel Member

/// A user who is a member of a channel.
struct ChannelMember: Identifiable, Hashable, Sendable {
    let id: String
    var name: String?
    var email: String
    var profileImageURL: String?
    var role: String?
    var isActive: Bool
    var lastActiveAt: Date?
    
    var displayName: String {
        name ?? email
    }
    
    /// Whether the user was recently active (within 5 minutes).
    var isOnline: Bool {
        guard let lastActive = lastActiveAt else { return false }
        return Date().timeIntervalSince(lastActive) < 300
    }
    
    /// Resolves the correct avatar URL for this member.
    /// Always uses the `/api/v1/users/{id}/profile/image` endpoint which
    /// returns the current avatar dynamically (same as the Admin Console).
    /// The endpoint works for ALL users regardless of whether profileImageURL is set.
    func resolveAvatarURL(serverBaseURL: String) -> URL? {
        // External URLs (e.g. Google OAuth avatars) → use directly
        if let urlString = profileImageURL, !urlString.isEmpty, urlString.hasPrefix("http") {
            return URL(string: urlString)
        }
        // Always use the profile image API endpoint — it works for every user
        // and returns the current avatar (base64, uploaded, or default).
        guard !serverBaseURL.isEmpty, !id.isEmpty else { return nil }
        return URL(string: "\(serverBaseURL)/api/v1/users/\(id)/profile/image")
    }
    
    static func fromJSON(_ json: [String: Any]) -> ChannelMember? {
        guard let id = json["id"] as? String else { return nil }
        let name = json["name"] as? String
        let email = json["email"] as? String ?? ""
        let profileImageURL = json["profile_image_url"] as? String
        let role = json["role"] as? String
        let isActive = json["is_active"] as? Bool ?? true
        
        // BUG-008 fix: Use shared TimestampParser for consistent ns/µs/ms/s handling
        let lastActiveAt = TimestampParser.parseOptional(json["last_active_at"])
        
        return ChannelMember(
            id: id,
            name: name,
            email: email,
            profileImageURL: profileImageURL,
            role: role,
            isActive: isActive,
            lastActiveAt: lastActiveAt
        )
    }
}
