import Darwin
import Foundation
import TokenBarCore

enum RebuildCommand {
    struct Options {
        var databasePath: String?
        var background: Bool = false
        var cpuPercent: Double?
        var json: Bool = false
    }

    static func parse(cursor: inout ArgumentCursor, dbOverride: String?) throws -> Options {
        var options = Options(databasePath: dbOverride)
        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h":
                throw HelpRequested.command("rebuild")
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
        return options
    }

    static func run(_ options: Options) async throws {
        let started = Date()
        let databaseURL = CLIPath.resolve(options.databasePath)
        let store = try UsageStore(databaseURL: databaseURL)
        if options.background {
            _ = setpriority(PRIO_PROCESS, 0, 20)
        }
        let resourceThrottle = options.background || options.cpuPercent != nil
            ? IndexingResourceThrottle(budget: IndexingResourceBudget(cpuPercent: options.cpuPercent ?? IndexingResourceBudget.backgroundCPUPercent))
            : nil
        let builtInSources = BuiltInSources.all()
        let customSources = (try? await store.customSources())
            .map { records in
                records
                    .filter(\.enabled)
                    .map { CustomUsageEventSource(record: $0) as any InspectableUsageEventSource }
            } ?? []
        let sources = builtInSources + customSources
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
        let totalCacheRead = state.events.reduce(0) { $0 + $1.cacheReadTokens }
        let totalCacheCreation = state.events.reduce(0) { $0 + $1.cacheCreationTokens }
        let output = RebuildOutput(
            generatedAt: CLIOutput.iso(Date()),
            databasePath: databaseURL.path,
            trigger: result.checkpoint?.trigger ?? "cli-rebuild-all-history",
            sourceWindow: "all-history",
            eventCount: state.events.count,
            promptCount: state.promptCount,
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            cacheCreationTokens: totalCacheCreation,
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
            CLIOutput.writeJSON(output)
            return
        }

        let programName = CLIProgramName.current()
        print("\(programName) rebuild")
        print("  Database: \(databaseURL.path)")
        print("  Source window: all-history")
        if output.background {
            print("  Mode: background (~\(formatCPUPercent(output.cpuPercent ?? IndexingResourceBudget.backgroundCPUPercent)) CPU budget)")
        }
        print("  Sources (\(output.sources.count)):")
        for source in output.sources {
            let readable = source.isReadable ? "readable" : "not readable"
            print("    - \(source.name) \(source.rootPath) — \(source.discoveredFileCount) files (\(readable))")
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

    private static func parseCPUPercent(_ raw: String) throws -> Double {
        guard let value = Double(raw), value >= 1, value <= 100 else {
            throw CLIError.invalidArgument("--cpu-percent must be between 1 and 100")
        }
        return value
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

    private static func formatCPUPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

struct RebuildOutput: Encodable {
    let generatedAt: String
    let databasePath: String
    let trigger: String
    let sourceWindow: String
    let eventCount: Int
    let promptCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let totalTokens: Int
    let warningCount: Int
    let rebuildError: String?
    let checkpointEventsAdded: Int?
    let checkpointPromptsAdded: Int?
    let background: Bool
    let cpuPercent: Double?
    let resourceSnapshot: IndexingResourceSnapshot?
    let sources: [DataSourceStatusOutput]

    var cacheTokens: Int { cacheReadTokens + cacheCreationTokens }

    init(
        generatedAt: String,
        databasePath: String,
        trigger: String,
        sourceWindow: String,
        eventCount: Int,
        promptCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
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
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
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

struct DataSourceStatusOutput: Encodable {
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
