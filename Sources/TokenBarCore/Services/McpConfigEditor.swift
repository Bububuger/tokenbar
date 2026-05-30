import Foundation

/// Mutates the on-disk MCP config files that the Library tab surfaces. Today
/// this only deletes a server entry; both `~/.claude.json` (user scope) and a
/// project's `.mcp.json` (project scope) store servers under a top-level
/// `mcpServers` map, so deletion is the same shape for both.
public enum McpConfigEditor {
    public enum EditError: Error, LocalizedError {
        case fileNotFound(String)
        case malformedJSON(String)
        case serverNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "Config file not found: \(path)"
            case .malformedJSON(let path): return "Config file is not valid JSON: \(path)"
            case .serverNotFound(let name): return "Server \"\(name)\" not found in config"
            }
        }
    }

    /// Removes `mcpServers.<name>` from `configFile` and rewrites the file,
    /// preserving every other key. Returns silently if the server is already
    /// gone is NOT desired — callers expect a thrown error so the UI can report
    /// a stale row, so a missing server throws `.serverNotFound`.
    public static func deleteServer(name: String, configFile: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configFile.path) else {
            throw EditError.fileNotFound(configFile.path)
        }
        let data = try Data(contentsOf: configFile)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditError.malformedJSON(configFile.path)
        }

        guard var servers = json["mcpServers"] as? [String: Any] else {
            throw EditError.serverNotFound(name)
        }
        guard servers[name] != nil else {
            throw EditError.serverNotFound(name)
        }
        servers.removeValue(forKey: name)
        json["mcpServers"] = servers

        let out = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try out.write(to: configFile, options: .atomic)
    }
}
