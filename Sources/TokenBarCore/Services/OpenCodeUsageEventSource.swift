import Foundation

public struct OpenCodeUsageEventSource: InspectableUsageEventSource, @unchecked Sendable {
    public let sourceName = "OpenCode"
    public let rootPath: String
    private let fileManager: FileManager

    public init(
        rootPath: String = OpenCodeDataSource.defaultDatabasePath,
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

        let databases = OpenCodeDataSource.discoverDatabases(
            rootPath: rootPath,
            fileManager: fileManager
        )

        var events: [UsageEvent] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        for database in databases {
            let result = try OpenCodeUsageParser.parse(
                databaseURL: database,
                watermark: watermarks[database.path]
            )
            events.append(contentsOf: result.events)
            nextWatermarks.append(contentsOf: result.nextWatermarks)
            warnings.append(contentsOf: result.warnings)
        }

        return UsageSourceLoadResult(
            events: events,
            prompts: [],
            nextWatermarks: nextWatermarks,
            warnings: warnings
        )
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let databases = OpenCodeDataSource.discoverDatabases(
            rootPath: rootPath,
            fileManager: fileManager
        )
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: !databases.isEmpty,
            discoveredFileCount: databases.count
        )
    }
}
