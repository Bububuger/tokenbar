import Foundation

public struct CursorUsageEventSource: InspectableUsageEventSource, @unchecked Sendable {
    public let sourceName = "Cursor"
    public let rootPath: String
    public let agent: AgentKind = .cursor
    private let fileManager: FileManager

    public init(
        rootPath: String = CursorDataSource.globalStatePath,
        fileManager: FileManager = .default
    ) {
        self.rootPath = rootPath
        self.fileManager = fileManager
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = referenceDate
        _ = calendar

        let sources = CursorDataSource.discoverSources(fileManager: fileManager)
        var prompts: [PromptRecord] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        for source in sources {
            switch source {
            case .globalState(let databaseURL):
                let result = try CursorUsageParser.parseGlobalState(
                    databaseURL: databaseURL,
                    watermark: watermarks[databaseURL.path]
                )
                prompts.append(contentsOf: result.prompts)
                nextWatermarks.append(contentsOf: result.nextWatermarks)
                warnings.append(contentsOf: result.warnings)
            case .hookJSONL(let fileURL):
                // Compatibility-only parser: hook token data is not discovered
                // or accumulated because dashboard events are authoritative.
                _ = fileURL
            }
        }

        return UsageSourceLoadResult(
            events: [],
            prompts: prompts,
            nextWatermarks: nextWatermarks,
            warnings: warnings
        )
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let sources = CursorDataSource.discoverSources(fileManager: fileManager)
        let expanded = CodexDataSource.expandHome(in: rootPath)
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: fileManager.isReadableFile(atPath: expanded) || !sources.isEmpty,
            discoveredFileCount: sources.count
        )
    }
}
