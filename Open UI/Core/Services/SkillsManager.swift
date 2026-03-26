import Foundation
import os.log

/// Manages Skills CRUD operations for the workspace.
@Observable
final class SkillsManager {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "Skills")

    // MARK: - State

    var skills: [SkillItem] = []
    var allUsers: [ChannelMember] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch All

    /// Fetches the skill list. Uses GET /api/v1/skills/list?page=1 (paginated).
    func fetchAll() async {
        isLoading = true
        error = nil
        do {
            skills = try await apiClient.getSkills()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Get Detail

    /// Fetches full skill detail (including content) via GET /api/v1/skills/id/{id}.
    func getDetail(id: String) async throws -> SkillDetail {
        return try await apiClient.getSkillDetail(id: id)
    }

    // MARK: - Create

    @discardableResult
    func createSkill(from detail: SkillDetail) async throws -> SkillDetail {
        let created = try await apiClient.createSkill(detail: detail)
        skills.append(created.toSkillItem())
        return created
    }

    // MARK: - Update

    @discardableResult
    func updateSkill(_ detail: SkillDetail) async throws -> SkillDetail {
        let updated = try await apiClient.updateSkill(detail: detail)
        if let idx = skills.firstIndex(where: { $0.id == detail.id }) {
            skills[idx] = updated.toSkillItem()
        }
        return updated
    }

    // MARK: - Toggle Active

    @discardableResult
    func toggleSkill(id: String) async throws -> SkillItem {
        let updated = try await apiClient.toggleSkill(id: id)
        if let idx = skills.firstIndex(where: { $0.id == id }) {
            skills[idx] = updated.toSkillItem()
        }
        return updated.toSkillItem()
    }

    // MARK: - Delete

    func deleteSkill(id: String) async throws {
        try await apiClient.deleteSkill(id: id)
        skills.removeAll { $0.id == id }
    }

    // MARK: - Clone

    /// Fetches full detail of an existing skill and creates a new copy with
    /// "-clone" appended to the ID and " (Clone)" appended to the name.
    @discardableResult
    func cloneSkill(id: String) async throws -> SkillDetail {
        let source = try await getDetail(id: id)
        let cloneDetail = SkillDetail(
            name: source.name + " (Clone)",
            slug: source.slug + "-clone",
            description: source.description,
            content: source.content,
            isActive: source.isActive,
            accessGrants: []
        )
        let created = try await createSkill(from: cloneDetail)
        return created
    }

    // MARK: - Export All

    /// Calls GET /api/v1/skills/export and returns JSON data ready for sharing.
    func exportAll() async throws -> Data {
        let details = try await apiClient.exportSkills()
        let payload = details.map { $0.toCreatePayload() }
        return try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
    }

    // MARK: - Access Grants

    @discardableResult
    func updateAccessGrants(skillId: String, grants: [AccessGrant], isPublic: Bool = false) async throws -> [AccessGrant] {
        var payload: [[String: Any]] = []
        for grant in grants {
            guard let userId = grant.userId else { continue }
            payload.append(["principal_type": "user", "principal_id": userId, "permission": "read"])
            if grant.write {
                payload.append(["principal_type": "user", "principal_id": userId, "permission": "write"])
            }
        }
        if isPublic {
            payload.append(["principal_type": "user", "principal_id": "*", "permission": "read"])
        }
        let json = try await apiClient.updateSkillAccessGrants(id: skillId, grants: payload)
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            let merged = AccessGrant.mergedByUser(raw)
            return merged.filter { $0.userId != "*" }
        }
        return grants
    }

    // MARK: - Users

    func fetchAllUsers() async {
        do {
            allUsers = try await apiClient.searchUsers()
        } catch {
            logger.warning("Failed to fetch users: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum SkillsManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The server returned an unexpected response."
    }
}
