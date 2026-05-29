import Foundation

public actor McpScanner {
    private static let staticTokenEstimates: [String: Int] = [
        "filesystem": 8400,
        "github": 21000,
        "postgres": 6200,
        "slack": 7200,
        "notion": 18400,
        "stripe": 11000,
        "sentry": 4400,
        "vercel": 5600,
        "linear": 9800,
        "chromium": 24000,
        "playwright": 24000,
        "figma": 14800,
        "datadog": 9800,
    ]

    public init() {}

    public func scanScope(_ scope: LibraryScope, configFile: URL) throws -> [ScannedMcpServer] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configFile.path) else { return [] }

        let data = try Data(contentsOf: configFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let serversDict: [String: Any]
        if let mcpServers = json["mcpServers"] as? [String: Any] {
            serversDict = mcpServers
        } else {
            serversDict = json
        }

        let now = Date()
        var results: [ScannedMcpServer] = []

        for (name, value) in serversDict {
            guard let serverConfig = value as? [String: Any] else { continue }
            let command = serverConfig["command"] as? String ?? ""
            let args = serverConfig["args"] as? [String] ?? []
            let env = serverConfig["env"] as? [String: String] ?? [:]
            let envKeys = Array(env.keys).sorted()

            let estimatedTokens = Self.staticTokenEstimates[name]
                ?? Self.staticTokenEstimates[name.lowercased()]
                ?? 5000

            results.append(ScannedMcpServer(
                scope: scope,
                sourceFile: configFile,
                name: name,
                command: command,
                args: args,
                envKeys: envKeys,
                estimatedTokens: estimatedTokens,
                scannedAt: now
            ))
        }

        return results.sorted { $0.name < $1.name }
    }

    /// Walks `~/.claude.json`'s `projects.<path>.mcpServers` map. Claude Code
    /// stores per-project MCP overrides nested under each project's entry,
    /// not in a separate file — this surfaces them as `.project` scope.
    public func scanClaudeJsonProjects(_ configFile: URL) throws -> [ScannedMcpServer] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configFile.path) else { return [] }

        let data = try Data(contentsOf: configFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: Any] else { return [] }

        let now = Date()
        var results: [ScannedMcpServer] = []
        for (_, value) in projects {
            guard let proj = value as? [String: Any],
                  let mcpServers = proj["mcpServers"] as? [String: Any] else { continue }
            for (name, cfg) in mcpServers {
                guard let serverConfig = cfg as? [String: Any] else { continue }
                let command = serverConfig["command"] as? String ?? ""
                let args = serverConfig["args"] as? [String] ?? []
                let env = serverConfig["env"] as? [String: String] ?? [:]
                let envKeys = Array(env.keys).sorted()
                let estimatedTokens = Self.staticTokenEstimates[name]
                    ?? Self.staticTokenEstimates[name.lowercased()]
                    ?? 5000
                results.append(ScannedMcpServer(
                    scope: .project,
                    sourceFile: configFile,
                    name: name,
                    command: command,
                    args: args,
                    envKeys: envKeys,
                    estimatedTokens: estimatedTokens,
                    scannedAt: now
                ))
            }
        }
        return results.sorted { $0.name < $1.name }
    }
}
