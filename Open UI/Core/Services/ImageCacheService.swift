import SwiftUI
import os.log

/// A thread-safe, memory-efficient image cache with automatic eviction.
///
/// Uses `NSCache` under the hood for automatic memory pressure handling,
/// combined with a disk cache for persistence across launches. Images are
/// keyed by their URL string and stored as compressed `Data`.
///
/// Usage:
/// ```swift
/// let cache = ImageCacheService.shared
/// if let image = cache.image(for: url) { … }
/// cache.store(image, for: url)
/// ```
actor ImageCacheService {

    /// Shared singleton instance.
    static let shared = ImageCacheService()

    // MARK: - Private Storage

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.openui", category: "ImageCache")

    /// Maximum number of images to hold in memory.
    private let memoryCacheLimit = 100

    /// Maximum disk cache size in bytes (50 MB).
    private let diskCacheSizeLimit: Int = 50 * 1024 * 1024

    /// Active download tasks keyed by URL string to deduplicate requests.
    private var activeTasks: [String: Task<UIImage?, Never>] = [:]

    // MARK: - Cloudflare Support

    /// Custom headers (e.g. User-Agent) that must be sent with image requests
    /// to servers behind Cloudflare Bot Fight Mode. Set by DependencyContainer
    /// when configuring services for a CF-protected server.
    /// Thread-safe: only accessed from within the actor.
    private var cfCustomHeaders: [String: String]?

    /// The host of the CF-protected server, used to scope header injection
    /// to only requests targeting that server (not external image URLs).
    private var cfServerHost: String?

    /// Configures CF headers for image requests. Called by DependencyContainer.
    func configureCFHeaders(customHeaders: [String: String]?, serverHost: String?) {
        self.cfCustomHeaders = customHeaders
        self.cfServerHost = serverHost
    }

    // MARK: - Self-Signed Certificate Support

    /// Whether requests to the configured server host should bypass SSL validation.
    /// Set by DependencyContainer when `ServerConfig.allowSelfSignedCertificates` is true.
    private var allowSelfSignedCerts: Bool = false

    /// The server host scoped for self-signed cert bypass.
    /// Only requests targeting this host skip SSL validation — external URLs still use
    /// the system trust store so we don't weaken security for unrelated endpoints.
    private var selfSignedCertServerHost: String?

    /// Lazy custom URLSession that trusts self-signed certificates.
    /// Created once on first use and reused for all subsequent requests.
    /// Re-created when `configureSelfSignedCertSupport` is called with new settings.
    private var selfSignedSession: URLSession?

    /// Configures self-signed certificate support for image requests.
    /// Called by DependencyContainer when `ServerConfig.allowSelfSignedCertificates` changes.
    ///
    /// - Parameters:
    ///   - allowed: When `true`, image requests to `serverHost` will bypass SSL cert validation.
    ///   - serverHost: The server host (e.g. `"myserver.local"`) to scope the bypass to.
    func configureSelfSignedCertSupport(allowed: Bool, serverHost: String?) {
        self.allowSelfSignedCerts = allowed
        self.selfSignedCertServerHost = serverHost
        // Invalidate cached session so it's re-created with new settings on next use
        selfSignedSession?.invalidateAndCancel()
        selfSignedSession = nil
        logger.info("ImageCache: self-signed cert support \(allowed ? "enabled" : "disabled") for host \(serverHost ?? "none")")
    }

    /// Returns the URLSession to use for a given URL.
    /// Uses the self-signed-cert session when the URL targets the configured
    /// server host and `allowSelfSignedCerts` is enabled; otherwise uses `URLSession.shared`.
    private func session(for url: URL) -> URLSession {
        guard allowSelfSignedCerts,
              let targetHost = selfSignedCertServerHost,
              url.host?.lowercased() == targetHost.lowercased() else {
            return URLSession.shared
        }

        if let existing = selfSignedSession {
            return existing
        }

        let delegate = SelfSignedCertDelegate(serverHost: targetHost)
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        selfSignedSession = session
        return session
    }

    // MARK: - Init

    private init() {
        memoryCache.countLimit = memoryCacheLimit
        memoryCache.totalCostLimit = 30 * 1024 * 1024 // 30 MB
        // STORAGE FIX: Run eviction on init to trim any cache that grew
        // over the limit from a previous session. Dispatched as a Task
        // because actor-isolated methods can't be called from nonisolated init.
        Task { await self.evictDiskCacheIfNeeded() }
    }

    // MARK: - Public API

    /// Returns a cached image for the given URL, checking memory first
    /// then disk.
    ///
    /// - Parameter url: The image URL to look up.
    /// - Returns: The cached `UIImage`, or `nil` if not cached.
    func cachedImage(for url: URL) -> UIImage? {
        let key = cacheKey(for: url)

        // Memory cache lookup
        if let memoryImage = memoryCache.object(forKey: key as NSString) {
            return memoryImage
        }

        // Disk cache lookup
        if let diskImage = loadFromDisk(key: key) {
            // Promote to memory cache
            let cost = diskImage.jpegData(compressionQuality: 1.0)?.count ?? 0
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: cost)
            return diskImage
        }

        return nil
    }

    /// Loads an image from the given URL, using the cache if available.
    ///
    /// Deduplicates concurrent requests for the same URL. If a download
    /// is already in progress, callers share the same `Task`.
    ///
    /// - Parameters:
    ///   - url: The image URL to load.
    ///   - authToken: Optional Bearer token for authenticated endpoints
    ///     (e.g. the model avatar endpoint `/api/v1/models/model/profile/image`).
    ///   - customHeaders: Optional custom headers to include (e.g. Cloudflare User-Agent).
    /// - Returns: The loaded `UIImage`, or `nil` on failure.
    func loadImage(from url: URL, authToken: String? = nil, customHeaders: [String: String]? = nil) async -> UIImage? {
        let key = cacheKey(for: url)

        // Check caches first
        if let cached = cachedImage(for: url) {
            return cached
        }

        // Deduplicate in-flight requests
        if let existingTask = activeTasks[key] {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> {
            do {
                var request = URLRequest(url: url)
                if let authToken, !authToken.isEmpty {
                    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
                }
                // Apply custom headers (e.g. CF User-Agent) so Cloudflare
                // doesn't reject the request due to UA mismatch.
                // First: explicitly passed headers take priority.
                // Second: auto-apply CF headers for requests to the CF-protected server.
                var effectiveHeaders = customHeaders ?? [:]
                if effectiveHeaders.isEmpty,
                   let cfHeaders = self.cfCustomHeaders,
                   let cfHost = self.cfServerHost,
                   url.host?.lowercased() == cfHost.lowercased() {
                    effectiveHeaders = cfHeaders
                }
                for (key, value) in effectiveHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                // Use the appropriate URLSession:
                // - Self-signed cert servers: custom session with certificate bypass delegate
                // - All other servers: URLSession.shared (picks up cf_clearance cookies)
                let (data, response) = try await self.session(for: url).data(for: request)

                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? -1
                let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                
                print("[ImageCache] Response for \(url.lastPathComponent): status=\(statusCode), contentType=\(contentType), dataSize=\(data.count), authToken=\(authToken != nil ? "YES" : "NO")")
                
                guard let httpResponse,
                      (200...399).contains(httpResponse.statusCode),
                      let image = UIImage(data: data),
                      image.size.width > 0 && image.size.height > 0
                else {
                    if let httpResponse {
                        print("[ImageCache] FAILED for \(url.lastPathComponent): status=\(httpResponse.statusCode), body=\(String(data: data.prefix(200), encoding: .utf8) ?? "non-utf8")")
                    } else {
                        print("[ImageCache] FAILED for \(url.lastPathComponent): no HTTP response")
                    }
                    return nil
                }

                // Store in memory
                let cost = data.count
                memoryCache.setObject(image, forKey: key as NSString, cost: cost)

                // Store on disk asynchronously
                saveToDisk(data: data, key: key)

                return image
            } catch {
                logger.error("Image download failed for \(url): \(error.localizedDescription)")
                return nil
            }
        }

        activeTasks[key] = task
        let result = await task.value
        activeTasks.removeValue(forKey: key)

        return result
    }

    /// Prefetches images for the given URLs in the background.
    ///
    /// - Parameter urls: The image URLs to prefetch.
    func prefetch(urls: [URL]) {
        for url in urls {
            let key = cacheKey(for: url)
            guard memoryCache.object(forKey: key as NSString) == nil else { continue }

            Task {
                _ = await loadImage(from: url)
            }
        }
    }

    /// Stores an image in both memory and disk caches.
    ///
    /// - Parameters:
    ///   - image: The image to cache.
    ///   - url: The URL key for the image.
    func store(_ image: UIImage, for url: URL) {
        let key = cacheKey(for: url)
        let data = image.jpegData(compressionQuality: 0.85)
        let cost = data?.count ?? 0

        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        if let data {
            saveToDisk(data: data, key: key)
        }
    }

    /// Evicts all images from memory and disk caches.
    func clearAll() {
        memoryCache.removeAllObjects()
        clearDiskCache()
        logger.info("Image cache cleared")
    }

    /// Evicts the cached image for a specific URL from both memory and disk.
    ///
    /// Used to invalidate model avatars when models are refreshed, ensuring
    /// admin-updated avatar images are re-fetched from the server.
    func evict(for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.removeObject(forKey: key as NSString)
        if let directory = diskCacheDirectory {
            let fileURL = directory.appendingPathComponent(key)
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Evicts only the memory cache, preserving disk cache.
    func clearMemory() {
        memoryCache.removeAllObjects()
    }
    
    /// Evicts all cached profile images (user/model avatars) from both memory and disk.
    /// Call on app startup and logout/login to ensure fresh avatars.
    func evictProfileImages() {
        // Clear memory cache entirely — profile images reload quickly
        memoryCache.removeAllObjects()
        
        // Also remove profile images from disk cache
        guard let directory = diskCacheDirectory else { return }
        if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // We can't reverse the hash to check the URL, so clear the entire disk cache
            // on login/startup. This is acceptable since it only happens on explicit events.
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
        logger.info("Profile image cache invalidated — will re-fetch on next access")
    }
    
    /// Whether this URL points to a user or model profile image.
    /// Matches: `/api/v1/users/{id}/profile/image` and `/api/v1/models/{id}/profile/image`
    private func isProfileImageURL(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/profile/image")
    }

    /// STORAGE FIX: Proactively runs disk eviction without requiring a save.
    /// Called by StorageManager on app launch and when entering background
    /// to ensure the cache stays under its size limit between sessions.
    func evictDiskCacheProactively() {
        evictDiskCacheIfNeeded()
    }

    // MARK: - Disk Cache

    private var diskCacheDirectory: URL? {
        fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ImageCache", isDirectory: true)
    }

    private func cacheKey(for url: URL) -> String {
        // FIX: Use SHA256 instead of DJB2 to avoid hash collisions on similar URLs.
        // DJB2 has high collision rates for URLs that differ only in query parameters
        // (e.g., model avatar URLs with different model IDs).
        let urlString = url.absoluteString
        let data = Data(urlString.utf8)
        // Use a simple but collision-resistant hash: FNV-1a 128-bit equivalent
        // by combining two independent 64-bit hashes with different seeds.
        var h1 = UInt64(14695981039346656037) // FNV offset basis
        var h2 = UInt64(0xcbf29ce484222325)   // Secondary seed
        for byte in data {
            h1 ^= UInt64(byte)
            h1 &*= 1099511628211 // FNV prime
            h2 ^= UInt64(byte)
            h2 &*= 6364136223846793005
        }
        return String(h1, radix: 16) + String(h2, radix: 16)
    }

    private func saveToDisk(data: Data, key: String) {
        guard let directory = diskCacheDirectory else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(key)
            try data.write(to: fileURL, options: .atomic)
            // Evict oldest entries if disk cache exceeds size limit
            evictDiskCacheIfNeeded()
        } catch {
            logger.error("Failed to save image to disk: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk(key: String) -> UIImage? {
        guard let directory = diskCacheDirectory else { return nil }
        let fileURL = directory.appendingPathComponent(key)

        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    private func clearDiskCache() {
        guard let directory = diskCacheDirectory else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// Evicts oldest disk cache entries when total size exceeds `diskCacheSizeLimit`.
    /// Uses file modification dates for LRU ordering.
    private func evictDiskCacheIfNeeded() {
        guard let directory = diskCacheDirectory else { return }

        do {
            let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: .skipsHiddenFiles
            )

            // Gather file info
            var totalSize: Int = 0
            var fileInfos: [(url: URL, date: Date, size: Int)] = []

            for file in files {
                let values = try file.resourceValues(forKeys: resourceKeys)
                let size = values.fileSize ?? 0
                let date = values.contentModificationDate ?? .distantPast
                totalSize += size
                fileInfos.append((url: file, date: date, size: size))
            }

            // Only evict if over limit
            guard totalSize > diskCacheSizeLimit else { return }

            // Sort oldest first
            fileInfos.sort { $0.date < $1.date }

            // Delete oldest files until under limit
            for info in fileInfos {
                guard totalSize > diskCacheSizeLimit else { break }
                try? fileManager.removeItem(at: info.url)
                totalSize -= info.size
            }

            logger.info("Disk cache eviction: trimmed to \(totalSize) bytes")
        } catch {
            logger.error("Disk cache eviction failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Cached Async Image

/// A SwiftUI view that loads and displays an image with caching support.
///
/// Unlike `AsyncImage`, this uses ``ImageCacheService`` for persistent
/// caching across app sessions, reducing redundant network requests.
///
/// Usage:
/// ```swift
/// CachedAsyncImage(url: avatarURL) { image in
///     image.resizable().aspectRatio(contentMode: .fill)
/// } placeholder: {
///     ProgressView()
/// }
/// ```
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Optional Bearer token for authenticated image endpoints.
    var authToken: String?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let loadedImage {
                content(Image(uiImage: loadedImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let url else { return }
        isLoading = true

        loadedImage = await ImageCacheService.shared.loadImage(from: url, authToken: authToken)
        isLoading = false
    }
}

// MARK: - Self-Signed Certificate Delegate

/// `URLSessionDelegate` that accepts self-signed TLS certificates for a specific server host.
///
/// Scoped to the configured host only — external URLs (e.g. Gravatar, CDN avatars) still
/// go through the system trust store so we don't weaken security globally.
///
/// Mirrors the `CertificateTrustDelegate` used by `NetworkManager` for API requests.
private final class SelfSignedCertDelegate: NSObject, URLSessionDelegate, Sendable {
    let serverHost: String

    init(serverHost: String) {
        self.serverHost = serverHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only bypass SSL for the configured server host
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == serverHost.lowercased(),
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
