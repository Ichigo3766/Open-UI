import Foundation
import os.log

/// Manages Tools CRUD operations for the workspace.
@Observable
final class ToolsManager {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "Tools")

    // MARK: - State

    var tools: [WorkspaceToolItem] = []
    var allUsers: [ChannelMember] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch All

    func fetchAll() async {
        isLoading = true
        error = nil
        do {
            tools = try await apiClient.getToolItems()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Get Detail

    func getDetail(id: String) async throws -> ToolDetail {
        return try await apiClient.getToolDetail(id: id)
    }

    // MARK: - Create

    @discardableResult
    func createTool(from detail: ToolDetail) async throws -> ToolDetail {
        let created = try await apiClient.createTool(detail: detail)
        tools.append(created.toWorkspaceToolItem())
        return created
    }

    // MARK: - Update

    @discardableResult
    func updateTool(_ detail: ToolDetail) async throws -> ToolDetail {
        let updated = try await apiClient.updateTool(detail: detail)
        if let idx = tools.firstIndex(where: { $0.id == detail.id }) {
            tools[idx] = updated.toWorkspaceToolItem()
        }
        return updated
    }

    // MARK: - Delete

    func deleteTool(id: String) async throws {
        try await apiClient.deleteTool(id: id)
        tools.removeAll { $0.id == id }
    }

    // MARK: - Clone

    @discardableResult
    func cloneTool(id: String) async throws -> ToolDetail {
        let source = try await getDetail(id: id)
        let cloneId = source.id + "-clone"
        let cloneDetail = ToolDetail(
            id: cloneId,
            name: source.name + " (Clone)",
            content: source.content,
            description: source.description,
            manifest: source.manifest,
            accessGrants: []
        )
        let created = try await createTool(from: cloneDetail)
        return created
    }

    // MARK: - Export All

    func exportAll() async throws -> Data {
        let details = try await apiClient.exportTools()
        let payload = details.map { $0.toCreatePayload() }
        return try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
    }

    // MARK: - Access Grants

    @discardableResult
    func updateAccessGrants(toolId: String, grants: [AccessGrant], isPublic: Bool = false) async throws -> [AccessGrant] {
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
        let json = try await apiClient.updateToolAccessGrants(id: toolId, grants: payload)
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

    // MARK: - Valves

    func getValves(id: String) async throws -> [String: Any] {
        return try await apiClient.getToolValves(id: id)
    }

    func getValvesSpec(id: String) async throws -> [String: Any] {
        return try await apiClient.getToolValvesSpec(id: id)
    }

    /// Same as getValvesSpec but also returns the insertion-ordered property keys
    /// parsed from the raw JSON bytes — needed so the UI can match OpenWebUI's ordering.
    func getValvesSpecWithOrder(id: String) async throws -> ([String: Any], [String]) {
        return try await apiClient.getToolValvesSpecOrdered(id: id)
    }

    func updateValves(id: String, values: [String: Any]) async throws -> [String: Any] {
        return try await apiClient.updateToolValves(id: id, values: values)
    }

    // MARK: - Import from URL

    func loadFromURL(url: String) async throws -> ToolDetail? {
        let json = try await apiClient.loadToolFromURL(url: url)
        // Full parse (works when server returns a complete tool object)
        if let detail = ToolDetail(json: json) { return detail }
        // Fallback: /api/v1/tools/load/url returns just {"name": "...", "content": "..."}
        guard let name = json["name"] as? String,
              let content = json["content"] as? String else { return nil }
        let slug = name
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return ToolDetail(id: slug, name: name, content: content)
    }
}
