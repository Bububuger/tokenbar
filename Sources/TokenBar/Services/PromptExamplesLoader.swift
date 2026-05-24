import Foundation

/// One curated entry shown in the Examples drawer of the Prompt Template
/// editor. Backed by `Resources/prompt-examples.json`, bundled with the app.
public struct PromptExample: Codable, Hashable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let description: String
    public let bodyPreview: String
}

/// Loads + caches the bundled examples. The JSON is read once per app launch
/// (file is tiny — ~3KB — so we keep it all in memory).
public enum PromptExamplesLoader {
    private static let cache = Cache()

    public static func load(bundle: Bundle = .main) -> [PromptExample] {
        if let cached = cache.value { return cached }
        guard
            let url = bundle.url(forResource: "prompt-examples", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let parsed = try? JSONDecoder().decode([PromptExample].self, from: data)
        else {
            return []
        }
        cache.value = parsed
        return parsed
    }

    /// For previews / unit tests — load from arbitrary URL.
    public static func loadFromURL(_ url: URL) throws -> [PromptExample] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PromptExample].self, from: data)
    }

    private final class Cache: @unchecked Sendable {
        var value: [PromptExample]?
    }
}
