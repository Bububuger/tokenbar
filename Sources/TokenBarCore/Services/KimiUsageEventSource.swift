import Foundation

public struct KimiUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "Kimi Code"
    public let rootPath: String
    public let agent: AgentKind = .kimi
    private let rootDirectory: String?
    private let fileManager: FileManager
    private let environment: [String: String]
    private let homeDirectory: String

    public init(
        rootPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.rootDirectory = rootPath
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.rootPath = rootPath ?? KimiDataSource.resolvedRootDirectories(
            environment: environment,
            homeDirectory: homeDirectory
        ).joined(separator: ", ")
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
        let files = try KimiDataSource.discoverSessionFiles(
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return try await JSONLWatermarkLoader.load(
            files: files,
            agent: agent,
            sourceName: sourceName,
            watermarks: watermarks,
            referenceDate: referenceDate,
            resourceThrottle: resourceThrottle
        ) { lines, fileURL in
            KimiUsageParser.parse(lines: lines, fileURL: fileURL)
        }
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let roots = KimiDataSource.resolvedRootDirectories(
            rootDirectory: rootDirectory,
            environment: environment,
            homeDirectory: homeDirectory
        )
        let discoveredCount = (try? KimiDataSource.discoverSessionFiles(
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory
        ).count) ?? 0
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: roots.contains { fileManager.isReadableFile(atPath: $0) },
            discoveredFileCount: discoveredCount
        )
    }
}
