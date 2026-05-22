import Darwin
import Foundation
import TokenBarCore

struct TokenBarCLI {
    static func main() async {
        do {
            let config = try parse()
            try await run(config)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            if error is CLIError {
                fputs("\n", stderr)
                printUsage()
                Foundation.exit(2)
            }
            Foundation.exit(1)
        }
    }

    private static func parse() throws -> RunConfiguration {
        let args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            return .init(dbPath: nil, command: .help)
        }

        var iterator = ArgumentCursor(args)
        var dbOverride: String?
        var command: ParsedCommand?

        while let arg = iterator.next() {
            switch arg {
            case "--help", "-h":
                return .init(dbPath: dbOverride, command: .help)
            case "--db":
                dbOverride = try iterator.nextValue(for: "--db")
            case "summary", "prompts", "hours", "hourly", "rebuild", "help":
                command = try parseCommand(named: arg, cursor: &iterator, dbOverride: dbOverride)
                break
            case let unknown where unknown.hasPrefix("-"):
                throw CLIError.invalidArgument("Unknown option: \(unknown)")
            default:
                throw CLIError.invalidArgument("Unknown command: \(arg)")
            }
            if command != nil {
                break
            }
        }

        if let command {
            return RunConfiguration(dbPath: dbOverride, command: command)
        }

        return .init(dbPath: dbOverride, command: .help)
    }

    private static func parseCommand(
        named: String,
        cursor: inout ArgumentCursor,
        dbOverride: String?
    ) throws -> ParsedCommand {
        switch named {
        case "help":
            return .help
        case "rebuild":
            var options = RebuildOptions(databasePath: dbOverride)
            while let arg = cursor.next() {
                switch arg {
                case "--help", "-h":
                    return .help
                case "--db":
                    options.databasePath = try cursor.nextValue(for: "--db")
                case "--background":
                    options.background = true
                case "--cpu-percent":
                    options.cpuPercent = try parseCPUPercent(try cursor.nextValue(for: "--cpu-percent"))
                case "--json":
                    options.json = true
                case let unknown where unknown.hasPrefix("-"):
                    throw CLIError.invalidArgument("Unknown rebuild option: \(unknown)")
                default:
                    throw CLIError.invalidArgument("Unexpected rebuild argument: \(arg)")
                }
            }
            return .rebuild(options)
        case "summary":
            var options = SummaryOptions(
                databasePath: dbOverride,
                days: 30,
                limit: 10
            )
            while let arg = cursor.next() {
                switch arg {
                case "--help", "-h":
                    return .help
                case "--db":
                    options.databasePath = try cursor.nextValue(for: "--db")
                case "--days":
                    options.days = try parseDays(try cursor.nextValue(for: "--days"))
                case "--project":
                    options.project = try cursor.nextValue(for: "--project")
                case "--limit":
                    options.limit = try parsePositiveInt(try cursor.nextValue(for: "--limit"), optionName: "limit")
                case "--json":
                    options.json = true
                case let unknown where unknown.hasPrefix("-"):
                    throw CLIError.invalidArgument("Unknown summary option: \(unknown)")
                default:
                    throw CLIError.invalidArgument("Unexpected summary argument: \(arg)")
                }
            }
            return .summary(options)
        case "prompts":
            var options = PromptOptions(
                databasePath: dbOverride,
                days: 30,
                limit: 10
            )
            while let arg = cursor.next() {
                switch arg {
                case "--help", "-h":
                    return .help
                case "--db":
                    options.databasePath = try cursor.nextValue(for: "--db")
                case "--days":
                    options.days = try parseDays(try cursor.nextValue(for: "--days"))
                case "--project":
                    options.project = try cursor.nextValue(for: "--project")
                case "--agent":
                    options.agentFilter = try parseAgent(try cursor.nextValue(for: "--agent"))
                case "--query":
                    options.query = try cursor.nextValue(for: "--query")
                case "--limit":
                    options.limit = try parsePositiveInt(try cursor.nextValue(for: "--limit"), optionName: "limit")
                case "--json":
                    options.json = true
                case let unknown where unknown.hasPrefix("-"):
                    throw CLIError.invalidArgument("Unknown prompts option: \(unknown)")
                default:
                    throw CLIError.invalidArgument("Unexpected prompts argument: \(arg)")
                }
            }
            return .prompts(options)
        case "hours", "hourly":
            var options = HourlyOptions(
                databasePath: dbOverride,
                days: 30,
                limit: 10
            )
            while let arg = cursor.next() {
                switch arg {
                case "--help", "-h":
                    return .help
                case "--db":
                    options.databasePath = try cursor.nextValue(for: "--db")
                case "--days":
                    options.days = try parseDays(try cursor.nextValue(for: "--days"))
                case "--project":
                    options.project = try cursor.nextValue(for: "--project")
                case "--agent":
                    options.agentFilter = try parseAgent(try cursor.nextValue(for: "--agent"))
                case "--limit":
                    options.limit = try parsePositiveInt(try cursor.nextValue(for: "--limit"), optionName: "limit")
                case "--json":
                    options.json = true
                case let unknown where unknown.hasPrefix("-"):
                    throw CLIError.invalidArgument("Unknown hours option: \(unknown)")
                default:
                    throw CLIError.invalidArgument("Unexpected hours argument: \(arg)")
                }
            }
            return .hours(options)
        default:
            throw CLIError.invalidArgument("Unknown command: \(named)")
        }
    }

    private static func parseDays(_ raw: String) throws -> Int {
        try parseInt(raw, optionName: "days", allowZero: true)
    }

    private static func parsePositiveInt(_ raw: String, optionName: String) throws -> Int {
        try parseInt(raw, optionName: optionName, allowZero: false)
    }

    private static func parseCPUPercent(_ raw: String) throws -> Double {
        guard let value = Double(raw), value >= 1, value <= 100 else {
            throw CLIError.invalidArgument("--cpu-percent must be between 1 and 100")
        }
        return value
    }

    private static func parseInt(_ raw: String, optionName: String, allowZero: Bool) throws -> Int {
        guard let value = Int(raw), value >= 0 else {
            throw CLIError.invalidArgument("--\(optionName) must be a non-negative integer")
        }
        if !allowZero && value == 0 {
            throw CLIError.invalidArgument("--\(optionName) must be greater than 0")
        }
        return value
    }

    private static func parseAgent(_ raw: String) throws -> AgentKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = AgentKind.allCases.first(where: { $0.rawValue == trimmed }) {
            return exact
        }
        let normalized = trimmed.lowercased()
        if let fuzzy = AgentKind.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
            return fuzzy
        }
        if let byDisplay = AgentKind.allCases.first(where: {
            $0.displayName.lowercased() == normalized
        }) {
            return byDisplay
        }
        let candidates = AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
        throw CLIError.invalidArgument("Unknown agent '\(raw)'. Allowed: \(candidates)")
    }

    private static func run(_ config: RunConfiguration) async throws {
        switch config.command {
        case .help:
            printUsage()
        case .rebuild(let options):
            try await runRebuild(with: options)
        case .summary(let options):
            try runSummary(with: options)
        case .prompts(let options):
            try runPrompts(with: options)
        case .hours(let options):
            try runHours(with: options)
        }
    }

    private static func runRebuild(with options: RebuildOptions) async throws {
        let started = Date()
        let databaseURL = resolveDatabasePath(options.databasePath)
        let store = try UsageStore(databaseURL: databaseURL)
        if options.background {
            _ = setpriority(PRIO_PROCESS, 0, 20)
        }
        let resourceThrottle = options.background || options.cpuPercent != nil
            ? IndexingResourceThrottle(budget: IndexingResourceBudget(cpuPercent: options.cpuPercent ?? IndexingResourceBudget.backgroundCPUPercent))
            : nil
        let sources: [any InspectableUsageEventSource] = [
            CodexUsageEventSource(daysBack: nil),
            ClaudeUsageEventSource(daysBack: nil),
            HermesUsageEventSource(),
        ]
        let calendar = Calendar(identifier: .gregorian)

        try await store.reparseAll()
        let engine = CheckpointEngine(sources: sources, store: store, resourceThrottle: resourceThrottle)
        let result = await engine.run(
            trigger: "cli-rebuild-all-history",
            startedAt: started,
            referenceDate: started,
            calendar: calendar
        )
        let state = result.state
        let statuses = await collectStatuses(from: sources, referenceDate: started, calendar: calendar)
        let totalInput = state.events.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = state.events.reduce(0) { $0 + $1.outputTokens }
        let totalCache = state.events.reduce(0) { $0 + $1.cacheTokens }
        let output = RebuildOutput(
            generatedAt: iso8601Date(Date()),
            databasePath: databaseURL.path,
            trigger: result.checkpoint?.trigger ?? "cli-rebuild-all-history",
            sourceWindow: "all-history",
            eventCount: state.events.count,
            promptCount: state.promptCount,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheTokens: totalCache,
            warningCount: state.warnings.count,
            rebuildError: state.lastRebuildError,
            checkpointEventsAdded: result.checkpoint?.eventsAdded,
            checkpointPromptsAdded: result.checkpoint?.promptsAdded,
            background: options.background || options.cpuPercent != nil,
            cpuPercent: options.cpuPercent ?? (options.background ? IndexingResourceBudget.backgroundCPUPercent : nil),
            resourceSnapshot: await resourceThrottle?.snapshot(),
            sources: statuses.map(DataSourceStatusOutput.from)
        )

        if options.json {
            printJSON(output)
            return
        }

        print("\(commandName()) rebuild")
        print("  Database: \(databaseURL.path)")
        print("  Source window: all-history")
        if output.background {
            print("  Mode: background (~\(formatCPUPercent(output.cpuPercent ?? IndexingResourceBudget.backgroundCPUPercent)) CPU budget)")
        }
        print("  Sources: Codex ~/.codex/sessions, Claude ~/.claude/projects, Hermes ~/.hermes/state.db")
        print("  Discovered files:")
        for source in output.sources {
            let readable = source.isReadable ? "readable" : "not readable"
            print("    \(source.name): \(source.discoveredFileCount) (\(readable))")
        }
        print("  Events: \(output.eventCount) | Prompts: \(output.promptCount)")
        print("  Input tokens: \(output.inputTokens)")
        print("  Output tokens: \(output.outputTokens)")
        print("  Cache tokens: \(output.cacheTokens)")
        print("  Total tokens: \(output.totalTokens)")
        print("  Checkpoint added: events \(output.checkpointEventsAdded ?? 0), prompts \(output.checkpointPromptsAdded ?? 0)")
        print("  Warnings: \(output.warningCount)")
        if let rebuildError = output.rebuildError, !rebuildError.isEmpty {
            print("  Rebuild error: \(rebuildError)")
        }
        if let resourceSnapshot = output.resourceSnapshot {
            print("  Estimated CPU: \(formatCPUPercent(resourceSnapshot.estimatedCPUPercent))")
        }
    }

    private static func runSummary(with options: SummaryOptions) throws {
        let repository = try makeRepository(path: options.databasePath)
        let events = try repository.allEvents()
        let allPrompts = try repository.allPrompts()
        let promptCount = filteredPromptsForSummaryCount(
            all: allPrompts,
            projectName: options.project,
            days: options.days
        ).count

        let filteredEvents = filterEvents(events, days: options.days, projectName: options.project)
        let topProjects = buildTopBreakdown(
            from: filteredEvents,
            key: { $0.projectName },
            name: { $0 },
            limit: options.limit
        )
        let topAgents = buildTopBreakdown(
            from: filteredEvents,
            key: { $0.agent },
            name: { $0.displayName },
            limit: options.limit
        )
        let topModels = buildTopBreakdown(
            from: filteredEvents,
            key: modelNameFallback,
            name: { $0 },
            limit: options.limit
        )

        let totalInput = filteredEvents.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = filteredEvents.reduce(0) { $0 + $1.outputTokens }
        let totalCache = filteredEvents.reduce(0) { $0 + $1.cacheTokens }

        let summary = SummaryOutput(
            generatedAt: iso8601Date(Date()),
            databasePath: resolveDatabasePath(options.databasePath).path,
            days: options.days,
            project: options.project,
            eventCount: filteredEvents.count,
            promptCount: promptCount,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheTokens: totalCache,
            topProjects: topProjects,
            topAgents: topAgents,
            topModels: topModels
        )

        if options.json {
            printJSON(summary)
            return
        }

        print("\(commandName()) summary")
        print("  Database: \(resolveDatabasePath(options.databasePath).path)")
        print("  Time window: \(options.days == 0 ? "all-time" : "last \(options.days) days")")
        if let project = options.project {
            print("  Project: \(project)")
        }
        print("  Events: \(summary.eventCount) | Prompts: \(summary.promptCount)")
        print("  Input tokens: \(summary.inputTokens)")
        print("  Output tokens: \(summary.outputTokens)")
        print("  Cache tokens: \(summary.cacheTokens)")
        print("  Total tokens: \(summary.totalTokens)")
        print("")
        print("  Top \(topProjects.count) projects")
        for (index, item) in summary.topProjects.enumerated() {
            print("    \(index + 1). \(item.name) - total \(item.totalTokens) (in \(item.inputTokens), out \(item.outputTokens), cache \(item.cacheTokens))")
        }
        print("")
        print("  Top \(topAgents.count) agents")
        for (index, item) in summary.topAgents.enumerated() {
            print("    \(index + 1). \(item.name) - total \(item.totalTokens) (in \(item.inputTokens), out \(item.outputTokens), cache \(item.cacheTokens))")
        }
        print("")
        print("  Top \(topModels.count) models")
        for (index, item) in summary.topModels.enumerated() {
            print("    \(index + 1). \(item.name) - total \(item.totalTokens) (in \(item.inputTokens), out \(item.outputTokens), cache \(item.cacheTokens))")
        }
    }

    private static func runHours(with options: HourlyOptions) throws {
        let repository = try makeRepository(path: options.databasePath)
        let events = try repository.allEvents()
        let snapshot = UsageAggregator.makeHourlySnapshot(
            from: events,
            referenceDate: Date(),
            calendar: Calendar.current,
            days: options.days,
            projectName: options.project,
            agent: options.agentFilter
        )
        let topHours = rankHours(snapshot.hours, limit: options.limit)
        let topHoursOfDay = rankHoursOfDay(snapshot.hoursOfDay, limit: options.limit)

        if options.json {
            let output = HourlyOutput(
                generatedAt: iso8601Date(snapshot.generatedAt),
                databasePath: resolveDatabasePath(options.databasePath).path,
                days: options.days,
                project: options.project,
                agent: options.agentFilter?.rawValue,
                eventCount: snapshot.eventCount,
                inputTokens: snapshot.summary.inputTokens,
                outputTokens: snapshot.summary.outputTokens,
                cacheTokens: snapshot.summary.cacheTokens,
                peakHour: snapshot.peakHour.map(HourBucketOutput.from),
                peakHourOfDay: snapshot.peakHourOfDay.map(HourOfDayOutput.from),
                topHours: topHours.map(HourBucketOutput.from),
                topHoursOfDay: topHoursOfDay.map(HourOfDayOutput.from),
                timeline: snapshot.hours.map(HourBucketOutput.from)
            )
            printJSON(output)
            return
        }

        print("\(commandName()) hours")
        print("  Database: \(resolveDatabasePath(options.databasePath).path)")
        print("  Time window: \(options.days == 0 ? "all-time" : "last \(options.days) days")")
        if let project = options.project {
            print("  Project: \(project)")
        }
        if let agent = options.agentFilter {
            print("  Agent: \(agent.displayName)")
        }
        print("  Events: \(snapshot.eventCount)")
        print("  Total tokens: \(snapshot.summary.totalTokens)")
        if let peakHour = snapshot.peakHour {
            print("  Peak concrete hour: \(formatHourRange(start: peakHour.start)) - \(peakHour.summary.totalTokens) tokens")
        }
        if let peakHourOfDay = snapshot.peakHourOfDay {
            print("  Peak daily time slot: \(formatHourOfDay(peakHourOfDay.hourOfDay)) - \(peakHourOfDay.summary.totalTokens) tokens across \(peakHourOfDay.activeHourCount) active hour(s)")
        }
        print("")
        print("  Top \(topHoursOfDay.count) daily time slots")
        for (index, item) in topHoursOfDay.enumerated() {
            print("    \(index + 1). \(formatHourOfDay(item.hourOfDay)) - total \(item.summary.totalTokens) (events \(item.eventCount), active hours \(item.activeHourCount))")
        }
        print("")
        print("  Top \(topHours.count) concrete hours")
        for (index, item) in topHours.enumerated() {
            print("    \(index + 1). \(formatHourRange(start: item.start)) - total \(item.summary.totalTokens) (events \(item.eventCount))")
        }
    }

    private static func runPrompts(with options: PromptOptions) throws {
        let repository = try makeRepository(path: options.databasePath)
        let events = try repository.allEvents()
        let prompts = try repository.allPrompts()
        let eventById = Dictionary(uniqueKeysWithValues: events.compactMap { ($0.id, $0) })

        let matched = filterPrompts(prompts, options: options)
        var filtered = matched
        filtered.sort { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
        if options.limit > 0 && filtered.count > options.limit {
            filtered = Array(filtered.prefix(options.limit))
        }

        if options.json {
            let output = PromptListOutput(
                generatedAt: iso8601Date(Date()),
                databasePath: resolveDatabasePath(options.databasePath).path,
                days: options.days,
                project: options.project,
                agent: options.agentFilter?.rawValue,
                query: options.query,
                totalCount: matched.count,
                limit: options.limit,
                count: filtered.count,
                prompts: filtered.map { prompt in
                    PromptOutput.from(
                        prompt,
                        modelName: modelNameFromPrompt(prompt, eventById: eventById)
                    )
                }
            )
            printJSON(output)
            return
        }

        print("\(commandName()) prompts")
        print("  Database: \(resolveDatabasePath(options.databasePath).path)")
        print("  Time window: \(options.days == 0 ? "all-time" : "last \(options.days) days")")
        if let project = options.project {
            print("  Project: \(project)")
        }
        if let agent = options.agentFilter {
            print("  Agent: \(agent.displayName)")
        }
        if let query = options.query, !query.isEmpty {
            print("  Query: \(query)")
        }
        print("  Count: \(filtered.count)")
        print("")

        if filtered.isEmpty {
            print("No prompts found.")
            return
        }

        for (index, prompt) in filtered.enumerated() {
            let modelName = modelNameFromPrompt(prompt, eventById: eventById)
            print("[\(index + 1)]")
            print("  time: \(formatDate(prompt.timestamp))")
            print("  agent: \(prompt.agent.displayName)")
            print("  model: \(modelName)")
            print("  project: \(prompt.projectName)")
            print("  session: \(prompt.sessionId)")
            print("  prompt: \(truncate(prompt.content, 220))")
        }
    }

    private static func collectStatuses(
        from sources: [any InspectableUsageEventSource],
        referenceDate: Date,
        calendar: Calendar
    ) async -> [UsageDataSourceStatus] {
        var statuses: [UsageDataSourceStatus] = []
        for source in sources {
            statuses.append(await source.status(referenceDate: referenceDate, calendar: calendar))
        }
        return statuses.sorted { $0.sourceName < $1.sourceName }
    }

    private static func filterEvents(_ events: [UsageEvent], days: Int, projectName: String?) -> [UsageEvent] {
        let cutoff = days == 0 ? nil : cutoffDate(days: days)
        return events.filter { event in
            if let cutoff, event.timestamp < cutoff {
                return false
            }
            if let projectName, event.projectName != projectName {
                return false
            }
            return true
        }
    }

    private static func filterPrompts(_ prompts: [PromptRecord], options: PromptOptions) -> [PromptRecord] {
        let cutoff = options.days == 0 ? nil : cutoffDate(days: options.days)
        return prompts.filter { prompt in
            if let cutoff, prompt.timestamp < cutoff {
                return false
            }
            if let projectName = options.project, prompt.projectName != projectName {
                return false
            }
            if let agentFilter = options.agentFilter, prompt.agent != agentFilter {
                return false
            }
            if let query = options.query, !query.isEmpty {
                if prompt.content.range(of: query, options: .caseInsensitive) == nil {
                    return false
                }
            }
            return true
        }
    }

    private static func cutoffDate(days: Int) -> Date? {
        Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }

    private static func modelNameFallback(_ event: UsageEvent) -> String {
        if let model = event.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        return event.agent.displayName
    }

    private static func modelNameFromPrompt(_ prompt: PromptRecord, eventById: [String: UsageEvent]) -> String {
        guard let eventId = prompt.eventId, let event = eventById[eventId],
              let modelName = event.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelName.isEmpty else {
            return prompt.agent.displayName
        }
        return modelName
    }

    private static func buildTopBreakdown<Key>(
        from events: [UsageEvent],
        key: (UsageEvent) -> Key,
        name: (Key) -> String,
        limit: Int
    ) -> [TokenBucketOutput] where Key: Hashable {
        var buckets: [Key: TokenBucket] = [:]
        for event in events {
            let bucketKey = key(event)
            var bucket = buckets[bucketKey] ?? TokenBucket()
            bucket.add(event)
            buckets[bucketKey] = bucket
        }

        return buckets
            .map { entry in
                let key = entry.key
                let bucket = entry.value
                return TokenBucketOutput(
                    name: name(key),
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    cacheTokens: bucket.cacheTokens
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens == rhs.totalTokens {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.totalTokens > rhs.totalTokens
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func rankHours(_ hours: [UsageHour], limit: Int) -> [UsageHour] {
        hours
            .filter { $0.summary.totalTokens > 0 }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.start > rhs.start
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func rankHoursOfDay(_ hours: [UsageHourOfDay], limit: Int) -> [UsageHourOfDay] {
        hours
            .filter { $0.summary.totalTokens > 0 }
            .sorted { lhs, rhs in
                if lhs.summary.totalTokens == rhs.summary.totalTokens {
                    return lhs.hourOfDay < rhs.hourOfDay
                }
                return lhs.summary.totalTokens > rhs.summary.totalTokens
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func makeRepository(path: String?) throws -> UsageRepository {
        let resolved = resolveDatabasePath(path)
        return try UsageRepository(databaseURL: resolved)
    }

    private static func resolveDatabasePath(_ explicitPath: String?) -> URL {
        let path = explicitPath ?? UsageDatabase.defaultDatabaseURL().path
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            fputs("Failed to encode JSON output: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    fileprivate static func iso8601Date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    fileprivate static func formatHourRange(start: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:00"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let end = Calendar.current.date(byAdding: .minute, value: 59, to: start) ?? start
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "HH:59"
        endFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(formatter.string(from: start))-\(endFormatter.string(from: end))"
    }

    fileprivate static func formatHourOfDay(_ hour: Int) -> String {
        let normalized = max(0, min(23, hour))
        return String(format: "%02d:00-%02d:59", normalized, normalized)
    }

    private static func formatCPUPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private static func truncate(_ value: String, _ maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }
        let maxIndex = value.index(value.startIndex, offsetBy: max(0, maxLength))
        return "\(value[value.startIndex..<maxIndex])..."
    }

    private static func printUsage() {
        let usage = """
Usage:
  \(commandName()) [--db <path>] <command> [options]

Commands:
  rebuild     Rescan all local agent history and rebuild the index
    --background    Run at utility priority with a \(formatCPUPercent(IndexingResourceBudget.backgroundCPUPercent)) CPU budget
    --cpu-percent N Override background CPU budget (1-100)
    --json          Emit JSON output

  summary     Show token summary
    --days N        Filter by last N days (default 30, 0 = all-time)
    --project <name> Filter to project name
    --limit N       Top-N results per breakdown (default 10)
    --json          Emit JSON output

  prompts     List prompt history
    --days N        Filter by last N days (default 30, 0 = all-time)
    --project <name> Filter to project name
    --agent <codex|claudeCode|hermes|geminiCLI|custom>
    --query <text>  Substring match on prompt content
    --limit N       Max results (default 10)
    --json          Emit JSON output

  hours       Show hourly token peaks and daily peak time slots
    --days N        Filter by last N days (default 30, 0 = all-time)
    --project <name> Filter to project name
    --agent <codex|claudeCode|hermes|geminiCLI|custom>
    --limit N       Top-N hourly results (default 10)
    --json          Emit JSON output, including the hourly timeline

  help        Show this message

Options:
  --db <path>      Override database path (default to usage DB)
  -h, --help       Show usage
"""
        print(usage)
    }

    private static func commandName() -> String {
        guard let executablePath = CommandLine.arguments.first else {
            return "tb"
        }
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        return name.isEmpty ? "tb" : name
    }

    private static func filteredPromptsForSummaryCount(all: [PromptRecord], projectName: String?, days: Int) -> [PromptRecord] {
        let cutoff = days == 0 ? nil : cutoffDate(days: days)
        return all.filter { prompt in
            if let projectName, prompt.projectName != projectName {
                return false
            }
            if let cutoff, prompt.timestamp < cutoff {
                return false
            }
            return true
        }
    }
}

private struct RunConfiguration {
    let command: ParsedCommand
    let databasePath: String?

    init(dbPath: String?, command: ParsedCommand) {
        self.databasePath = dbPath
        self.command = command
    }
}

private enum ParsedCommand {
    case help
    case rebuild(RebuildOptions)
    case summary(SummaryOptions)
    case prompts(PromptOptions)
    case hours(HourlyOptions)
}

private struct RebuildOptions {
    var databasePath: String?
    var background = false
    var cpuPercent: Double?
    var json: Bool = false
}

private struct SummaryOptions {
    var databasePath: String?
    var days: Int
    var project: String?
    var limit: Int
    var json: Bool = false
}

private struct PromptOptions {
    var databasePath: String?
    var days: Int
    var project: String?
    var agentFilter: AgentKind?
    var query: String?
    var limit: Int
    var json: Bool = false
}

private struct HourlyOptions {
    var databasePath: String?
    var days: Int
    var project: String?
    var agentFilter: AgentKind?
    var limit: Int
    var json: Bool = false
}

private struct TokenBucket {
    var inputTokens = 0
    var outputTokens = 0
    var cacheTokens = 0

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheTokens += event.cacheTokens
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheTokens
    }
}

private struct TokenBucketOutput: Codable {
    let name: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalTokens: Int

    init(name: String, inputTokens: Int, outputTokens: Int, cacheTokens: Int) {
        self.name = name
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.totalTokens = inputTokens + outputTokens + cacheTokens
    }
}

private struct RebuildOutput: Codable {
    let generatedAt: String
    let databasePath: String
    let trigger: String
    let sourceWindow: String
    let eventCount: Int
    let promptCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalTokens: Int
    let warningCount: Int
    let rebuildError: String?
    let checkpointEventsAdded: Int?
    let checkpointPromptsAdded: Int?
    let background: Bool
    let cpuPercent: Double?
    let resourceSnapshot: IndexingResourceSnapshot?
    let sources: [DataSourceStatusOutput]

    init(
        generatedAt: String,
        databasePath: String,
        trigger: String,
        sourceWindow: String,
        eventCount: Int,
        promptCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        warningCount: Int,
        rebuildError: String?,
        checkpointEventsAdded: Int?,
        checkpointPromptsAdded: Int?,
        background: Bool,
        cpuPercent: Double?,
        resourceSnapshot: IndexingResourceSnapshot?,
        sources: [DataSourceStatusOutput]
    ) {
        self.generatedAt = generatedAt
        self.databasePath = databasePath
        self.trigger = trigger
        self.sourceWindow = sourceWindow
        self.eventCount = eventCount
        self.promptCount = promptCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.totalTokens = inputTokens + outputTokens + cacheTokens
        self.warningCount = warningCount
        self.rebuildError = rebuildError
        self.checkpointEventsAdded = checkpointEventsAdded
        self.checkpointPromptsAdded = checkpointPromptsAdded
        self.background = background
        self.cpuPercent = cpuPercent
        self.resourceSnapshot = resourceSnapshot
        self.sources = sources
    }
}

private struct DataSourceStatusOutput: Codable {
    let name: String
    let rootPath: String
    let isReadable: Bool
    let discoveredFileCount: Int

    static func from(_ status: UsageDataSourceStatus) -> DataSourceStatusOutput {
        DataSourceStatusOutput(
            name: status.sourceName,
            rootPath: status.rootPath,
            isReadable: status.isReadable,
            discoveredFileCount: status.discoveredFileCount
        )
    }
}

private struct SummaryOutput: Codable {
    let generatedAt: String
    let databasePath: String
    let days: Int
    let project: String?
    let eventCount: Int
    let promptCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalTokens: Int
    let topProjects: [TokenBucketOutput]
    let topAgents: [TokenBucketOutput]
    let topModels: [TokenBucketOutput]

    init(
        generatedAt: String,
        databasePath: String,
        days: Int,
        project: String?,
        eventCount: Int,
        promptCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        topProjects: [TokenBucketOutput],
        topAgents: [TokenBucketOutput],
        topModels: [TokenBucketOutput]
    ) {
        self.generatedAt = generatedAt
        self.databasePath = databasePath
        self.days = days
        self.project = project
        self.eventCount = eventCount
        self.promptCount = promptCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.totalTokens = inputTokens + outputTokens + cacheTokens
        self.topProjects = topProjects
        self.topAgents = topAgents
        self.topModels = topModels
    }
}

private struct PromptOutput: Codable {
    let id: String
    let timestamp: String
    let agent: String
    let agentRaw: String
    let agentDisplayName: String
    let projectName: String
    let sessionId: String
    let modelName: String
    let sourcePath: String
    let content: String
    let contentHash: String
    let eventId: String?

    static func from(_ prompt: PromptRecord, modelName: String) -> Self {
        PromptOutput(
            id: prompt.id,
            timestamp: iso8601Date(prompt.timestamp),
            agent: prompt.agent.rawValue,
            agentRaw: prompt.agent.rawValue,
            agentDisplayName: prompt.agent.displayName,
            projectName: prompt.projectName,
            sessionId: prompt.sessionId,
            modelName: modelName,
            sourcePath: prompt.sourcePath,
            content: prompt.content,
            contentHash: prompt.contentHash,
            eventId: prompt.eventId
        )
    }

    private static func iso8601Date(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

private struct PromptListOutput: Codable {
    let generatedAt: String
    let databasePath: String
    let days: Int
    let project: String?
    let agent: String?
    let query: String?
    let totalCount: Int
    let limit: Int
    let count: Int
    let prompts: [PromptOutput]
}

private struct HourBucketOutput: Codable {
    let start: String
    let hourOfDay: Int
    let label: String
    let eventCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalTokens: Int
    let intensity: Double

    static func from(_ hour: UsageHour) -> Self {
        HourBucketOutput(
            start: TokenBarCLI.iso8601Date(hour.start),
            hourOfDay: hour.hourOfDay,
            label: TokenBarCLI.formatHourRange(start: hour.start),
            eventCount: hour.eventCount,
            inputTokens: hour.summary.inputTokens,
            outputTokens: hour.summary.outputTokens,
            cacheTokens: hour.summary.cacheTokens,
            totalTokens: hour.summary.totalTokens,
            intensity: hour.intensity
        )
    }
}

private struct HourOfDayOutput: Codable {
    let hourOfDay: Int
    let label: String
    let eventCount: Int
    let activeHourCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalTokens: Int
    let intensity: Double

    static func from(_ hour: UsageHourOfDay) -> Self {
        HourOfDayOutput(
            hourOfDay: hour.hourOfDay,
            label: TokenBarCLI.formatHourOfDay(hour.hourOfDay),
            eventCount: hour.eventCount,
            activeHourCount: hour.activeHourCount,
            inputTokens: hour.summary.inputTokens,
            outputTokens: hour.summary.outputTokens,
            cacheTokens: hour.summary.cacheTokens,
            totalTokens: hour.summary.totalTokens,
            intensity: hour.intensity
        )
    }
}

private struct HourlyOutput: Codable {
    let generatedAt: String
    let databasePath: String
    let days: Int
    let project: String?
    let agent: String?
    let eventCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalTokens: Int
    let peakHour: HourBucketOutput?
    let peakHourOfDay: HourOfDayOutput?
    let topHours: [HourBucketOutput]
    let topHoursOfDay: [HourOfDayOutput]
    let timeline: [HourBucketOutput]

    init(
        generatedAt: String,
        databasePath: String,
        days: Int,
        project: String?,
        agent: String?,
        eventCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        peakHour: HourBucketOutput?,
        peakHourOfDay: HourOfDayOutput?,
        topHours: [HourBucketOutput],
        topHoursOfDay: [HourOfDayOutput],
        timeline: [HourBucketOutput]
    ) {
        self.generatedAt = generatedAt
        self.databasePath = databasePath
        self.days = days
        self.project = project
        self.agent = agent
        self.eventCount = eventCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.totalTokens = inputTokens + outputTokens + cacheTokens
        self.peakHour = peakHour
        self.peakHourOfDay = peakHourOfDay
        self.topHours = topHours
        self.topHoursOfDay = topHoursOfDay
        self.timeline = timeline
    }
}

private struct ArgumentCursor {
    private var values: [String]
    private(set) var index = 0

    init(_ values: [String]) {
        self.values = values
    }

    mutating func next() -> String? {
        guard index < values.count else {
            return nil
        }
        defer { index += 1 }
        return values[index]
    }

    mutating func nextValue(for optionName: String) throws -> String {
        guard let value = next() else {
            throw CLIError.invalidArgument("Missing value for \(optionName)")
        }
        return value
    }
}

private enum CLIError: LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let reason):
            return reason
        }
    }
}

@main
struct TokenBarCLIEntry {
    static func main() async {
        await TokenBarCLI.main()
    }
}
