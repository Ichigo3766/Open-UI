import Foundation
import os.log

/// Manages knowledge base CRUD operations and caches the list for the workspace.
/// Registered in `AppDependencyContainer` and shared across all views.
@Observable
final class KnowledgeManager {
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.openui", category: "Knowledge")

    // MARK: - State

    /// Flat list of all knowledge bases (used by the workspace list and the `#` picker).
    var knowledgeBases: [KnowledgeItem] = []
    /// All server users (used for the access-control user picker in the editor).
    var allUsers: [ChannelMember] = []
    var isLoading = false
    var error: String?

    // MARK: - Init

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Fetch

    /// Loads all knowledge bases. Called on workspace open and after any mutation.
    /// File counts are fetched via the paginated `/files?page=1` endpoint in parallel,
    /// so they reflect files added from any client (app or web UI), not the stale
    /// list-endpoint value which often returns null or an empty array.
    func fetchAll() async {
        isLoading = true
        error = nil
        do {
            let raw = try await apiClient.getKnowledgeBases()

            // Build items without file counts first so the list appears immediately.
            let items: [KnowledgeItem] = raw.compactMap { entry -> KnowledgeItem? in
                guard let id = entry["id"] as? String,
                      let name = entry["name"] as? String else { return nil }
                return KnowledgeItem(
                    id: id,
                    name: name,
                    description: entry["description"] as? String,
                    type: .collection,
                    fileCount: nil
                )
            }
            knowledgeBases = items

            // Fetch accurate file counts in parallel from the paginated files endpoint.
            // The list endpoint's `files` field is unreliable (often null or empty).
            let counts: [(String, Int)] = await withTaskGroup(of: (String, Int).self) { group in
                for item in items {
                    group.addTask { [weak self] in
                        guard let self else { return (item.id, 0) }
                        let count = (try? await self.apiClient.getKnowledgeFileCount(item.id)) ?? 0
                        return (item.id, count)
                    }
                }
                var results: [(String, Int)] = []
                for await result in group { results.append(result) }
                return results
            }

            // Merge counts back into the list by reconstructing each item with the fetched count.
            // (KnowledgeItem.fileCount is `let`, so we create a new value.)
            let countMap = Dictionary(uniqueKeysWithValues: counts)
            knowledgeBases = items.map { item in
                KnowledgeItem(
                    id: item.id,
                    name: item.name,
                    description: item.description,
                    type: item.type,
                    fileCount: countMap[item.id]
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Create

    @discardableResult
    func createKnowledge(from detail: KnowledgeDetail) async throws -> KnowledgeDetail {
        let payload = detail.toCreatePayload()
        let json = try await apiClient.createKnowledge(payload: payload)
        guard let created = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        await fetchAll()
        return created
    }

    // MARK: - Read

    func getDetail(id: String) async throws -> KnowledgeDetail {
        let json = try await apiClient.getKnowledgeById(id)
        guard let detail = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        return detail
    }

    // MARK: - Update

    @discardableResult
    func updateKnowledge(_ detail: KnowledgeDetail) async throws -> KnowledgeDetail {
        let payload = detail.toUpdatePayload()
        let json = try await apiClient.updateKnowledge(id: detail.id, payload: payload)
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        // Sync list entry
        if let idx = knowledgeBases.firstIndex(where: { $0.id == detail.id }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }

    // MARK: - Delete

    func deleteKnowledge(id: String) async throws {
        try await apiClient.deleteKnowledge(id: id)
        knowledgeBases.removeAll { $0.id == id }
    }

    // MARK: - Reset

    /// Removes all files from a knowledge base and re-processes it.
    @discardableResult
    func resetKnowledge(id: String) async throws -> KnowledgeDetail {
        let json = try await apiClient.resetKnowledge(id: id)
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        if let idx = knowledgeBases.firstIndex(where: { $0.id == id }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }

    // MARK: - File Management

    /// Fetches the files attached to a specific knowledge base.
    func getFiles(knowledgeId: String) async throws -> [KnowledgeFileEntry] {
        let raw = try await apiClient.getKnowledgeFilesForKB(knowledgeId)
        return raw.compactMap { KnowledgeFileEntry(json: $0) }
    }

    /// Uploads multiple files in parallel (each with server-side processing), then
    /// adds them all to the knowledge base individually.
    ///
    /// The batch-add endpoint (`/files/batch/add`) triggers a broken server-side
    /// `process_files_batch()` call on some OpenWebUI versions, so we use the
    /// individual `/file/add` endpoint instead. Uploads still run in parallel for speed.
    ///
    /// - Parameters:
    ///   - files: Array of (data, fileName) tuples to upload.
    ///   - knowledgeId: The knowledge base to add files to.
    ///   - onProgress: Called with a value 0…1 as uploads + adds complete.
    func uploadAndAddFilesBatch(
        files: [(data: Data, fileName: String)],
        knowledgeId: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        guard !files.isEmpty else { return }

        let total = Double(files.count)
        let counter = ProgressCounter()

        // Upload all files in parallel (each with ?process=true for server-side indexing),
        // then immediately add each to the knowledge base as soon as its upload finishes.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask { [self] in
                    // Upload with processing so the server extracts text/embeddings
                    let fileId = try await self.apiClient.uploadFile(
                        data: file.data,
                        fileName: file.fileName,
                        knowledgeId: knowledgeId
                    )
                    // Add to knowledge base
                    _ = try await self.apiClient.addFileToKnowledge(
                        knowledgeId: knowledgeId,
                        fileId: fileId
                    )
                    let completed = await counter.increment()
                    onProgress?(Double(completed) / total)
                }
            }
            for try await _ in group {}
        }

        onProgress?(1.0)

        // Sync list entry with updated file count
        if let idx = knowledgeBases.firstIndex(where: { $0.id == knowledgeId }) {
            let count = (try? await apiClient.getKnowledgeFileCount(knowledgeId)) ?? 0
            knowledgeBases[idx] = KnowledgeItem(
                id: knowledgeBases[idx].id,
                name: knowledgeBases[idx].name,
                description: knowledgeBases[idx].description,
                type: knowledgeBases[idx].type,
                fileCount: count
            )
        }
    }

    /// Uploads a file and then adds it to the knowledge base.
    /// Passes `knowledgeId` as metadata so the server can associate the file during upload.
    @discardableResult
    func uploadAndAddFile(
        fileData: Data,
        fileName: String,
        knowledgeId: String,
        onUploaded: ((String) -> Void)? = nil
    ) async throws -> KnowledgeDetail {
        // 1. Upload the file, passing knowledge_id metadata so the server indexes it correctly.
        let fileId = try await apiClient.uploadFile(
            data: fileData,
            fileName: fileName,
            knowledgeId: knowledgeId,
            onUploaded: onUploaded
        )
        // 2. Add to knowledge base
        let json = try await apiClient.addFileToKnowledge(
            knowledgeId: knowledgeId,
            fileId: fileId
        )
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        // Sync list entry with new file count
        if let idx = knowledgeBases.firstIndex(where: { $0.id == knowledgeId }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }

    /// Scrapes a web page and adds its content as a text file to the knowledge base.
    ///
    /// Flow:
    /// 1. POST /api/v1/retrieval/process/web?process=false → get scraped text
    /// 2. Upload text as a .txt file (with knowledge_id metadata)
    /// 3. POST /api/v1/knowledge/{id}/file/add
    @discardableResult
    func addWebPage(url: String, knowledgeId: String) async throws -> KnowledgeDetail {
        // 1. Scrape the web page
        let content = try await apiClient.processWebPage(url: url)

        // 2. Derive a filename from the URL
        let host = URL(string: url)?.host ?? "webpage"
        let sanitized = host.replacingOccurrences(of: "www.", with: "")
        let fileName = "\(sanitized).txt"

        // 3. Upload as a text file
        guard let fileData = content.data(using: .utf8) else {
            throw KnowledgeManagerError.invalidResponse
        }
        let fileId = try await apiClient.uploadFile(
            data: fileData,
            fileName: fileName,
            knowledgeId: knowledgeId
        )

        // 4. Add to knowledge base
        let json = try await apiClient.addFileToKnowledge(
            knowledgeId: knowledgeId,
            fileId: fileId
        )
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        if let idx = knowledgeBases.firstIndex(where: { $0.id == knowledgeId }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }

    /// Creates a plain-text file from `text` and adds it to the knowledge base.
    ///
    /// Flow:
    /// 1. Encode text as UTF-8 bytes
    /// 2. Upload as a .txt file (with knowledge_id metadata)
    /// 3. POST /api/v1/knowledge/{id}/file/add
    @discardableResult
    func addTextContent(
        text: String,
        title: String,
        knowledgeId: String
    ) async throws -> KnowledgeDetail {
        guard let fileData = text.data(using: .utf8) else {
            throw KnowledgeManagerError.invalidResponse
        }
        // Build a safe filename from the title
        let safe = title.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
        let fileName = safe.isEmpty ? "content.txt" : "\(safe).txt"

        let fileId = try await apiClient.uploadFile(
            data: fileData,
            fileName: fileName,
            knowledgeId: knowledgeId
        )

        let json = try await apiClient.addFileToKnowledge(
            knowledgeId: knowledgeId,
            fileId: fileId
        )
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        if let idx = knowledgeBases.firstIndex(where: { $0.id == knowledgeId }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }

    // MARK: - Access Grants

    /// Updates the access grants for a knowledge base.
    /// - Parameters:
    ///   - knowledgeId: The knowledge base ID.
    ///   - grants: The per-user access grants to persist.
    ///   - isPublic: If `true`, appends a wildcard `*` grant so all users can read (Public mode).
    /// Write access = TWO entries (one "read" + one "write") matching the web UI format.
    @discardableResult
    func updateAccessGrants(knowledgeId: String, grants: [AccessGrant], isPublic: Bool = false) async throws -> [AccessGrant] {
        var payload: [[String: Any]] = []
        for grant in grants {
            guard let userId = grant.userId else { continue }
            // Always include a "read" entry
            payload.append([
                "principal_type": "user",
                "principal_id": userId,
                "permission": "read"
            ])
            // For write access, also include a "write" entry
            if grant.write {
                payload.append([
                    "principal_type": "user",
                    "principal_id": userId,
                    "permission": "write"
                ])
            }
        }
        // Public mode: add wildcard grant so all users can read
        if isPublic {
            payload.append([
                "principal_type": "user",
                "principal_id": "*",
                "permission": "read"
            ])
        }
        let json = try await apiClient.updateKnowledgeAccessGrants(id: knowledgeId, grants: payload)
        if let grantsArray = json["access_grants"] as? [[String: Any]] {
            let raw = grantsArray.compactMap { AccessGrant.fromJSON($0) }
            let merged = AccessGrant.mergedByUser(raw)
            // Strip the wildcard entry from the local state — it's implicit in isPrivate = false
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

    /// Removes a file from a knowledge base (does not delete the underlying file).
    @discardableResult
    func removeFile(fileId: String, from knowledgeId: String) async throws -> KnowledgeDetail {
        let json = try await apiClient.removeFileFromKnowledge(
            knowledgeId: knowledgeId,
            fileId: fileId
        )
        guard let updated = KnowledgeDetail(json: json) else {
            throw KnowledgeManagerError.invalidResponse
        }
        if let idx = knowledgeBases.firstIndex(where: { $0.id == knowledgeId }) {
            knowledgeBases[idx] = updated.toKnowledgeItem()
        }
        return updated
    }
}

// MARK: - ProgressCounter

/// A simple actor that provides async-safe increment for tracking parallel upload progress.
private actor ProgressCounter {
    private var value: Int = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

// MARK: - Errors

enum KnowledgeManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an unexpected response."
        }
    }
}
