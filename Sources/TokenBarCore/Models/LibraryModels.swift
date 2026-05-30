import Foundation

public enum LibraryScope: String, Codable, Sendable, Hashable, CaseIterable {
    case user
    case project
    case shared
    case plugin
}

public struct ScannedSkill: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path.path }
    public let scope: LibraryScope
    public let scopeRoot: URL
    public let name: String
    public let path: URL
    public let isSymlink: Bool
    public let resolvedTarget: URL?
    public let isBroken: Bool
    public let sizeBytes: Int64
    public let estimatedTokens: Int
    public let description: String?
    public let allowedTools: [String]?
    public let pluginId: String?
    public let modifiedAt: Date
    public let scannedAt: Date

    public init(
        scope: LibraryScope,
        scopeRoot: URL,
        name: String,
        path: URL,
        isSymlink: Bool,
        resolvedTarget: URL?,
        isBroken: Bool,
        sizeBytes: Int64,
        estimatedTokens: Int,
        description: String?,
        allowedTools: [String]?,
        pluginId: String? = nil,
        modifiedAt: Date,
        scannedAt: Date
    ) {
        self.scope = scope
        self.scopeRoot = scopeRoot
        self.name = name
        self.path = path
        self.isSymlink = isSymlink
        self.resolvedTarget = resolvedTarget
        self.isBroken = isBroken
        self.sizeBytes = sizeBytes
        self.estimatedTokens = estimatedTokens
        self.description = description
        self.allowedTools = allowedTools
        self.pluginId = pluginId
        self.modifiedAt = modifiedAt
        self.scannedAt = scannedAt
    }
}

public struct ScannedMcpServer: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(scope.rawValue):\(sourceFile.path):\(name)" }
    public let scope: LibraryScope
    public let sourceFile: URL
    public let name: String
    public let command: String
    public let args: [String]
    public let envKeys: [String]
    public let estimatedTokens: Int
    public let isDisabled: Bool
    /// The owning project directory for `.mcp.json`-sourced servers; nil for
    /// user scope. Used to locate the config file when deleting.
    public let projectRoot: String?
    public let scannedAt: Date

    public init(
        scope: LibraryScope,
        sourceFile: URL,
        name: String,
        command: String,
        args: [String],
        envKeys: [String],
        estimatedTokens: Int,
        isDisabled: Bool = false,
        projectRoot: String? = nil,
        scannedAt: Date
    ) {
        self.scope = scope
        self.sourceFile = sourceFile
        self.name = name
        self.command = command
        self.args = args
        self.envKeys = envKeys
        self.estimatedTokens = estimatedTokens
        self.isDisabled = isDisabled
        self.projectRoot = projectRoot
        self.scannedAt = scannedAt
    }
}

public struct LibraryConflict: Sendable, Equatable, Identifiable {
    public var id: String { "\(kind):\(skillName)" }

    public enum Kind: String, Sendable, Hashable {
        case duplicateReal
        case scopeOverlap
        case brokenSymlink
        case userPlugin
    }

    public enum Severity: String, Sendable, Hashable {
        case warning
        case error
    }

    public let kind: Kind
    public let skillName: String
    public let scopes: [LibraryScope]
    public let severity: Severity

    public init(kind: Kind, skillName: String, scopes: [LibraryScope], severity: Severity) {
        self.kind = kind
        self.skillName = skillName
        self.scopes = scopes
        self.severity = severity
    }
}

public struct LibraryScanState: Sendable, Equatable {
    public let scope: LibraryScope
    public let lastScanAt: Date
    public let lastError: String?
    public let skillCount: Int
    public let mcpCount: Int

    public init(scope: LibraryScope, lastScanAt: Date, lastError: String?, skillCount: Int, mcpCount: Int) {
        self.scope = scope
        self.lastScanAt = lastScanAt
        self.lastError = lastError
        self.skillCount = skillCount
        self.mcpCount = mcpCount
    }
}

/// Parsed record from `~/.claude/plugins/installed_plugins.json`. This is the
/// Claude Code-side plugin catalog (separate from TokenBar's own plugin
/// gallery in Settings — those are still surfaced via `PluginManager`).
public struct ScannedClaudePlugin: Sendable, Equatable, Identifiable {
    public var id: String { fullId }
    public let fullId: String          // "warp@claude-code-warp"
    public let name: String            // "warp"
    public let marketplace: String     // "claude-code-warp"
    public let version: String
    public let scope: String           // "user" / "local"
    public let installPath: String
    public let projectPath: String?    // only when scope == "local"
    public let installedAt: Date?

    public init(
        fullId: String,
        name: String,
        marketplace: String,
        version: String,
        scope: String,
        installPath: String,
        projectPath: String?,
        installedAt: Date?
    ) {
        self.fullId = fullId
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.scope = scope
        self.installPath = installPath
        self.projectPath = projectPath
        self.installedAt = installedAt
    }
}

public struct LibrarySnapshot: Sendable, Equatable {
    public let skills: [ScannedSkill]
    public let mcpServers: [ScannedMcpServer]
    public let plugins: [ScannedClaudePlugin]
    public let conflicts: [LibraryConflict]
    public let scanStates: [LibraryScope: LibraryScanState]
    public let lastFullScanAt: Date?
    public let isScanning: Bool

    public init(
        skills: [ScannedSkill],
        mcpServers: [ScannedMcpServer],
        plugins: [ScannedClaudePlugin],
        conflicts: [LibraryConflict],
        scanStates: [LibraryScope: LibraryScanState],
        lastFullScanAt: Date?,
        isScanning: Bool
    ) {
        self.skills = skills
        self.mcpServers = mcpServers
        self.plugins = plugins
        self.conflicts = conflicts
        self.scanStates = scanStates
        self.lastFullScanAt = lastFullScanAt
        self.isScanning = isScanning
    }

    public static let empty = LibrarySnapshot(
        skills: [],
        mcpServers: [],
        plugins: [],
        conflicts: [],
        scanStates: [:],
        lastFullScanAt: nil,
        isScanning: false
    )

    public var skillsByScope: [LibraryScope: [ScannedSkill]] {
        Dictionary(grouping: skills, by: \.scope)
    }

    public var mcpByScope: [LibraryScope: [ScannedMcpServer]] {
        Dictionary(grouping: mcpServers, by: \.scope)
    }
}
