import Foundation

/// omp (oh-my-pi) is a fork of pi writing the same version-3 session JSONL under
/// `~/.omp/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl`. Discovery reuses
/// `PiDataSource`; parsing reuses `PiUsageParser` with `Dialect.omp`, which maps
/// omp's `reasoningTokens` usage field. omp additionally emits title / custom /
/// custom_message / mode_change entry types that carry no usage and are skipped.
public struct OmpUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "oh-my-pi"
    public let rootPath: String
    public let agent: AgentKind = .omp
    private let fileManager: FileManager

    public init(rootPath: String = "~/.omp/agent", fileManager: FileManager = .default) {
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
        let files = try PiDataSource.discoverSessionFiles(
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
            let context = PiUsageParser.sessionContext(fileURL: fileURL)
            return PiUsageParser.parse(
                lines: lines,
                fileURL: fileURL,
                initialSessionID: context.sessionID,
                initialProjectPath: context.projectPath,
                dialect: .omp
            )
        }
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let expanded = CodexDataSource.expandHome(in: rootPath)
        let discoveredCount = (try? PiDataSource.discoverSessionFiles(
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
