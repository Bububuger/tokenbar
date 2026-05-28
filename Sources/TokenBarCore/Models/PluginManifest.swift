import Foundation

public struct PluginManifest: Codable, Sendable, Hashable {
    public let manifestVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let author: String
    public var homepage: String?
    public var minTokenbarVersion: String?
    public let source: PluginSourceConfig
    public var tokenSemantics: PluginTokenSemantics?
    public var setupHints: [String]?

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case id, name, version, description, author, homepage
        case minTokenbarVersion = "min_tokenbar_version"
        case source
        case tokenSemantics = "token_semantics"
        case setupHints = "setup_hints"
    }

    public var inputIncludesCached: Bool {
        tokenSemantics?.inputIncludesCached ?? false
    }

    public var timestampFormat: PluginTimestampFormat {
        tokenSemantics?.timestampFormat ?? .iso8601
    }

    public func validate() throws {
        guard manifestVersion == 1 else {
            throw PluginManifestError.unsupportedVersion(manifestVersion)
        }
        guard !id.isEmpty else {
            throw PluginManifestError.missingField("id")
        }
        guard id.range(of: #"^[a-z0-9][a-z0-9\-]*$"#, options: .regularExpression) != nil else {
            throw PluginManifestError.invalidId(id)
        }
        guard !name.isEmpty else {
            throw PluginManifestError.missingField("name")
        }
        guard !version.isEmpty else {
            throw PluginManifestError.missingField("version")
        }
    }
}

public enum PluginSourceConfig: Codable, Sendable, Hashable {
    case jsonl(PluginJSONLSource)
    case sqlite(PluginSQLiteSource)
    case executable(PluginExecutableSource)

    enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let singleContainer = try decoder.singleValueContainer()
        switch type {
        case "jsonl":
            self = .jsonl(try singleContainer.decode(PluginJSONLSource.self))
        case "sqlite":
            self = .sqlite(try singleContainer.decode(PluginSQLiteSource.self))
        case "executable":
            self = .executable(try singleContainer.decode(PluginExecutableSource.self))
        default:
            throw PluginManifestError.unknownSourceType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .jsonl(let source):
            try source.encode(to: encoder)
        case .sqlite(let source):
            try source.encode(to: encoder)
        case .executable(let source):
            try source.encode(to: encoder)
        }
    }

    public var sourceType: String {
        switch self {
        case .jsonl: "jsonl"
        case .sqlite: "sqlite"
        case .executable: "executable"
        }
    }
}

public struct PluginJSONLSource: Codable, Sendable, Hashable {
    public let type: String
    public let directory: String
    public let glob: String
    public let fields: PluginFieldMapping
    public var filter: PluginLineFilter?

    public init(directory: String, glob: String, fields: PluginFieldMapping, filter: PluginLineFilter? = nil) {
        self.type = "jsonl"
        self.directory = directory
        self.glob = glob
        self.fields = fields
        self.filter = filter
    }
}

public struct PluginSQLiteSource: Codable, Sendable, Hashable {
    public let type: String
    public let directory: String
    public let glob: String
    public let query: PluginSQLiteQuery

    public init(directory: String, glob: String, query: PluginSQLiteQuery) {
        self.type = "sqlite"
        self.directory = directory
        self.glob = glob
        self.query = query
    }
}

public struct PluginExecutableSource: Codable, Sendable, Hashable {
    public let type: String
    public let command: String
    public var script: String?
    public var args: [String]?
    public var incrementalFlag: String?
    public var timeoutSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case type, command, script, args
        case incrementalFlag = "incremental_flag"
        case timeoutSeconds = "timeout_seconds"
    }

    public var effectiveTimeout: Int {
        min(max(timeoutSeconds ?? 30, 5), 120)
    }

    public init(command: String, script: String? = nil, args: [String]? = nil, incrementalFlag: String? = nil, timeoutSeconds: Int? = nil) {
        self.type = "executable"
        self.command = command
        self.script = script
        self.args = args
        self.incrementalFlag = incrementalFlag
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct PluginFieldMapping: Codable, Sendable, Hashable {
    public var inputTokens: String?
    public var outputTokens: String?
    public var cacheReadTokens: String?
    public var cacheCreationTokens: String?
    public var reasoningTokens: String?
    public var model: String?
    public var timestamp: String?
    public var sessionId: String?
    public var project: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case reasoningTokens = "reasoning_tokens"
        case model, timestamp
        case sessionId = "session_id"
        case project
    }

    public func toCustomSourceFieldMapping() -> CustomSourceFieldMapping {
        CustomSourceFieldMapping(
            inputTokens: inputTokens ?? "usage.input_tokens",
            outputTokens: outputTokens ?? "usage.output_tokens",
            cacheReadTokens: cacheReadTokens ?? "usage.cache_read_input_tokens",
            cacheCreationTokens: cacheCreationTokens ?? "usage.cache_creation_input_tokens",
            model: model ?? "model"
        )
    }
}

public struct PluginSQLiteQuery: Codable, Sendable, Hashable {
    public let table: String
    public let columns: PluginFieldMapping
    public var watermarkColumn: String?
    public var `where`: String?

    enum CodingKeys: String, CodingKey {
        case table, columns
        case watermarkColumn = "watermark_column"
        case `where`
    }

    public init(table: String, columns: PluginFieldMapping, watermarkColumn: String? = nil, where whereClause: String? = nil) {
        self.table = table
        self.columns = columns
        self.watermarkColumn = watermarkColumn
        self.`where` = whereClause
    }
}

public struct PluginLineFilter: Codable, Sendable, Hashable {
    public let field: String
    public let equals: String
}

public struct PluginTokenSemantics: Codable, Sendable, Hashable {
    public var inputIncludesCached: Bool?
    public var timestampFormat: PluginTimestampFormat?

    enum CodingKeys: String, CodingKey {
        case inputIncludesCached = "input_includes_cached"
        case timestampFormat = "timestamp_format"
    }
}

public enum PluginTimestampFormat: String, Codable, Sendable, Hashable {
    case iso8601
    case unixS = "unix_s"
    case unixMs = "unix_ms"
    case unixNano = "unix_nano"

    public func parse(_ value: Any) -> Date? {
        switch self {
        case .iso8601:
            guard let str = value as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: str) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: str)
        case .unixS:
            guard let num = numericValue(value) else { return nil }
            return Date(timeIntervalSince1970: num)
        case .unixMs:
            guard let num = numericValue(value) else { return nil }
            return Date(timeIntervalSince1970: num / 1_000)
        case .unixNano:
            guard let num = numericValue(value) else { return nil }
            return Date(timeIntervalSince1970: num / 1_000_000_000)
        }
    }

    private func numericValue(_ value: Any) -> Double? {
        switch value {
        case let n as Int: Double(n)
        case let n as Int64: Double(n)
        case let n as UInt64: Double(n)
        case let n as Double: n
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }
}

public enum PluginManifestError: LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case missingField(String)
    case invalidId(String)
    case unknownSourceType(String)
    case manifestNotFound(String)
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): "Unsupported manifest version: \(v)"
        case .missingField(let f): "Missing required field: \(f)"
        case .invalidId(let id): "Invalid plugin id (must be kebab-case): \(id)"
        case .unknownSourceType(let t): "Unknown source type: \(t)"
        case .manifestNotFound(let path): "Manifest not found: \(path)"
        case .downloadFailed(let msg): "Download failed: \(msg)"
        }
    }
}

public struct PluginRegistryEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public var author: String?
    public var type: String?
    public let downloadUrl: String
    public var minTokenbarVersion: String?

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, type
        case downloadUrl = "download_url"
        case minTokenbarVersion = "min_tokenbar_version"
    }
}

public struct PluginRegistryIndex: Codable, Sendable, Hashable {
    public let registryVersion: Int
    public var updatedAt: String?
    public let plugins: [PluginRegistryEntry]

    enum CodingKeys: String, CodingKey {
        case registryVersion = "registry_version"
        case updatedAt = "updated_at"
        case plugins
    }
}
