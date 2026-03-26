import Foundation
import os.log

/// Manages Models CRUD operations for the workspace.
@Observable
final class ModelManager {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "Models")

    // MARK: - State

    var models: [ModelItem] = []
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
            models = try await apiClient.listWorkspaceModels()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Get Detail

    func getDetail(id: String) async throws -> ModelDetail {
        try await apiClient.getWorkspaceModelDetail(id: id)
    }

    // MARK: - Create

    @discardableResult
    func create(from detail: ModelDetail) async throws -> ModelDetail {
        let json = try await apiClient.createWorkspaceModel(payload: detail.toCreatePayload())
        guard let created = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        models.append(created.toModelItem())
        return created
    }

    // MARK: - Update

    @discardableResult
    func update(_ detail: ModelDetail) async throws -> ModelDetail {
        let json = try await apiClient.updateWorkspaceModel(payload: detail.toUpdatePayload())
        guard let updated = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        if let idx = models.firstIndex(where: { $0.id == detail.id }) {
            models[idx] = updated.toModelItem()
        }
        return updated
    }

    // MARK: - Delete

    func delete(id: String) async throws {
        try await apiClient.deleteWorkspaceModel(id: id)
        models.removeAll { $0.id == id }
    }

    // MARK: - Toggle Active

    @discardableResult
    func toggle(id: String) async throws -> ModelItem {
        let json = try await apiClient.toggleWorkspaceModel(id: id)
        guard let updated = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        let item = updated.toModelItem()
        if let idx = models.firstIndex(where: { $0.id == id }) {
            models[idx] = item
        }
        return item
    }

    // MARK: - Clone

    @discardableResult
    func clone(id: String) async throws -> ModelDetail {
        let source = try await getDetail(id: id)
        // Generate new ID and name
        let cloneId = source.id + "-clone"
        let cloneName = source.name + " (Clone)"
        // Build the payload from the source model
        var payload = source.toCreatePayload()
        payload["id"] = cloneId
        payload["name"] = cloneName
        payload["access_grants"] = [] as [[String: Any]]
        let json = try await apiClient.createWorkspaceModel(payload: payload)
        guard let created = ModelDetail(json: json) else {
            throw ModelManagerError.invalidResponse
        }
        models.append(created.toModelItem())
        return created
    }

    // MARK: - Export All

    func exportAll() async throws -> Data {
        let items = try await apiClient.exportWorkspaceModels()
        return try JSONSerialization.data(withJSONObject: items, options: .prettyPrinted)
    }

    // MARK: - Access Grants

    @discardableResult
    func updateAccessGrants(modelId: String, modelName: String, grants: [AccessGrant], isPublic: Bool = false) async throws -> [AccessGrant] {
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
        let json = try await apiClient.updateModelAccessGrants(id: modelId, name: modelName, grants: payload)
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

enum ModelManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The server returned an unexpected response."
    }
}
