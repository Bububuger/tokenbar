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
                let incremental = try JSONLIncrementalReader.read(
                    fileURL: file,
                    sourceName: sourceName,
                    agent: .custom,
                    watermark: watermarks[file.path],
                    now: referenceDate
                )
                let mappedResult = parseMappedJSONL(lines: incremental.lines, fileURL: file)
                events.append(contentsOf: mappedResult.events.map { customEvent($0) })
                warnings.append(contentsOf: incremental.warnings)
                warnings.append(contentsOf: mappedResult.warnings.map {
                    UsageSourceWarning(sourceName: sourceName, sourcePath: $0.sourcePath, lineNumber: $0.lineNumber, message: $0.message)
                })
                nextWatermarks.append(customWatermark(from: incremental.nextWatermark, lastEventId: mappedResult.events.last?.id))
                if mappedResult.events.isEmpty && mappedResult.warnings.isEmpty {
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

    private func parseMappedJSONL(
        lines: [JSONLLineRecord],
        fileURL: URL
    ) -> UsageSourceLoadResult {
        var events: [UsageEvent] = []
        var warnings: [UsageSourceWarning] = []

        for line in lines {
            let lineNumber = line.lineNumber
            let lineText = line.text
            guard let data = lineText.data(using: .utf8) else {
                warnings.append(UsageSourceWarning(sourceName: sourceName, sourcePath: fileURL.path, lineNumber: lineNumber, message: "line is not valid UTF-8"))
                continue
            }

            let object: [String: Any]
            do {
                object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch {
                warnings.append(UsageSourceWarning(sourceName: sourceName, sourcePath: fileURL.path, lineNumber: lineNumber, message: "malformed JSON"))
                continue
            }

            let input = mappedIntValue(from: object, path: record.fieldMapping.inputTokens)
            let output = mappedIntValue(from: object, path: record.fieldMapping.outputTokens)
            let cache = mappedIntValue(from: object, path: record.fieldMapping.cacheTokens)
            guard let input, let output, let cache else {
                warnings.append(UsageSourceWarning(sourceName: sourceName, sourcePath: fileURL.path, lineNumber: lineNumber, message: "usage fields are incomplete for custom mapping"))
                continue
            }

            let inputClamp = TokenBarNumberFormatting.clampNonNegative(input)
            let outputClamp = TokenBarNumberFormatting.clampNonNegative(output)
            let cacheClamp = TokenBarNumberFormatting.clampNonNegative(cache)
            if inputClamp.wasNegative || outputClamp.wasNegative || cacheClamp.wasNegative {
                warnings.append(UsageSourceWarning(sourceName: sourceName, sourcePath: fileURL.path, lineNumber: lineNumber, message: "negative token count clamped to 0"))
            }

            let projectPath = (object["projectPath"] as? String) ?? (object["cwd"] as? String)
            let projectName = URL(fileURLWithPath: projectPath ?? fileURL.deletingPathExtension().path).lastPathComponent
            let sessionId = (object["sessionId"] as? String) ?? (object["session_id"] as? String) ?? fileURL.deletingPathExtension().lastPathComponent
            let timestamp = parseTimestamp(object["timestamp"] as? String) ?? .distantPast
            let modelName = mappedStringValue(from: object, path: record.fieldMapping.model)

            events.append(
                UsageEvent(
                    id: "\(fileURL.path)#mapped#\(lineNumber)",
                    agent: .custom,
                    projectPath: projectPath,
                    projectName: projectName,
                    sessionId: sessionId,
                    timestamp: timestamp,
                    inputTokens: inputClamp.value,
                    outputTokens: outputClamp.value,
                    cacheTokens: cacheClamp.value,
                    reasoningTokens: nil,
                    modelName: modelName,
                    sourcePath: fileURL.path,
                    parser: .custom,
                    confidence: 1.0
                )
            )
        }

        return UsageSourceLoadResult(events: events, prompts: [], warnings: warnings)
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func mappedStringValue(from object: [String: Any], path: String) -> String? {
        mappedValue(from: object, path: path).flatMap { $0 as? String }
    }

    private func mappedIntValue(from object: [String: Any], path: String) -> Int? {
        let value = mappedValue(from: object, path: path)
        switch value {
        case let intValue as Int:
            return intValue
        case let intValue as Int64:
            return Int(intValue)
        case let doubleValue as Double:
            return Int(doubleValue)
        case let num as NSNumber:
            return num.intValue
        case let stringValue as String:
            return Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func mappedValue(from object: [String: Any], path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        var current: Any = object
        for part in parts {
            if let index = Int(part), let array = current as? [Any], array.indices.contains(index) {
                current = array[index]
                continue
            }
            guard let dictionary = current as? [String: Any], let next = dictionary[part] else {
                return nil
            }
            current = next
        }
        return current
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
