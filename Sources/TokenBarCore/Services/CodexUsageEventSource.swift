import Foundation

public struct CodexUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "Codex"
    public let rootPath: String
    public let agent: AgentKind = .codex
    public let daysBack: Int?
    private let fileManager: FileManager

    public init(rootPath: String = "~/.codex/sessions", daysBack: Int? = nil, fileManager: FileManager = .default) {
        self.rootPath = rootPath
        self.daysBack = daysBack
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
        let files = try CodexDataSource.discoverRolloutFiles(
            rootDirectory: rootPath,
            referenceDate: referenceDate,
            daysBack: daysBack,
            calendar: calendar,
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
            let context = CodexUsageParser.sessionContext(fileURL: fileURL)
            return await CodexUsageParser.parse(
                lines: lines,
                fileURL: fileURL,
                initialSessionID: context.sessionID,
                initialProjectPath: context.projectPath,
                resourceThrottle: resourceThrottle
            )
        }
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        let expandedPath = CodexDataSource.expandHome(in: rootPath)
        let isReadable = fileManager.isReadableFile(atPath: expandedPath)
        let discoveredCount = (try? CodexDataSource.discoverRolloutFiles(
            rootDirectory: rootPath,
            referenceDate: referenceDate,
            daysBack: daysBack,
            calendar: calendar,
            fileManager: fileManager
        ).count) ?? 0

        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: isReadable,
            discoveredFileCount: discoveredCount
        )
    }
}
