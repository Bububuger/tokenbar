import Foundation

public struct OpenClawUsageEventSource: InspectableUsageEventSource, ResourceBudgetedUsageEventSource, @unchecked Sendable {
    public let sourceName = "OpenClaw"
    public let rootPath: String
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

        var events: [UsageEvent] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        for file in files {
            let incremental = try await JSONLIncrementalReader.read(
                fileURL: file,
                sourceName: sourceName,
                agent: .openclaw,
                watermark: watermarks[file.path],
                now: referenceDate,
                resourceThrottle: resourceThrottle
            )
            warnings.append(contentsOf: incremental.warnings)
            if incremental.lines.isEmpty {
                nextWatermarks.append(
                    SourceWatermark(
                        sourcePath: incremental.nextWatermark.sourcePath,
                        agent: incremental.nextWatermark.agent,
                        lastMtime: incremental.nextWatermark.lastMtime,
                        lastByteOffset: incremental.nextWatermark.lastByteOffset,
                        lastEventId: watermarks[file.path]?.lastEventId,
                        lastInode: incremental.nextWatermark.lastInode,
                        updatedAt: incremental.nextWatermark.updatedAt
                    )
                )
                continue
            }

            let context = OpenClawUsageParser.sessionContext(fileURL: file)
            let result = OpenClawUsageParser.parse(
                lines: incremental.lines,
                fileURL: file,
                initialSessionID: context.sessionID,
                initialProjectPath: context.projectPath
            )
            events.append(contentsOf: result.events)
            nextWatermarks.append(
                SourceWatermark(
                    sourcePath: incremental.nextWatermark.sourcePath,
                    agent: incremental.nextWatermark.agent,
                    lastMtime: incremental.nextWatermark.lastMtime,
                    lastByteOffset: incremental.nextWatermark.lastByteOffset,
                    lastEventId: result.events.last?.id ?? watermarks[file.path]?.lastEventId,
                    lastInode: incremental.nextWatermark.lastInode,
                    updatedAt: incremental.nextWatermark.updatedAt
                )
            )
            warnings.append(contentsOf: result.warnings.map {
                UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: $0.sourcePath,
                    lineNumber: $0.lineNumber,
                    message: $0.message
                )
            })
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
