import Foundation
import TokenBarCore

// MARK: - events

enum EventsCommand {
    static let name = "events"
    static let allowedSort = ["timestamp", "tokens", "input", "output", "cache"]

    struct Row: Encodable {
        let id: String
        let timestamp: String
        let agent: String
        let agentDisplayName: String
        let projectName: String
        let projectPath: String?
        let sessionId: String
        let modelName: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let totalTokens: Int
        let reasoningTokens: Int?
        let sourcePath: String
        let parser: String

        var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

        static func from(_ event: UsageEvent) -> Row {
            let total = event.inputTokens + event.outputTokens + event.cacheTokens
            return Row(
                id: event.id,
                timestamp: CLIOutput.iso(event.timestamp),
                agent: event.agent.rawValue,
                agentDisplayName: event.agent.displayName,
                projectName: event.projectName,
                projectPath: event.projectPath,
                sessionId: event.sessionId,
                modelName: modelNameOrFallback(event),
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheReadTokens: event.cacheReadTokens,
                cacheCreationTokens: event.cacheCreationTokens,
                totalTokens: total,
                reasoningTokens: event.reasoningTokens,
                sourcePath: event.sourcePath,
                parser: event.parser.rawValue
            )
        }
    }

    struct Result: Encodable {
        let count: Int
        let totalCount: Int
        let events: [Row]
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
        if let sort = options.sort {
            try sort.require(allowed: allowedSort)
        }
        if options.query != nil {
            throw CLIError.invalidArgument("--query is only supported on `prompts`; events have no text content. Filter on --project/--agent/--session instead.")
        }
        if options.promptId != nil {
            throw CLIError.invalidArgument("--id is only supported on `prompts`.")
        }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let allEvents = try repository.allEvents()
        let filtered = CLIFilters.filterEvents(allEvents, options: options)
        let sorted = sortEvents(filtered, sort: options.sort)
        let total = sorted.count
        let limited = options.limit == 0 ? sorted : Array(sorted.prefix(options.limit))
        let rows = limited.map(Row.from)
        let result = Result(count: rows.count, totalCount: total, events: rows)

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(rows)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "events",
                result: result
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) events")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            print("  Count: \(rows.count) (of \(total))")
            for row in rows {
                print("  \(row.timestamp) [\(row.agentDisplayName)] \(row.projectName) \(row.modelName) total=\(row.totalTokens) (in=\(row.inputTokens) out=\(row.outputTokens) cache=\(row.cacheTokens))")
                print("      session=\(row.sessionId)  id=\(row.id)")
            }
        }
    }

    private static func sortEvents(_ events: [UsageEvent], sort: SortSpec?) -> [UsageEvent] {
        let spec = sort ?? SortSpec(field: "timestamp", direction: .desc)
        return events.sorted { lhs, rhs in
            let (a, b): (Double, Double)
            switch spec.field {
            case "timestamp":
                a = lhs.timestamp.timeIntervalSince1970
                b = rhs.timestamp.timeIntervalSince1970
            case "tokens":
                a = Double(lhs.inputTokens + lhs.outputTokens + lhs.cacheTokens)
                b = Double(rhs.inputTokens + rhs.outputTokens + rhs.cacheTokens)
            case "input":
                a = Double(lhs.inputTokens); b = Double(rhs.inputTokens)
            case "output":
                a = Double(lhs.outputTokens); b = Double(rhs.outputTokens)
            case "cache":
                a = Double(lhs.cacheTokens); b = Double(rhs.cacheTokens)
            default:
                a = lhs.timestamp.timeIntervalSince1970
                b = rhs.timestamp.timeIntervalSince1970
            }
            switch spec.direction {
            case .asc: return a < b
            case .desc: return a > b
            }
        }
    }
}

// MARK: - prompts

enum PromptsCommand {
    static let name = "prompts"
    static let allowedSort = ["timestamp", "contentLength"]

    struct Row: Encodable {
        let id: String
        let timestamp: String
        let agent: String
        let agentDisplayName: String
        let projectName: String
        let sessionId: String
        let modelName: String
        let sourcePath: String
        let content: String
        let contentHash: String
        let contentLength: Int
        let eventId: String?
    }

    struct Result: Encodable {
        let count: Int
        let totalCount: Int
        let prompts: [Row]
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
        if let sort = options.sort {
            try sort.require(allowed: allowedSort)
        }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let allEvents = try repository.allEvents()
        let allPrompts = try repository.allPrompts()
        let eventById = Dictionary(uniqueKeysWithValues: allEvents.map { ($0.id, $0) })

        let filtered = CLIFilters.filterPrompts(allPrompts, options: options)
        let sorted = sortPrompts(filtered, sort: options.sort)
        let total = sorted.count
        let limited = options.limit == 0 ? sorted : Array(sorted.prefix(options.limit))
        let rows = limited.map { prompt -> Row in
            let modelName = resolveModelName(prompt: prompt, eventById: eventById)
            return Row(
                id: prompt.id,
                timestamp: CLIOutput.iso(prompt.timestamp),
                agent: prompt.agent.rawValue,
                agentDisplayName: prompt.agent.displayName,
                projectName: prompt.projectName,
                sessionId: prompt.sessionId,
                modelName: modelName,
                sourcePath: prompt.sourcePath,
                content: prompt.content,
                contentHash: prompt.contentHash,
                contentLength: prompt.content.count,
                eventId: prompt.eventId
            )
        }
        let result = Result(count: rows.count, totalCount: total, prompts: rows)

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(rows)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "prompts",
                result: result
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) prompts")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            print("  Count: \(rows.count) (of \(total))")
            for (index, row) in rows.enumerated() {
                print("[\(index + 1)]")
                print("  time:    \(CLIOutput.formatDateTime(row.timestampDate))")
                print("  agent:   \(row.agentDisplayName)")
                print("  model:   \(row.modelName)")
                print("  project: \(row.projectName)")
                print("  session: \(row.sessionId)")
                print("  prompt:  \(CLIOutput.truncate(row.content, 220))")
            }
        }
    }

    private static func sortPrompts(_ prompts: [PromptRecord], sort: SortSpec?) -> [PromptRecord] {
        let spec = sort ?? SortSpec(field: "timestamp", direction: .desc)
        return prompts.sorted { lhs, rhs in
            let (a, b): (Double, Double)
            switch spec.field {
            case "timestamp":
                a = lhs.timestamp.timeIntervalSince1970
                b = rhs.timestamp.timeIntervalSince1970
            case "contentLength":
                a = Double(lhs.content.count); b = Double(rhs.content.count)
            default:
                a = lhs.timestamp.timeIntervalSince1970
                b = rhs.timestamp.timeIntervalSince1970
            }
            switch spec.direction {
            case .asc: return a < b
            case .desc: return a > b
            }
        }
    }

    private static func resolveModelName(prompt: PromptRecord, eventById: [String: UsageEvent]) -> String {
        guard let eventId = prompt.eventId, let event = eventById[eventId] else {
            return prompt.agent.displayName
        }
        return modelNameOrFallback(event)
    }
}

private extension PromptsCommand.Row {
    /// Convert back to Date for text formatting purposes. The JSON output
    /// uses the pre-formatted ISO string field.
    var timestampDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp) ?? Date()
    }
}

func printWindowSummary(options: FilterOptions, databasePath: String) {
    print("  Database: \(databasePath)")
    if let day = options.day {
        print("  Day: \(day)")
    } else if options.since != nil || options.until != nil {
        print("  Window: \(CLIOutput.iso(options.resolvedStart) ?? "(open)")..\(CLIOutput.iso(options.resolvedEnd) ?? "(open)")")
    } else {
        if options.days == 0 {
            print("  Window: all-time")
        } else {
            print("  Window: last \(options.days) days")
        }
    }
    if let project = options.project { print("  Project: \(project)") }
    if let agent = options.agent { print("  Agent: \(agent.displayName)") }
    if let model = options.model { print("  Model: \(model)") }
    if let session = options.session { print("  Session: \(session)") }
    if let query = options.query, !query.isEmpty { print("  Query: \(query)") }
}
