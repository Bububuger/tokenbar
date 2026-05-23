import Foundation
import TokenBarCore

// MARK: - projects

enum ProjectsCommand {
    static let name = "projects"
    static let allowedSort = ["tokens", "name", "lastSeen", "eventCount"]

    struct Row: Encodable {
        let name: String
        let eventCount: Int
        let promptCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalTokens: Int
        let firstSeen: String?
        let lastSeen: String?
        let distinctAgents: [String]
        let distinctModels: [String]
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
        // projects is window-only — reject per-row filters that don't make sense.
        if options.agent != nil || options.model != nil || options.session != nil {
            throw CLIError.invalidArgument("--agent/--model/--session are not allowed on projects; aggregate columns include those already.")
        }
        if options.project != nil {
            throw CLIError.invalidArgument("--project is not allowed on projects; the command lists every project. Use sessions/events with --project to drill in.")
        }
        if options.query != nil || options.promptId != nil {
            throw CLIError.invalidArgument("--query/--id are not supported on projects.")
        }
        if let sort = options.sort { try sort.require(allowed: allowedSort) }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let allEvents = try repository.allEvents()
        let allPrompts = try repository.allPrompts()
        let windowEvents = CLIFilters.filterEvents(allEvents, options: options)
        let windowPrompts = CLIFilters.filterPrompts(allPrompts, options: options)

        var byProject: [String: ProjectAccumulator] = [:]
        for event in windowEvents {
            byProject[event.projectName, default: ProjectAccumulator()].add(event)
        }
        var promptByProject: [String: Int] = [:]
        for prompt in windowPrompts {
            promptByProject[prompt.projectName, default: 0] += 1
        }

        let rows = byProject.map { name, accumulator -> Row in
            Row(
                name: name,
                eventCount: accumulator.eventCount,
                promptCount: promptByProject[name] ?? 0,
                inputTokens: accumulator.inputTokens,
                outputTokens: accumulator.outputTokens,
                cacheTokens: accumulator.cacheTokens,
                totalTokens: accumulator.totalTokens,
                firstSeen: accumulator.firstSeen.map(CLIOutput.iso),
                lastSeen: accumulator.lastSeen.map(CLIOutput.iso),
                distinctAgents: Array(accumulator.agents).sorted(),
                distinctModels: Array(accumulator.models).sorted()
            )
        }

        let sortedRows = sortRows(rows, sort: options.sort)
        let total = sortedRows.count
        let limited = options.limit == 0 ? sortedRows : Array(sortedRows.prefix(options.limit))

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "projects",
                result: ProjectsResult(count: limited.count, totalCount: total, projects: limited)
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) projects")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            print("  Count: \(limited.count) (of \(total))")
            for row in limited {
                print("  - \(row.name) total=\(row.totalTokens) (in=\(row.inputTokens) out=\(row.outputTokens) cache=\(row.cacheTokens)) events=\(row.eventCount) prompts=\(row.promptCount)")
                print("      agents: \(row.distinctAgents.joined(separator: ", "))")
                if !row.distinctModels.isEmpty {
                    print("      models: \(row.distinctModels.joined(separator: ", "))")
                }
                if let first = row.firstSeen, let last = row.lastSeen {
                    print("      span: \(first)..\(last)")
                }
            }
        }
    }

    private static func sortRows(_ rows: [Row], sort: SortSpec?) -> [Row] {
        let spec = sort ?? SortSpec(field: "tokens", direction: .desc)
        return rows.sorted { lhs, rhs in
            let order: ComparisonResult
            switch spec.field {
            case "name":
                order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case "lastSeen":
                let a = lhs.lastSeen ?? ""
                let b = rhs.lastSeen ?? ""
                order = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            case "eventCount":
                order = compareInts(lhs.eventCount, rhs.eventCount)
            default:
                order = compareInts(lhs.totalTokens, rhs.totalTokens)
            }
            switch spec.direction {
            case .asc:
                return order == .orderedAscending
            case .desc:
                return order == .orderedDescending
            }
        }
    }
}

struct ProjectsResult: Encodable {
    let count: Int
    let totalCount: Int
    let projects: [ProjectsCommand.Row]
}

private struct ProjectAccumulator {
    var inputTokens = 0
    var outputTokens = 0
    var cacheTokens = 0
    var eventCount = 0
    var firstSeen: Date?
    var lastSeen: Date?
    var agents: Set<String> = []
    var models: Set<String> = []

    var totalTokens: Int { inputTokens + outputTokens + cacheTokens }

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheTokens += event.cacheTokens
        eventCount += 1
        if firstSeen == nil || event.timestamp < (firstSeen ?? .distantFuture) {
            firstSeen = event.timestamp
        }
        if lastSeen == nil || event.timestamp > (lastSeen ?? .distantPast) {
            lastSeen = event.timestamp
        }
        agents.insert(event.agent.rawValue)
        let model = (event.modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { models.insert(model) }
    }
}

private func compareInts(_ a: Int, _ b: Int) -> ComparisonResult {
    if a == b { return .orderedSame }
    return a < b ? .orderedAscending : .orderedDescending
}

// MARK: - sessions

enum SessionsCommand {
    static let name = "sessions"
    static let allowedSort = ["lastSeen", "tokens", "firstSeen", "eventCount", "promptCount"]

    struct Row: Encodable {
        let sessionId: String
        let projectName: String
        let agent: String
        let agentDisplayName: String
        let modelName: String
        let firstSeen: String?
        let lastSeen: String?
        let eventCount: Int
        let promptCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalTokens: Int
    }

    struct Result: Encodable {
        let count: Int
        let totalCount: Int
        let sessions: [Row]
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
        if options.query != nil || options.promptId != nil {
            throw CLIError.invalidArgument("--query/--id are not supported on sessions.")
        }
        if let sort = options.sort { try sort.require(allowed: allowedSort) }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let allEvents = try repository.allEvents()
        let allPrompts = try repository.allPrompts()
        let events = CLIFilters.filterEvents(allEvents, options: options)
        let prompts = CLIFilters.filterPrompts(allPrompts, options: options)

        struct Bucket {
            var inputTokens = 0, outputTokens = 0, cacheTokens = 0
            var eventCount = 0
            var firstSeen: Date?
            var lastSeen: Date?
            var agent: AgentKind?
            var latestModel: String?
            var latestModelAt: Date?
            var projectName: String = ""
        }

        var byKey: [String: Bucket] = [:]
        for event in events {
            let key = event.sessionId + "|" + event.agent.rawValue
            var bucket = byKey[key] ?? Bucket()
            bucket.agent = event.agent
            bucket.projectName = event.projectName
            bucket.inputTokens += event.inputTokens
            bucket.outputTokens += event.outputTokens
            bucket.cacheTokens += event.cacheTokens
            bucket.eventCount += 1
            if bucket.firstSeen == nil || event.timestamp < (bucket.firstSeen ?? .distantFuture) {
                bucket.firstSeen = event.timestamp
            }
            if bucket.lastSeen == nil || event.timestamp > (bucket.lastSeen ?? .distantPast) {
                bucket.lastSeen = event.timestamp
            }
            let model = (event.modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                if let existing = bucket.latestModelAt {
                    if event.timestamp > existing {
                        bucket.latestModel = model
                        bucket.latestModelAt = event.timestamp
                    }
                } else {
                    bucket.latestModel = model
                    bucket.latestModelAt = event.timestamp
                }
            }
            byKey[key] = bucket
        }

        var promptCounts: [String: Int] = [:]
        for prompt in prompts {
            let key = prompt.sessionId + "|" + prompt.agent.rawValue
            promptCounts[key, default: 0] += 1
        }

        let rows: [Row] = byKey.map { key, bucket -> Row in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let sessionId = parts.first ?? ""
            let agent = bucket.agent ?? .codex
            return Row(
                sessionId: sessionId,
                projectName: bucket.projectName,
                agent: agent.rawValue,
                agentDisplayName: agent.displayName,
                modelName: bucket.latestModel ?? agent.displayName,
                firstSeen: bucket.firstSeen.map(CLIOutput.iso),
                lastSeen: bucket.lastSeen.map(CLIOutput.iso),
                eventCount: bucket.eventCount,
                promptCount: promptCounts[key] ?? 0,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheTokens: bucket.cacheTokens,
                totalTokens: bucket.inputTokens + bucket.outputTokens + bucket.cacheTokens
            )
        }

        let sorted = sortRows(rows, sort: options.sort)
        let total = sorted.count
        let limited = options.limit == 0 ? sorted : Array(sorted.prefix(options.limit))
        let result = Result(count: limited.count, totalCount: total, sessions: limited)

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "sessions",
                result: result
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) sessions")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            print("  Count: \(limited.count) (of \(total))")
            for row in limited {
                let span = (row.firstSeen ?? "?") + ".." + (row.lastSeen ?? "?")
                print("  \(row.sessionId) [\(row.agentDisplayName)] project=\(row.projectName) model=\(row.modelName) total=\(row.totalTokens) events=\(row.eventCount) prompts=\(row.promptCount) span=\(span)")
            }
        }
    }

    private static func sortRows(_ rows: [Row], sort: SortSpec?) -> [Row] {
        let spec = sort ?? SortSpec(field: "lastSeen", direction: .desc)
        return rows.sorted { lhs, rhs in
            let order: ComparisonResult
            switch spec.field {
            case "tokens":
                order = compareInts(lhs.totalTokens, rhs.totalTokens)
            case "firstSeen":
                order = compareStrings(lhs.firstSeen, rhs.firstSeen)
            case "eventCount":
                order = compareInts(lhs.eventCount, rhs.eventCount)
            case "promptCount":
                order = compareInts(lhs.promptCount, rhs.promptCount)
            default:
                order = compareStrings(lhs.lastSeen, rhs.lastSeen)
            }
            switch spec.direction {
            case .asc: return order == .orderedAscending
            case .desc: return order == .orderedDescending
            }
        }
    }
}

private func compareStrings(_ a: String?, _ b: String?) -> ComparisonResult {
    let lhs = a ?? ""
    let rhs = b ?? ""
    if lhs == rhs { return .orderedSame }
    return lhs < rhs ? .orderedAscending : .orderedDescending
}

// MARK: - models

enum ModelsCommand {
    static let name = "models"
    static let allowedSort = ["tokens", "name", "eventCount", "cost"]

    struct Row: Encodable {
        let name: String
        let distinctAgents: [String]
        let eventCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalTokens: Int
        let estimatedCostUSD: Double
        let costSource: String
    }

    struct Result: Encodable {
        let count: Int
        let totalCount: Int
        let models: [Row]
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
        if options.query != nil || options.promptId != nil {
            throw CLIError.invalidArgument("--query/--id are not supported on models.")
        }
        if let sort = options.sort { try sort.require(allowed: allowedSort) }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let events = CLIFilters.filterEvents(try repository.allEvents(), options: options)

        struct Bucket {
            var inputTokens = 0, outputTokens = 0, cacheTokens = 0
            var eventCount = 0
            var agents = Set<String>()
            var costUSD: Double = 0
        }

        var byModel: [String: Bucket] = [:]
        for event in events {
            let name = modelNameOrFallback(event)
            var bucket = byModel[name] ?? Bucket()
            bucket.inputTokens += event.inputTokens
            bucket.outputTokens += event.outputTokens
            bucket.cacheTokens += event.cacheTokens
            bucket.eventCount += 1
            bucket.agents.insert(event.agent.rawValue)
            bucket.costUSD += Double(event.inputTokens + event.outputTokens + event.cacheTokens) * event.agent.defaultCostPerMillionTokens / 1_000_000
            byModel[name] = bucket
        }

        let rows = byModel.map { name, bucket -> Row in
            Row(
                name: name,
                distinctAgents: Array(bucket.agents).sorted(),
                eventCount: bucket.eventCount,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheTokens: bucket.cacheTokens,
                totalTokens: bucket.inputTokens + bucket.outputTokens + bucket.cacheTokens,
                estimatedCostUSD: bucket.costUSD,
                costSource: "defaults"
            )
        }

        let sorted = sortRows(rows, sort: options.sort)
        let total = sorted.count
        let limited = options.limit == 0 ? sorted : Array(sorted.prefix(options.limit))
        let result = Result(count: limited.count, totalCount: total, models: limited)

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "models",
                result: result
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) models")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            print("  Count: \(limited.count) (of \(total))")
            for row in limited {
                print("  - \(row.name) total=\(row.totalTokens) events=\(row.eventCount) cost~$\(String(format: "%.4f", row.estimatedCostUSD)) (\(row.costSource)) agents=\(row.distinctAgents.joined(separator: ","))")
            }
        }
    }

    private static func sortRows(_ rows: [Row], sort: SortSpec?) -> [Row] {
        let spec = sort ?? SortSpec(field: "tokens", direction: .desc)
        return rows.sorted { lhs, rhs in
            let order: ComparisonResult
            switch spec.field {
            case "name":
                order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case "eventCount":
                order = compareInts(lhs.eventCount, rhs.eventCount)
            case "cost":
                if lhs.estimatedCostUSD == rhs.estimatedCostUSD {
                    order = .orderedSame
                } else if lhs.estimatedCostUSD < rhs.estimatedCostUSD {
                    order = .orderedAscending
                } else {
                    order = .orderedDescending
                }
            default:
                order = compareInts(lhs.totalTokens, rhs.totalTokens)
            }
            switch spec.direction {
            case .asc: return order == .orderedAscending
            case .desc: return order == .orderedDescending
            }
        }
    }
}

// MARK: - agents

enum AgentsCommand {
    static let name = "agents"
    static let allowedSort = ["tokens", "name", "eventCount"]

    struct Row: Encodable {
        let kind: String
        let displayName: String
        let eventCount: Int
        let promptCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalTokens: Int
        let distinctProjects: [String]
        let distinctModels: [String]
    }

    struct Result: Encodable {
        let count: Int
        let totalCount: Int
        let agents: [Row]
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
        if options.session != nil || options.agent != nil || options.query != nil || options.promptId != nil {
            throw CLIError.invalidArgument("--session/--agent/--query/--id are not allowed on agents.")
        }
        if let sort = options.sort { try sort.require(allowed: allowedSort) }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let events = CLIFilters.filterEvents(try repository.allEvents(), options: options)
        let prompts = CLIFilters.filterPrompts(try repository.allPrompts(), options: options)

        struct Bucket {
            var inputTokens = 0, outputTokens = 0, cacheTokens = 0
            var eventCount = 0
            var projects = Set<String>()
            var models = Set<String>()
        }

        var byAgent: [AgentKind: Bucket] = [:]
        for event in events {
            var bucket = byAgent[event.agent] ?? Bucket()
            bucket.inputTokens += event.inputTokens
            bucket.outputTokens += event.outputTokens
            bucket.cacheTokens += event.cacheTokens
            bucket.eventCount += 1
            bucket.projects.insert(event.projectName)
            let model = (event.modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty { bucket.models.insert(model) }
            byAgent[event.agent] = bucket
        }

        var promptCounts: [AgentKind: Int] = [:]
        for prompt in prompts {
            promptCounts[prompt.agent, default: 0] += 1
        }

        let rows = byAgent.map { agent, bucket -> Row in
            Row(
                kind: agent.rawValue,
                displayName: agent.displayName,
                eventCount: bucket.eventCount,
                promptCount: promptCounts[agent] ?? 0,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheTokens: bucket.cacheTokens,
                totalTokens: bucket.inputTokens + bucket.outputTokens + bucket.cacheTokens,
                distinctProjects: Array(bucket.projects).sorted(),
                distinctModels: Array(bucket.models).sorted()
            )
        }

        let sorted = sortRows(rows, sort: options.sort)
        let total = sorted.count
        let limited = options.limit == 0 ? sorted : Array(sorted.prefix(options.limit))
        let result = Result(count: limited.count, totalCount: total, agents: limited)

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "agents",
                result: result
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) agents")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            print("  Count: \(limited.count) (of \(total))")
            for row in limited {
                print("  - \(row.displayName) [\(row.kind)] total=\(row.totalTokens) events=\(row.eventCount) prompts=\(row.promptCount) projects=\(row.distinctProjects.count) models=\(row.distinctModels.count)")
            }
        }
    }

    private static func sortRows(_ rows: [Row], sort: SortSpec?) -> [Row] {
        let spec = sort ?? SortSpec(field: "tokens", direction: .desc)
        return rows.sorted { lhs, rhs in
            let order: ComparisonResult
            switch spec.field {
            case "name":
                order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            case "eventCount":
                order = compareInts(lhs.eventCount, rhs.eventCount)
            default:
                order = compareInts(lhs.totalTokens, rhs.totalTokens)
            }
            switch spec.direction {
            case .asc: return order == .orderedAscending
            case .desc: return order == .orderedDescending
            }
        }
    }
}
