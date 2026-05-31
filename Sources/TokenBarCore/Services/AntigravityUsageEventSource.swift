import Foundation

public struct AntigravityUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "Antigravity"
    public let rootPath: String
    public let agent: AgentKind = .antigravity
    private let roots: [String]
    private let fileManager: FileManager

    public init(roots: [String] = AntigravityDataSource.defaultRoots, fileManager: FileManager = .default) {
        self.roots = roots
        self.rootPath = roots.first ?? "~/.gemini/antigravity"
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
        let files = try AntigravityDataSource.discoverSessionFiles(
            roots: roots,
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
            AntigravityUsageParser.parse(lines: lines, fileURL: fileURL)
        }
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let expanded = CodexDataSource.expandHome(in: rootPath)
        let discoveredCount = (try? AntigravityDataSource.discoverSessionFiles(
            roots: roots,
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
