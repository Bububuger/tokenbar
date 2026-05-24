import Foundation

public struct ClaudeUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "Claude Code"
    public let rootPath: String
    public let agent: AgentKind = .claudeCode
    public let daysBack: Int?
    private let fileManager: FileManager

    public init(rootPath: String = "~/.claude/projects", daysBack: Int? = nil, fileManager: FileManager = .default) {
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
        _ = calendar
        let files = try ClaudeDataSource.discoverSessionFiles(
            rootDirectory: rootPath,
            referenceDate: referenceDate,
            daysBack: daysBack,
            fileManager: fileManager
        )
        let rootDirectory = rootPath
        return try await JSONLWatermarkLoader.load(
            files: files,
            agent: agent,
            sourceName: sourceName,
            watermarks: watermarks,
            referenceDate: referenceDate,
            resourceThrottle: resourceThrottle
        ) { lines, fileURL in
            let slug = ClaudeDataSource.projectSlug(for: fileURL, rootDirectory: rootDirectory)
            return await ClaudeUsageParser.parse(
                lines: lines,
                fileURL: fileURL,
                fallbackProjectSlug: slug,
                resourceThrottle: resourceThrottle
            )
        }
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = calendar
        let expandedPath = ClaudeDataSource.expandHome(in: rootPath)
        let isReadable = fileManager.isReadableFile(atPath: expandedPath)
        let discoveredCount = (try? ClaudeDataSource.discoverSessionFiles(
            rootDirectory: rootPath,
            referenceDate: referenceDate,
            daysBack: daysBack,
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
