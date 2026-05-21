import Foundation

public struct ClaudeUsageEventSource: InspectableUsageEventSource, @unchecked Sendable {
    public let sourceName = "Claude Code"
    public let rootPath: String
    public let daysBack: Int
    private let fileManager: FileManager

    public init(rootPath: String = "~/.claude/projects", daysBack: Int = 30, fileManager: FileManager = .default) {
        self.rootPath = rootPath
        self.daysBack = daysBack
        self.fileManager = fileManager
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = calendar
        let files = try ClaudeDataSource.discoverSessionFiles(
            rootDirectory: rootPath,
            referenceDate: referenceDate,
            daysBack: daysBack,
            fileManager: fileManager
        )

        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        for file in files {
            let slug = file.deletingLastPathComponent().lastPathComponent
            let incremental = try JSONLIncrementalReader.read(
                fileURL: file,
                sourceName: sourceName,
                agent: .claudeCode,
                watermark: watermarks[file.path],
                now: referenceDate
            )
            let result = ClaudeUsageParser.parse(lines: incremental.lines, fileURL: file, fallbackProjectSlug: slug)
            events.append(contentsOf: result.events)
            prompts.append(contentsOf: result.prompts)
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
            warnings.append(contentsOf: incremental.warnings)
            warnings.append(contentsOf: result.warnings.map {
                UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: $0.sourcePath,
                    lineNumber: $0.lineNumber,
                    message: $0.message
                )
            })
        }

        return UsageSourceLoadResult(events: events, prompts: prompts, nextWatermarks: nextWatermarks, warnings: warnings)
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
