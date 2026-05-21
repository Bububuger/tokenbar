import Foundation

public struct CustomSourceRegistry: Sendable {
    private let store: UsageStore

    public init(store: UsageStore) {
        self.store = store
    }

    public func list() async -> [CustomSourceRecord] {
        (try? await store.customSources()) ?? []
    }

    public func upsert(_ source: CustomSourceRecord) async throws {
        try await store.upsertCustomSource(source)
    }

    public func delete(id: String) async throws {
        try await store.deleteCustomSource(id: id)
    }
}

public struct CustomUsageEventSource: InspectableUsageEventSource, @unchecked Sendable {
    public let sourceName: String
    public let rootPath: String
    public let record: CustomSourceRecord
    private let fileManager: FileManager

    public init(record: CustomSourceRecord, fileManager: FileManager = .default) {
        self.record = record
        self.sourceName = record.name
        self.rootPath = record.directory
        self.fileManager = fileManager
    }

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = referenceDate
        _ = calendar
        let files = try discoverFiles()
        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        for file in files {
            let format = record.format == .auto
                ? SourceFormatDetector.detect(fileURL: file)
                : record.format
            switch format {
            case .claudeCodeJSONL:
                let slug = file.deletingLastPathComponent().lastPathComponent
                let incremental = try JSONLIncrementalReader.read(
                    fileURL: file,
                    sourceName: sourceName,
                    agent: .custom,
                    watermark: watermarks[file.path],
                    now: referenceDate
                )
                let result = ClaudeUsageParser.parse(lines: incremental.lines, fileURL: file, fallbackProjectSlug: slug)
                events.append(contentsOf: result.events.map { customEvent($0) })
                prompts.append(contentsOf: result.prompts.map { customPrompt($0) })
                nextWatermarks.append(customWatermark(from: incremental.nextWatermark, lastEventId: result.events.last?.id ?? watermarks[file.path]?.lastEventId))
                warnings.append(contentsOf: incremental.warnings)
                warnings.append(contentsOf: result.warnings.map {
                    UsageSourceWarning(sourceName: sourceName, sourcePath: $0.sourcePath, lineNumber: $0.lineNumber, message: $0.message)
                })
            case .codexJSONL:
                let incremental = try JSONLIncrementalReader.read(
                    fileURL: file,
                    sourceName: sourceName,
                    agent: .custom,
                    watermark: watermarks[file.path],
                    now: referenceDate
                )
                let context = CodexUsageParser.sessionContext(fileURL: file)
                let result = CodexUsageParser.parse(lines: incremental.lines, fileURL: file, initialSessionID: context.sessionID, initialProjectPath: context.projectPath)
                events.append(contentsOf: result.events.map { customEvent($0) })
                prompts.append(contentsOf: result.prompts.map { customPrompt($0) })
                nextWatermarks.append(customWatermark(from: incremental.nextWatermark, lastEventId: result.events.last?.id ?? watermarks[file.path]?.lastEventId))
                warnings.append(contentsOf: incremental.warnings)
                warnings.append(contentsOf: result.warnings.map {
                    UsageSourceWarning(sourceName: sourceName, sourcePath: $0.sourcePath, lineNumber: $0.lineNumber, message: $0.message)
                })
            case .auto, .unknown:
                warnings.append(
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: file.path,
                        lineNumber: nil,
                        message: "custom source format could not be detected"
                    )
                )
            }
        }

        return UsageSourceLoadResult(events: events, prompts: prompts, nextWatermarks: nextWatermarks, warnings: warnings)
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        let files = (try? discoverFiles()) ?? []
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: fileManager.isReadableFile(atPath: expandedDirectory),
            discoveredFileCount: files.count
        )
    }

    private var expandedDirectory: String {
        CodexDataSource.expandHome(in: record.directory)
    }

    private func discoverFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: expandedDirectory, isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else {
            return []
        }

        let recursive = record.globPattern.contains("**")
        let suffix = record.globPattern.split(separator: "*").last.map(String.init) ?? ".jsonl"
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL else { return nil }
                guard url.lastPathComponent.hasSuffix(suffix) else { return nil }
                return url
            }.sorted { $0.path < $1.path }
        }

        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasSuffix(suffix) }
        .sorted { $0.path < $1.path }
    }

    private func customEvent(_ event: UsageEvent) -> UsageEvent {
        UsageEvent(
            id: "custom:\(record.id):\(event.id)",
            agent: .custom,
            projectPath: event.projectPath,
            projectName: event.projectName,
            sessionId: event.sessionId,
            timestamp: event.timestamp,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheTokens: event.cacheTokens,
            reasoningTokens: event.reasoningTokens,
            modelName: event.modelName,
            sourcePath: event.sourcePath,
            parser: .custom,
            confidence: event.confidence
        )
    }

    private func customPrompt(_ prompt: PromptRecord) -> PromptRecord {
        PromptRecord(
            id: "custom:\(record.id):\(prompt.id)",
            eventId: prompt.eventId.map { "custom:\(record.id):\($0)" },
            agent: .custom,
            projectName: prompt.projectName,
            sessionId: prompt.sessionId,
            timestamp: prompt.timestamp,
            content: prompt.content,
            contentHash: prompt.contentHash,
            sourcePath: prompt.sourcePath
        )
    }

    private func customWatermark(from watermark: SourceWatermark, lastEventId: String?) -> SourceWatermark {
        SourceWatermark(
            sourcePath: watermark.sourcePath,
            agent: .custom,
            lastMtime: watermark.lastMtime,
            lastByteOffset: watermark.lastByteOffset,
            lastEventId: lastEventId.map { "custom:\(record.id):\($0)" },
            lastInode: watermark.lastInode,
            updatedAt: watermark.updatedAt
        )
    }
}

public enum SourceFormatDetector {
    public static func detect(fileURL: URL, sampleLineLimit: Int = 20) -> CustomSourceFormat {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return .unknown
        }
        for line in text.split(whereSeparator: \.isNewline).prefix(sampleLineLimit) {
            let lineText = String(line)
            if lineText.contains("\"message\""), lineText.contains("\"usage\""), lineText.contains("\"input_tokens\"") {
                return .claudeCodeJSONL
            }
            if lineText.contains("\"token_count\""), lineText.contains("\"total_token_usage\"") {
                return .codexJSONL
            }
        }
        return .unknown
    }
}
