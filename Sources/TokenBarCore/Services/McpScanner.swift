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

    /// Scans a project's `.mcp.json` file. Claude Code records which of these
    /// servers a user has toggled off in `~/.claude.json`'s per-project
    /// `disabledMcpjsonServers` array — pass that list as `disabledNames` so the
    /// scan can surface a disabled state. `projectRoot` is the directory that
    /// owns the `.mcp.json` (used later to locate the file when deleting).
    public func scanProjectMcpJson(projectRoot: URL, disabledNames: Set<String>) throws -> [ScannedMcpServer] {
        let fm = FileManager.default
        let configFile = projectRoot.appendingPathComponent(".mcp.json")
        guard fm.fileExists(atPath: configFile.path) else { return [] }

        let data = try Data(contentsOf: configFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let serversDict = (json["mcpServers"] as? [String: Any]) ?? json

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
                scope: .project,
                sourceFile: configFile,
                name: name,
                command: command,
                args: args,
                envKeys: envKeys,
                estimatedTokens: estimatedTokens,
                isDisabled: disabledNames.contains(name),
                projectRoot: projectRoot.path,
                scannedAt: now
            ))
        }
        return results.sorted { $0.name < $1.name }
    }
}
