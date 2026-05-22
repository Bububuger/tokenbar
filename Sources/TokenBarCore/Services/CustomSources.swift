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

        switch record.engine {
        case .claudeCode:
            for file in files {
                if shouldUseMappedJSONL(for: file) {
                    let incremental = try JSONLIncrementalReader.read(
                        fileURL: file,
                        sourceName: sourceName,
                        agent: .custom,
                        watermark: watermarks[file.path],
                        now: referenceDate
                    )
                    let result = parseMappedJSONL(lines: incremental.lines, fileURL: file)
                    events.append(contentsOf: result.events.map { customMappedEvent($0) })
                    nextWatermarks.append(customWatermark(
                        from: incremental.nextWatermark,
                        lastEventId: result.events.last?.id ?? watermarks[file.path]?.lastEventId,
                        agent: .custom
                    ))
                    warnings.append(contentsOf: incremental.warnings)
                    warnings.append(contentsOf: result.warnings)
                    continue
                }

                let incremental = try JSONLIncrementalReader.read(
                    fileURL: file,
                    sourceName: sourceName,
                    agent: record.engine.agentKind,
                    watermark: watermarks[file.path],
                    now: referenceDate
                )
                let result = ClaudeUsageParser.parse(lines: incremental.lines, fileURL: file, fallbackProjectSlug: claudeFallbackProjectSlug(for: file))
                events.append(contentsOf: result.events.map { customEvent($0) })
                prompts.append(contentsOf: result.prompts.map { customPrompt($0) })
                nextWatermarks.append(customWatermark(from: incremental.nextWatermark, lastEventId: result.events.last?.id ?? watermarks[file.path]?.lastEventId))
                warnings.append(contentsOf: incremental.warnings)
                warnings.append(contentsOf: result.warnings.map {
                    UsageSourceWarning(sourceName: sourceName, sourcePath: $0.sourcePath, lineNumber: $0.lineNumber, message: $0.message)
                })
            }
        case .codex:
            for file in files {
                if shouldUseMappedJSONL(for: file) {
                    let incremental = try JSONLIncrementalReader.read(
                        fileURL: file,
                        sourceName: sourceName,
                        agent: .custom,
                        watermark: watermarks[file.path],
                        now: referenceDate
                    )
                    let result = parseMappedJSONL(lines: incremental.lines, fileURL: file)
                    events.append(contentsOf: result.events.map { customMappedEvent($0) })
                    nextWatermarks.append(customWatermark(
                        from: incremental.nextWatermark,
                        lastEventId: result.events.last?.id ?? watermarks[file.path]?.lastEventId,
                        agent: .custom
                    ))
                    warnings.append(contentsOf: incremental.warnings)
                    warnings.append(contentsOf: result.warnings)
                    continue
                }

                let incremental = try JSONLIncrementalReader.read(
                    fileURL: file,
                    sourceName: sourceName,
                    agent: record.engine.agentKind,
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
            }
        case .hermes:
            for file in files {
                let result = try HermesUsageParser.parse(databaseURL: file, watermark: watermarks[file.path])
                events.append(contentsOf: result.events.map { customEvent($0) })
                prompts.append(contentsOf: result.prompts.map { customPrompt($0) })
                nextWatermarks.append(contentsOf: result.nextWatermarks.map {
                    customWatermark(from: $0, lastEventId: $0.lastEventId)
                })
                warnings.append(contentsOf: result.warnings.map {
                    UsageSourceWarning(sourceName: sourceName, sourcePath: $0.sourcePath, lineNumber: $0.lineNumber, message: $0.message)
                })
            }
        case .gemini:
            let projectIndex = GeminiDataSource.loadProjectIndex(
                rootDirectory: record.directory,
                fileManager: fileManager
            )
            for file in files {
                let sourcePath = file.path
                let priorWatermark = watermarks[sourcePath]

                let fingerprint: FileFingerprint
                do {
                    fingerprint = try JSONLIncrementalReader.fingerprint(at: sourcePath)
                } catch {
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: sourceName,
                            sourcePath: sourcePath,
                            lineNumber: nil,
                            message: "failed to fingerprint source file: \(error.localizedDescription)"
                        )
                    )
                    continue
                }

                if shouldSkipWholeFileJSON(fingerprint: fingerprint, watermark: priorWatermark) {
                    nextWatermarks.append(
                        customWatermark(
                            from: SourceWatermark(
                                sourcePath: sourcePath,
                                agent: record.engine.agentKind,
                                lastMtime: fingerprint.mtime,
                                lastByteOffset: 0,
                                lastEventId: stripCustomWatermarkPrefix(priorWatermark?.lastEventId),
                                lastInode: fingerprint.inode,
                                updatedAt: referenceDate
                            ),
                            lastEventId: stripCustomWatermarkPrefix(priorWatermark?.lastEventId)
                        )
                    )
                    continue
                }

                let data: Data
                do {
                    data = try Data(contentsOf: file)
                } catch {
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: sourceName,
                            sourcePath: sourcePath,
                            lineNumber: nil,
                            message: "failed to read source file: \(error.localizedDescription)"
                        )
                    )
                    continue
                }

                let parseResult = GeminiUsageParser.parse(
                    data: data,
                    fileURL: file
                ) { slug in
                    GeminiDataSource.resolveProject(
                        forSlug: slug,
                        rootDirectory: record.directory,
                        projectIndex: projectIndex,
                        fileManager: fileManager
                    )
                }
                warnings.append(contentsOf: parseResult.warnings.map {
                    UsageSourceWarning(
                        sourceName: sourceName,
                        sourcePath: $0.sourcePath,
                        lineNumber: $0.lineNumber,
                        message: $0.message
                    )
                })

                let previousLastEventID = stripCustomWatermarkPrefix(priorWatermark?.lastEventId)
                let newEvents = filterNewGeminiEvents(
                    parseResult.events,
                    previousLastEventID: previousLastEventID
                )
                events.append(contentsOf: newEvents.map { customEvent($0) })

                let watermarkLastEventID = newEvents.last
                    .flatMap { messageID(fromEventID: $0.id, sourcePath: sourcePath) }
                    ?? previousLastEventID

                nextWatermarks.append(
                    customWatermark(
                        from: SourceWatermark(
                            sourcePath: sourcePath,
                            agent: record.engine.agentKind,
                            lastMtime: fingerprint.mtime,
                            lastByteOffset: 0,
                            lastEventId: watermarkLastEventID,
                            lastInode: fingerprint.inode,
                            updatedAt: referenceDate
                        ),
                        lastEventId: watermarkLastEventID
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
        if record.engine == .hermes {
            return discoverHermesDatabases()
        }

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
                guard fileMatches(url, globPattern: record.globPattern, fallbackSuffix: suffix) else { return nil }
                return url
            }.sorted { $0.path < $1.path }
        }

        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { fileMatches($0, globPattern: record.globPattern, fallbackSuffix: suffix) }
        .sorted { $0.path < $1.path }
    }

    private func discoverHermesDatabases() -> [URL] {
        let root = URL(fileURLWithPath: expandedDirectory, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return fileManager.isReadableFile(atPath: root.path) ? [root] : []
        }
        let stateDB = root.appendingPathComponent("state.db")
        return fileManager.isReadableFile(atPath: stateDB.path) ? [stateDB] : []
    }

    private func fileMatches(_ url: URL, globPattern: String, fallbackSuffix: String) -> Bool {
        let name = url.lastPathComponent
        if globPattern.contains("rollout-*.jsonl") {
            return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
        }
        if globPattern.contains("*.jsonl") {
            return name.hasSuffix(".jsonl")
        }
        if globPattern.contains("*.json") {
            return name.hasSuffix(".json")
        }
        if globPattern == "state.db" {
            return name == "state.db"
        }
        if globPattern.contains("**") {
            return name.hasSuffix(fallbackSuffix)
        }
        if globPattern.contains("*") {
            return name.hasSuffix(fallbackSuffix)
        }
        return name == globPattern
    }

    private func claudeFallbackProjectSlug(for file: URL) -> String {
        let components = file.pathComponents
        if let subagentsIndex = components.lastIndex(of: "subagents"),
           subagentsIndex >= 2 {
            return components[subagentsIndex - 2]
        }
        let parent = file.deletingLastPathComponent()
        return parent.lastPathComponent == "subagents"
            ? parent.deletingLastPathComponent().lastPathComponent
            : parent.lastPathComponent
    }

    private func customEvent(_ event: UsageEvent) -> UsageEvent {
        UsageEvent(
            id: "custom:\(record.id):\(event.id)",
            agent: record.engine.agentKind,
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
            parser: record.engine.parserKind,
            confidence: event.confidence
        )
    }

    private func customMappedEvent(_ event: UsageEvent) -> UsageEvent {
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
            agent: record.engine.agentKind,
            projectName: prompt.projectName,
            sessionId: prompt.sessionId,
            timestamp: prompt.timestamp,
            content: prompt.content,
            contentHash: prompt.contentHash,
            sourcePath: prompt.sourcePath
        )
    }

    private func customWatermark(
        from watermark: SourceWatermark,
        lastEventId: String?,
        agent: AgentKind? = nil
    ) -> SourceWatermark {
        SourceWatermark(
            sourcePath: watermark.sourcePath,
            agent: agent ?? record.engine.agentKind,
            lastMtime: watermark.lastMtime,
            lastByteOffset: watermark.lastByteOffset,
            lastEventId: lastEventId.map { "custom:\(record.id):\($0)" },
            lastInode: watermark.lastInode,
            updatedAt: watermark.updatedAt
        )
    }

    private func shouldUseMappedJSONL(for file: URL) -> Bool {
        guard record.engine != .hermes else { return false }
        switch record.format {
        case .unknown:
            return true
        case .auto:
            return SourceFormatDetector.detect(fileURL: file) == .unknown
        case .claudeCodeJSONL, .codexJSONL:
            return false
        }
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

    private func shouldSkipWholeFileJSON(fingerprint: FileFingerprint, watermark: SourceWatermark?) -> Bool {
        guard let watermark else { return false }
        guard fingerprint.mtime <= watermark.lastMtime else { return false }
        guard let lastInode = watermark.lastInode else { return true }
        return fingerprint.inode == lastInode
    }

    private func filterNewGeminiEvents(
        _ events: [UsageEvent],
        previousLastEventID: String?
    ) -> [UsageEvent] {
        guard let previousLastEventID else { return events }
        guard let lastSeenIndex = events.lastIndex(where: { event in
            messageID(fromEventID: event.id, sourcePath: event.sourcePath) == previousLastEventID
        }) else {
            return events
        }
        let nextIndex = events.index(after: lastSeenIndex)
        guard nextIndex < events.endIndex else {
            return []
        }
        return Array(events[nextIndex...])
    }

    private func messageID(fromEventID eventID: String, sourcePath: String) -> String? {
        let prefix = sourcePath + "#"
        guard eventID.hasPrefix(prefix) else { return nil }
        return String(eventID.dropFirst(prefix.count))
    }

    private func stripCustomWatermarkPrefix(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "custom" else {
            return value
        }
        return parts.dropFirst(2).joined(separator: ":")
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
