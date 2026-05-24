import Foundation

public struct OpenClawUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "OpenClaw"
    public let rootPath: String
    public let agent: AgentKind = .openclaw
    private let fileManager: FileManager

    public init(rootPath: String = "~/.openclaw", fileManager: FileManager = .default) {
        self.rootPath = rootPath
        self.fileManager = fileManager
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        try await loadEvents(
            since: watermarks,
            referenceDate: referenceDate,
            calendar: calendar,
            resourceThrottle: nil
        )
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar,
        resourceThrottle: IndexingResourceThrottle?
    ) async throws -> UsageSourceLoadResult {
        _ = calendar
        let files = try OpenClawDataSource.discoverSessionFiles(
            rootDirectory: rootPath,
            fileManager: fileManager
        )
        return try await JSONLWatermarkLoader.load(
            files: files,
            agent: agent,
            sourceName: sourceName,
            watermarks: watermarks,
            referenceDate: referenceDate,
            resourceThrottle: resourceThrottle
        ) { lines, fileURL in
            let context = OpenClawUsageParser.sessionContext(fileURL: fileURL)
            return OpenClawUsageParser.parse(
                lines: lines,
                fileURL: fileURL,
                initialSessionID: context.sessionID,
                initialProjectPath: context.projectPath
            )
        }
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let expanded = CodexDataSource.expandHome(in: rootPath)
        let discoveredCount = (try? OpenClawDataSource.discoverSessionFiles(
            rootDirectory: rootPath,
            fileManager: fileManager
        ).count) ?? 0
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: fileManager.isReadableFile(atPath: expanded),
            discoveredFileCount: discoveredCount
        )
    }
}
