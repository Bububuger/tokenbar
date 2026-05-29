import Foundation
import TokenBarCore

// Library tab data, mirrored for the CLI. These read the same `library_*`
// tables the app's Library tab renders (populated by the scanners on rebuild),
// so rows here match the SQLite counts. Current-state lists — no time window.

// MARK: - skills

enum SkillsCommand {
    static let name = "skills"

    struct Row: Encodable {
        let scope: String
        let scopeRoot: String
        let name: String
        let estimatedTokens: Int
        let path: String
        let isBroken: Bool
        let pluginId: String?
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        options.limit = CommandRegistry.descriptor(named: name)?.defaultLimit ?? 100
        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h": throw HelpRequested.command(name)
            default:
                if try !FilterParser.consume(flag: arg, cursor: &cursor, options: &options) {
                    throw CLIError.invalidArgument("Unexpected argument: \(arg)")
                }
            }
        }
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let skills = try repository.loadLibrarySkills()
        let rows = skills.map { skill in
            Row(
                scope: skill.scope.rawValue,
                scopeRoot: skill.scopeRoot.path,
                name: skill.name,
                estimatedTokens: skill.estimatedTokens,
                path: skill.path.path,
                isBroken: skill.isBroken,
                pluginId: skill.pluginId
            )
        }
        let limited = options.limit == 0 ? rows : Array(rows.prefix(options.limit))

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: nil,
                filters: nil,
                resultKey: "skills",
                result: limited
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) skills")
            print("  Database: \(databaseURL.path)")
            print("  Count: \(limited.count) (of \(rows.count))")
            for row in limited {
                let broken = row.isBroken ? " [broken]" : ""
                let plugin = row.pluginId.map { " plugin=\($0)" } ?? ""
                print("  - [\(row.scope)] \(row.name) tokens=\(row.estimatedTokens)\(broken)\(plugin)")
                print("      root: \(row.scopeRoot)")
                print("      path: \(row.path)")
            }
        }
    }
}

// MARK: - mcp

enum McpCommand {
    static let name = "mcp"

    struct Row: Encodable {
        let scope: String
        let sourceFile: String
        let name: String
        let command: String
        let args: [String]
        let estimatedTokens: Int
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        options.limit = CommandRegistry.descriptor(named: name)?.defaultLimit ?? 100
        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h": throw HelpRequested.command(name)
            default:
                if try !FilterParser.consume(flag: arg, cursor: &cursor, options: &options) {
                    throw CLIError.invalidArgument("Unexpected argument: \(arg)")
                }
            }
        }
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let servers = try repository.loadLibraryMcp()
        let rows = servers.map { server in
            Row(
                scope: server.scope.rawValue,
                sourceFile: server.sourceFile.path,
                name: server.name,
                command: server.command,
                args: server.args,
                estimatedTokens: server.estimatedTokens
            )
        }
        let limited = options.limit == 0 ? rows : Array(rows.prefix(options.limit))

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: nil,
                filters: nil,
                resultKey: "mcp",
                result: limited
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) mcp")
            print("  Database: \(databaseURL.path)")
            print("  Count: \(limited.count) (of \(rows.count))")
            for row in limited {
                let argsTail = row.args.isEmpty ? "" : " " + row.args.joined(separator: " ")
                print("  - [\(row.scope)] \(row.name) tokens=\(row.estimatedTokens)")
                print("      cmd: \(row.command)\(argsTail)")
                print("      source: \(row.sourceFile)")
            }
        }
    }
}

// MARK: - plugins

enum PluginsCommand {
    static let name = "plugins"

    struct Row: Encodable {
        let fullId: String
        let name: String
        let marketplace: String
        let version: String
        let scope: String
        let installPath: String
        let projectPath: String?
        let installedAt: String?
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        options.limit = CommandRegistry.descriptor(named: name)?.defaultLimit ?? 100
        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h": throw HelpRequested.command(name)
            default:
                if try !FilterParser.consume(flag: arg, cursor: &cursor, options: &options) {
                    throw CLIError.invalidArgument("Unexpected argument: \(arg)")
                }
            }
        }
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let plugins = try repository.loadLibraryPlugins()
        let rows = plugins.map { plugin in
            Row(
                fullId: plugin.fullId,
                name: plugin.name,
                marketplace: plugin.marketplace,
                version: plugin.version,
                scope: plugin.scope,
                installPath: plugin.installPath,
                projectPath: plugin.projectPath,
                installedAt: plugin.installedAt.map(CLIOutput.iso)
            )
        }
        let limited = options.limit == 0 ? rows : Array(rows.prefix(options.limit))

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: nil,
                filters: nil,
                resultKey: "plugins",
                result: limited
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) plugins")
            print("  Database: \(databaseURL.path)")
            print("  Count: \(limited.count) (of \(rows.count))")
            for row in limited {
                let installed = row.installedAt.map { " installed=\($0)" } ?? ""
                print("  - \(row.fullId) v\(row.version) [\(row.scope)]\(installed)")
                print("      path: \(row.installPath)")
                if let projectPath = row.projectPath {
                    print("      project: \(projectPath)")
                }
            }
        }
    }
}
