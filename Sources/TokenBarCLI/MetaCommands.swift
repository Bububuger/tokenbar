import Foundation
import TokenBarCore

// MARK: - sources

enum SourcesCommand {
    static let name = "sources"

    struct Row: Encodable {
        let name: String
        let type: String                // "builtin" | "custom"
        let engine: String?             // for custom; the CustomSourceEngine raw
        let agent: String?              // resolved AgentKind raw
        let rootPath: String
        let globPattern: String?
        let enabled: Bool
        let isReadable: Bool
        let discoveredFileCount: Int
        let eventCount: Int
        let promptCount: Int
        let latestEventTimestamp: String?
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
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

    static func run(_ options: FilterOptions) async throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let allEvents = try repository.allEvents()
        let allPrompts = try repository.allPrompts()
        let customSourceRecords = try repository.listCustomSources()

        let builtIn = BuiltInSources.all()

        var rows: [Row] = []
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = Date()

        for source in builtIn {
            let status = await source.status(referenceDate: referenceDate, calendar: calendar)
            let agentEvents = allEvents.filter { $0.agent == source.agent }
            let agentPrompts = allPrompts.filter { $0.agent == source.agent }
            let latest = agentEvents.max(by: { $0.timestamp < $1.timestamp })?.timestamp
            rows.append(Row(
                name: status.sourceName,
                type: "builtin",
                engine: nil,
                agent: source.agent.rawValue,
                rootPath: status.rootPath,
                globPattern: nil,
                enabled: true,
                isReadable: status.isReadable,
                discoveredFileCount: status.discoveredFileCount,
                eventCount: agentEvents.count,
                promptCount: agentPrompts.count,
                latestEventTimestamp: latest.map(CLIOutput.iso)
            ))
        }

        for record in customSourceRecords {
            let source = CustomUsageEventSource(record: record)
            let status = await source.status(referenceDate: referenceDate, calendar: calendar)
            let prefix = "custom:\(record.id):"
            let customEvents = allEvents.filter { $0.id.hasPrefix(prefix) }
            let customPrompts = allPrompts.filter { $0.id.hasPrefix(prefix) || ($0.eventId?.hasPrefix(prefix) ?? false) }
            let latest = customEvents.max(by: { $0.timestamp < $1.timestamp })?.timestamp
            rows.append(Row(
                name: record.name,
                type: "custom",
                engine: record.engine.rawValue,
                agent: record.engine.agentKind.rawValue,
                rootPath: record.directory,
                globPattern: record.globPattern,
                enabled: record.enabled,
                isReadable: status.isReadable,
                discoveredFileCount: status.discoveredFileCount,
                eventCount: customEvents.count,
                promptCount: customPrompts.count,
                latestEventTimestamp: latest.map(CLIOutput.iso)
            ))
        }

        let resultKey = "sources"

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(rows)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: nil,
                filters: nil,
                resultKey: resultKey,
                result: rows
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) sources")
            print("  Database: \(databaseURL.path)")
            print("  Count: \(rows.count)")
            for row in rows {
                let readable = row.isReadable ? "readable" : "not readable"
                let enabled = row.enabled ? "enabled" : "disabled"
                print("  - \(row.name) [\(row.type) \(enabled), \(readable)]")
                print("      root: \(row.rootPath)")
                if let glob = row.globPattern { print("      glob: \(glob)") }
                if let agent = row.agent { print("      agent: \(agent)") }
                print("      files: \(row.discoveredFileCount), events: \(row.eventCount), prompts: \(row.promptCount)")
                if let latest = row.latestEventTimestamp {
                    print("      latest: \(latest)")
                }
            }
        }
    }
}

// MARK: - checkpoints

enum CheckpointsCommand {
    static let name = "checkpoints"

    struct Row: Encodable {
        let id: Int64
        let startedAt: String
        let endedAt: String?
        let trigger: String
        let eventsAdded: Int
        let promptsAdded: Int
        let warnings: Int
        let durationMs: Int64?
        let error: String?
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        options.limit = CommandRegistry.descriptor(named: name)?.defaultLimit ?? 20
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
        let limit = options.limit == 0 ? Int.max : options.limit
        let checkpoints = try repository.recentCheckpoints(limit: min(limit, 1000))
        let rows = checkpoints.map { checkpoint -> Row in
            let duration: Int64?
            if let ended = checkpoint.endedAt {
                duration = Int64(ended.timeIntervalSince(checkpoint.startedAt) * 1000)
            } else {
                duration = nil
            }
            return Row(
                id: checkpoint.id,
                startedAt: CLIOutput.iso(checkpoint.startedAt),
                endedAt: checkpoint.endedAt.map(CLIOutput.iso),
                trigger: checkpoint.trigger,
                eventsAdded: checkpoint.eventsAdded,
                promptsAdded: checkpoint.promptsAdded,
                warnings: checkpoint.warnings,
                durationMs: duration,
                error: checkpoint.error
            )
        }

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(rows)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: nil,
                filters: nil,
                resultKey: "checkpoints",
                result: rows
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) checkpoints")
            print("  Database: \(databaseURL.path)")
            print("  Count: \(rows.count)")
            for row in rows {
                let duration = row.durationMs.map { "\($0)ms" } ?? "—"
                let errorTag = (row.error ?? "").isEmpty ? "" : " ERROR: \(row.error ?? "")"
                print("  #\(row.id) \(row.startedAt) trigger=\(row.trigger) events+\(row.eventsAdded) prompts+\(row.promptsAdded) warnings=\(row.warnings) dur=\(duration)\(errorTag)")
            }
        }
    }
}

// MARK: - warnings

enum WarningsCommand {
    static let name = "warnings"

    struct Row: Encodable {
        let sourceName: String
        let sourcePath: String
        let lineNumber: Int?
        let message: String
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        options.limit = CommandRegistry.descriptor(named: name)?.defaultLimit ?? 50
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
        let warnings = try repository.latestWarnings(limit: options.limit == 0 ? 1000 : options.limit)
        let rows = warnings.map { Row(
            sourceName: $0.sourceName,
            sourcePath: $0.sourcePath,
            lineNumber: $0.lineNumber,
            message: $0.message
        )}

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(rows)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: nil,
                filters: nil,
                resultKey: "warnings",
                result: rows
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) warnings")
            print("  Database: \(databaseURL.path)")
            print("  Count: \(rows.count)")
            for row in rows {
                let line = row.lineNumber.map { ":\($0)" } ?? ""
                print("  [\(row.sourceName)] \(row.sourcePath)\(line)")
                print("      \(row.message)")
            }
        }
    }
}

// MARK: - schema

enum SchemaCommand {
    static let name = "schema"

    struct AgentEntry: Encodable {
        let kind: String
        let displayName: String
        let eventCount: Int
    }

    struct ModelEntry: Encodable {
        let name: String
        let eventCount: Int
    }

    struct DataWindow: Encodable {
        let earliest: String?
        let latest: String?
        let eventCount: Int
    }

    struct SchemaOutput: Encodable {
        let databasePath: String
        let dataWindow: DataWindow
        let distinctProjects: [String]
        let distinctAgents: [AgentEntry]
        let distinctModels: [ModelEntry]
        let groupByDimensions: [String]
        let bucketKinds: [String]
        let commands: [CommandDescriptor]
        let costSource: String
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        // schema only consumes --db and --json
        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h": throw HelpRequested.command(name)
            case "--db":
                options.databasePath = try cursor.nextValue(for: "--db")
            case "--json":
                options.output = .json
            case "--ndjson":
                throw CLIError.invalidArgument("schema does not support --ndjson; use --json")
            case let unknown where unknown.hasPrefix("-"):
                throw CLIError.invalidArgument("Unknown schema option: \(unknown)")
            default:
                throw CLIError.invalidArgument("Unexpected schema argument: \(arg)")
            }
        }
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let allEvents = try repository.allEvents()
        let timeBounds = try repository.eventTimeBounds()

        var agentCounts: [AgentKind: Int] = [:]
        var modelCounts: [String: Int] = [:]
        var projectTokens: [String: Int] = [:]
        for event in allEvents {
            agentCounts[event.agent, default: 0] += 1
            let modelName = modelNameOrFallback(event)
            modelCounts[modelName, default: 0] += 1
            let total = event.inputTokens + event.outputTokens + event.cacheTokens
            projectTokens[event.projectName, default: 0] += total
        }

        let projects = projectTokens
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        let agentEntries = agentCounts
            .map { AgentEntry(kind: $0.key.rawValue, displayName: $0.key.displayName, eventCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.eventCount == rhs.eventCount { return lhs.kind < rhs.kind }
                return lhs.eventCount > rhs.eventCount
            }

        let modelEntries = modelCounts
            .map { ModelEntry(name: $0.key, eventCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.eventCount == rhs.eventCount { return lhs.name < rhs.name }
                return lhs.eventCount > rhs.eventCount
            }

        let schema = SchemaOutput(
            databasePath: databaseURL.path,
            dataWindow: DataWindow(
                earliest: timeBounds.earliest.map(CLIOutput.iso),
                latest: timeBounds.latest.map(CLIOutput.iso),
                eventCount: timeBounds.eventCount
            ),
            distinctProjects: projects,
            distinctAgents: agentEntries,
            distinctModels: modelEntries,
            groupByDimensions: GroupByDimension.allCases.map(\.rawValue),
            bucketKinds: TimeBucket.allCases.map(\.rawValue),
            commands: CommandRegistry.all,
            costSource: "defaults"
        )

        // schema is always JSON.
        let envelope = JSONEnvelope(
            schemaVersion: CLIOutput.schemaVersion,
            command: name,
            generatedAt: CLIOutput.iso(Date()),
            databasePath: databaseURL.path,
            window: nil,
            filters: nil,
            resultKey: "schema",
            result: schema
        )
        CLIOutput.writeJSON(envelope)
    }
}
