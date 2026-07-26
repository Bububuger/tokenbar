import Foundation

public struct CodexUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    private static let defaultRootPath = "~/.codex/sessions"
    private static let defaultArchiveRootPath = "~/.codex/archived_sessions"

    public let sourceName = "Codex"
    public let rootPath: String
    public let archiveRootPath: String?
    public let agent: AgentKind = .codex
    public let daysBack: Int?
    private let fileManager: FileManager

    public init(
        rootPath: String = "~/.codex/sessions",
        archiveRootPath: String? = nil,
        daysBack: Int? = nil,
        fileManager: FileManager = .default
    ) {
        self.rootPath = rootPath
        self.archiveRootPath = archiveRootPath
            ?? (rootPath == Self.defaultRootPath ? Self.defaultArchiveRootPath : nil)
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
            archiveRootDirectory: archiveRootPath,
            referenceDate: referenceDate,
            daysBack: daysBack,
            calendar: calendar,
            fileManager: fileManager
        )
        let archiveURL = CodexDataSource.resolvedArchiveURL(
            rootDirectory: rootPath,
            archiveRootDirectory: archiveRootPath
        )
        let rootURL = URL(
            fileURLWithPath: CodexDataSource.expandHome(in: rootPath),
            isDirectory: true
        ).standardizedFileURL
        let canonicalActiveRootPath = rootURL.lastPathComponent == "archived_sessions"
            ? rootURL.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true).path
            : rootURL.path
        return try await JSONLWatermarkLoader.load(
            files: files,
            agent: agent,
            sourceName: sourceName,
            watermarks: watermarks,
            referenceDate: referenceDate,
            resourceThrottle: resourceThrottle
        ) { lines, fileURL in
            let context = CodexUsageParser.sessionContext(fileURL: fileURL)
            let isArchived = archiveURL == fileURL
                .deletingLastPathComponent()
                .standardizedFileURL
            return await CodexUsageParser.parse(
                lines: lines,
                fileURL: fileURL,
                initialSessionID: context.sessionID,
                initialProjectPath: context.projectPath,
                canonicalActiveRootPath: isArchived ? canonicalActiveRootPath : nil,
                resourceThrottle: resourceThrottle
            )
        }
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        let expandedPath = CodexDataSource.expandHome(in: rootPath)
        let discoveredCount = (try? CodexDataSource.discoverRolloutFiles(
            rootDirectory: rootPath,
            archiveRootDirectory: archiveRootPath,
            referenceDate: referenceDate,
            daysBack: daysBack,
            calendar: calendar,
            fileManager: fileManager
        ).count) ?? 0
        let archiveIsReadable = CodexDataSource.resolvedArchiveURL(
            rootDirectory: rootPath,
            archiveRootDirectory: archiveRootPath
        ).map { fileManager.isReadableFile(atPath: $0.path) } ?? false
        let isReadable = fileManager.isReadableFile(atPath: expandedPath) || archiveIsReadable

        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: isReadable,
            discoveredFileCount: discoveredCount
        )
    }
}
