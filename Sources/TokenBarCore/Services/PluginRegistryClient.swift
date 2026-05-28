import Foundation

public actor PluginRegistryClient {
    public static let defaultRegistryURL = "https://raw.githubusercontent.com/Bububuger/tokenbar-plugins/main/registry.json"
    public static let cacheFileName = "registry-cache.json"
    public static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let registryURL: String
    private let session: URLSession
    private let cacheDir: URL

    public init(
        registryURL: String = PluginRegistryClient.defaultRegistryURL,
        session: URLSession = .shared,
        cacheDir: URL = PluginManager.pluginsRoot
    ) {
        self.registryURL = registryURL
        self.session = session
        self.cacheDir = cacheDir
    }

    public func fetchIndex(forceRefresh: Bool = false) async throws -> PluginRegistryIndex {
        if !forceRefresh, let cached = loadCache(), !isCacheExpired() {
            return cached
        }

        guard let url = URL(string: registryURL) else {
            throw PluginManifestError.downloadFailed("invalid registry URL")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let cached = loadCache() { return cached }
            throw PluginManifestError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let index = try JSONDecoder().decode(PluginRegistryIndex.self, from: data)
        saveCache(data)
        return index
    }

    public func downloadManifest(from entry: PluginRegistryEntry) async throws -> (manifest: PluginManifest, data: Data) {
        guard let url = URL(string: entry.downloadUrl) else {
            throw PluginManifestError.downloadFailed("invalid download URL")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PluginManifestError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        return (manifest, data)
    }

    public func downloadAttachment(baseURL: String, fileName: String) async throws -> Data {
        let urlString = baseURL.hasSuffix("/") ? baseURL + fileName : baseURL + "/" + fileName
        guard let url = URL(string: urlString) else {
            throw PluginManifestError.downloadFailed("invalid attachment URL: \(urlString)")
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PluginManifestError.downloadFailed("attachment HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private var cacheURL: URL {
        cacheDir.appendingPathComponent(Self.cacheFileName)
    }

    private func loadCache() -> PluginRegistryIndex? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(PluginRegistryIndex.self, from: data)
    }

    private func saveCache(_ data: Data) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL)
    }

    private func isCacheExpired() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let mtime = attrs[.modificationDate] as? Date else {
            return true
        }
        return Date().timeIntervalSince(mtime) > Self.cacheTTL
    }
}
