import Foundation

/// Manages prompt CRUD operations and caches the prompts list for the workspace.
/// Registered in `AppDependencyContainer` and shared across all views.
@Observable
final class PromptManager {
    private let apiClient: APIClient

    // MARK: - State

    /// Flat list of all prompts (used by the workspace list and the `/` picker).
    var prompts: [PromptItem] = []
    /// All unique tags across prompts (for filter chips).
    var allTags: [String] = []
    /// All server users (used for the access-control user picker in the editor).
    var allUsers: [ChannelMember] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch

    /// Loads all prompts. Called on workspace open and after any mutation.
    func fetchPrompts() async {
        isLoading = true
        error = nil
        do {
            let raw = try await apiClient.getPrompts()
            prompts = raw.compactMap { PromptItem(json: $0) }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Loads all tags. Called once on workspace open.
    func fetchTags() async {
        do {
            allTags = try await apiClient.getPromptTags()
        } catch {
            // Non-critical — tags can be derived from existing prompts
            allTags = Array(Set(prompts.flatMap { $0.tags })).sorted()
        }
    }

    // MARK: - Create

    /// Creates a new prompt and updates the local list.
    @discardableResult
    func createPrompt(from detail: PromptDetail, commitMessage: String = "") async throws -> PromptDetail {
        let payload = detail.toCreatePayload(commitMessage: commitMessage)
        let json = try await apiClient.createPrompt(payload: payload)
        guard let created = PromptDetail(json: json) else {
            throw PromptManagerError.invalidResponse
        }
        await fetchPrompts()
        await fetchTags()
        return created
    }

    // MARK: - Read

    /// Fetches a full prompt detail by ID (includes access control, meta).
    func getPromptDetail(id: String) async throws -> PromptDetail {
        let json = try await apiClient.getPromptById(id)
        guard let detail = PromptDetail(json: json) else {
            throw PromptManagerError.invalidResponse
        }
        return detail
    }

    // MARK: - Update

    /// Updates an existing prompt and refreshes the local list.
    @discardableResult
    func updatePrompt(_ detail: PromptDetail, commitMessage: String = "") async throws -> PromptDetail {
        let payload = detail.toUpdatePayload(commitMessage: commitMessage)
        let json = try await apiClient.updatePrompt(id: detail.id, payload: payload)
        guard let updated = PromptDetail(json: json) else {
            throw PromptManagerError.invalidResponse
        }
        await fetchPrompts()
        await fetchTags()
        return updated
    }

    // MARK: - Delete

    func deletePrompt(id: String) async throws {
        try await apiClient.deletePrompt(id: id)
        prompts.removeAll { $0.id == id }
        // Refresh tags since deleted prompt may have had unique tags
        allTags = Array(Set(prompts.flatMap { $0.tags })).sorted()
    }

    // MARK: - Toggle

    /// Toggles a prompt's active/inactive state. Uses optimistic UI update.
    func togglePrompt(id: String) async throws {
        // Optimistic update
        if let idx = prompts.firstIndex(where: { $0.id == id }) {
            let current = prompts[idx]
            // Rebuild with toggled state (PromptItem is a struct)
            var json: [String: Any] = [
                "id": current.id,
                "command": current.command,
                "name": current.name,
                "content": current.content,
                "user_id": current.userId,
                "tags": current.tags,
                "is_active": !current.isActive
            ]
            if let cd = current.createdAt { json["created_at"] = cd.timeIntervalSince1970 }
            if let ud = current.updatedAt { json["updated_at"] = ud.timeIntervalSince1970 }
            if let updated = PromptItem(json: json) {
                prompts[idx] = updated
            }
        }

        do {
            _ = try await apiClient.togglePrompt(id: id)
        } catch {
            // Revert on failure
            await fetchPrompts()
            throw error
        }
    }

    // MARK: - Version History

    /// Fetches version history for a prompt.
    func getHistory(promptId: String) async throws -> [PromptVersion] {
        let raw = try await apiClient.getPromptHistory(id: promptId)
        return raw.compactMap { PromptVersion(json: $0) }
    }

    /// Sets a specific history version as the production (live) version.
    /// Calls `POST /api/v1/prompts/id/{id}/update_version` with `{"version_id": "..."}`.
    /// After success, refreshes the local prompts list so the list view reflects changes.
    @discardableResult
    func setProductionVersion(promptId: String, versionId: String) async throws -> [String: Any] {
        let result = try await apiClient.setPromptVersion(id: promptId, versionId: versionId)
        await fetchPrompts()
        return result
    }

    // MARK: - Access Grants

    /// Updates the access grants for a prompt.
    /// - `isPublic: true` → appends a wildcard `{"principal_id": "*", "permission": "read"}` grant (Public)
    /// - `isPublic: false` (default) → sends only explicit user grants (Private)
    /// Returns the updated list of access grants from the server response (wildcard excluded from local state).
    @discardableResult
    func updateAccessGrants(promptId: String, grants: [AccessGrant], isPublic: Bool = false) async throws -> [AccessGrant] {
        // Web UI format: write access = TWO entries (one "read" + one "write") per user.
        var payload: [[String: Any]] = []
        for grant in grants {
            guard let userId = grant.userId else { continue }
            payload.append(["principal_type": "user", "principal_id": userId, "permission": "read"])
            if grant.write {
                payload.append(["principal_type": "user", "principal_id": userId, "permission": "write"])
            }
        }
        // Public mode: append the wildcard grant so everyone can read
        if isPublic {
            payload.append(["principal_type": "user", "principal_id": "*", "permission": "read"])
        }
        let json = try await apiClient.updatePromptAccessGrants(id: promptId, grants: payload)
        // Parse updated access_grants from response — merge read+write entries, exclude wildcard from local state
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            let merged = AccessGrant.mergedByUser(raw)
            // Filter out the wildcard entry — it's represented by `isPrivate` in the UI, not the grants list
            return merged.filter { $0.userId != "*" }
        }
        return grants
    }

    // MARK: - Users

    /// Fetches all server users for the access-control picker.
    func fetchAllUsers() async {
        do {
            allUsers = try await apiClient.searchUsers()
        } catch {
            // Non-critical — editor will show empty picker if this fails
        }
    }

    // MARK: - Clone

    /// Creates a copy of a prompt with a modified name and unique command.
    @discardableResult
    func clonePrompt(id: String) async throws -> PromptDetail {
        let detail = try await getPromptDetail(id: id)
        let clonedName = "Copy of \(detail.name)"
        let baseCommand = "copy-of-\(detail.command)"
        // Ensure the command is unique by appending a counter if needed
        var command = baseCommand
        var counter = 2
        while prompts.contains(where: { $0.command == command }) {
            command = "\(baseCommand)-\(counter)"
            counter += 1
        }
        let cloned = PromptDetail(
            command: command,
            name: clonedName,
            content: detail.content,
            isActive: detail.isActive,
            tags: detail.tags,
            accessGrants: []
        )
        return try await createPrompt(from: cloned, commitMessage: "Cloned from \(detail.name)")
    }

    // MARK: - Export All

    /// Returns a JSON Data blob containing all prompts (name, command, content, tags).
    /// Fetches full detail for each prompt so content is included.
    func exportAll() async throws -> Data {
        var result: [[String: Any]] = []
        for item in prompts {
            if let detail = try? await getPromptDetail(id: item.id) {
                result.append(detail.toCreatePayload())
            }
        }
        return try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
    }

    // MARK: - Convenience

    /// Returns the first prompt matching the given command (without the leading `/`).
    func prompt(forCommand command: String) -> PromptItem? {
        let normalized = command.hasPrefix("/") ? String(command.dropFirst()) : command
        return prompts.first { $0.command == normalized }
    }
}

// MARK: - Errors

enum PromptManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an unexpected response."
        }
    }
}
