import Foundation
import GRDB

public struct HermesUsageEventSource: InspectableUsageEventSource, @unchecked Sendable {
    public let sourceName = "Hermes"
    public let rootPath: String
    public let agent: AgentKind = .hermes
    private let fileManager: FileManager

    public init(rootPath: String = "~/.hermes/state.db", fileManager: FileManager = .default) {
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
        return try HermesUsageParser.parse(
            databaseURL: URL(fileURLWithPath: expandedPath),
            watermark: watermarks[expandedPath]
        )
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        _ = referenceDate
        _ = calendar
        return UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: fileManager.isReadableFile(atPath: expandedPath),
            discoveredFileCount: fileManager.fileExists(atPath: expandedPath) ? 1 : 0
        )
    }

    private var expandedPath: String {
        CodexDataSource.expandHome(in: rootPath)
    }
}

public enum HermesUsageParser {
    public static func parse(databaseURL: URL, watermark: SourceWatermark? = nil) throws -> UsageSourceLoadResult {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        return try queue.read { db in
            let currentFingerprint = try? JSONLIncrementalReader.fingerprint(at: databaseURL.path)
            let effectiveWatermark: SourceWatermark?
            var warnings: [UsageSourceWarning] = []
            if let watermark,
               let currentFingerprint,
               let lastInode = watermark.lastInode,
               currentFingerprint.inode != lastInode {
                effectiveWatermark = nil
                warnings.append(
                    UsageSourceWarning(
                        sourceName: "Hermes",
                        sourcePath: databaseURL.path,
                        lineNumber: nil,
                        message: "forced full reparse: inode changed \(lastInode) -> \(currentFingerprint.inode)"
                    )
                )
            } else {
                effectiveWatermark = watermark
            }

            if !hasColumn("input_tokens", in: "messages", db: db) {
                return try parseSessionAggregateSchema(
                    databaseURL: databaseURL,
                    db: db,
                    watermark: effectiveWatermark,
                    fingerprint: currentFingerprint,
                    warnings: warnings
                )
            }

            let hasSessionModel = hasColumn("model", in: "sessions", db: db)
            let hasMessagesModel = hasColumn("model", in: "messages", db: db)
            let modelSelect = modelSelectClause(hasMessagesModel: hasMessagesModel, hasSessionsModel: hasSessionModel)
            let messageTimestampScale = timestampScale(db: db, table: "messages", column: "started_at")
            var arguments = StatementArguments()
            var filter = ""
            if let effectiveWatermark {
                filter = "AND (m.started_at > ? OR (m.started_at = ? AND CAST(m.id AS TEXT) > ?))"
                let ts = sqliteTimestamp(from: effectiveWatermark.lastMtime, scale: messageTimestampScale)
                arguments += [ts, ts, effectiveWatermark.lastEventId ?? ""]
            }
            let rows = try Row.fetchAll(db, sql: """
            SELECT CAST(m.id AS TEXT) AS id,
                   m.session_id AS session_id,
                   m.started_at AS started_at,
                   m.role AS role,
                   m.content AS content,
                   m.input_tokens AS input_tokens,
                   m.output_tokens AS output_tokens,
                   m.cache_read_tokens AS cache_read_tokens,
                   m.cache_write_tokens AS cache_write_tokens,
                   m.reasoning_tokens AS reasoning_tokens,
                   \(modelSelect) AS model_name,
                   COALESCE(s.source, 'hermes') AS project_name
            FROM messages m
            LEFT JOIN sessions s ON s.id = m.session_id
            WHERE m.started_at IS NOT NULL \(filter)
            ORDER BY m.started_at ASC, m.id ASC
            """, arguments: arguments)

            var events: [UsageEvent] = []
            var prompts: [PromptRecord] = []

            for row in rows {
                let role: String = row["role"]
                let sessionID: String = row["session_id"] ?? "unknown"
                let messageID: String = row["id"] ?? "\(databaseURL.path)#\(events.count + prompts.count)"
                let projectName: String = row["project_name"] ?? "hermes"
                let timestamp = hermesDate(from: row["started_at"])
                let content: String = row["content"] ?? ""

                if role == "user" {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !PromptExtraction.isSystemReminder(trimmed), !looksLikeToolResult(trimmed) {
                        let contentHash = PromptExtraction.hash(trimmed)
                        prompts.append(
                            PromptRecord(
                                id: "\(databaseURL.path)#prompt#\(messageID)#\(contentHash)",
                                eventId: nil,
                                agent: .hermes,
                                projectName: projectName,
                                sessionId: sessionID,
                                timestamp: timestamp,
                                content: trimmed,
                                contentHash: contentHash,
                                sourcePath: databaseURL.path
                            )
                        )
                    }
                }

                let inputTokens: Int = row["input_tokens"] ?? 0
                let outputTokens: Int = row["output_tokens"] ?? 0
                let cacheReadTokens: Int = row["cache_read_tokens"] ?? 0
                let cacheWriteTokens: Int = row["cache_write_tokens"] ?? 0
                let reasoningTokens: Int? = row["reasoning_tokens"]
                let modelName: String? = row["model_name"]
                guard inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + (reasoningTokens ?? 0) > 0 else {
                    continue
                }

                events.append(
                    UsageEvent(
                        id: "\(databaseURL.path)#hermes#\(messageID)",
                        agent: .hermes,
                        projectPath: nil,
                        projectName: projectName,
                        sessionId: sessionID,
                        timestamp: timestamp,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheTokens: cacheReadTokens + cacheWriteTokens,
                        reasoningTokens: reasoningTokens,
                        modelName: modelName,
                        sourcePath: databaseURL.path,
                        parser: .hermes,
                        confidence: 1.0
                    )
                )
            }

            let maxEvent = events.max { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id < rhs.id
                }
                return lhs.timestamp < rhs.timestamp
            }
            let nextWatermark = SourceWatermark(
                sourcePath: databaseURL.path,
                agent: .hermes,
                lastMtime: maxEvent?.timestamp ?? watermark?.lastMtime ?? .distantPast,
                lastByteOffset: 0,
                lastEventId: maxEvent?.id.replacingOccurrences(of: "\(databaseURL.path)#hermes#", with: "") ?? watermark?.lastEventId,
                lastInode: currentFingerprint?.inode ?? watermark?.lastInode,
                updatedAt: Date()
            )

            return UsageSourceLoadResult(events: events, prompts: prompts, nextWatermarks: [nextWatermark], warnings: warnings)
        }
    }

    private static func parseSessionAggregateSchema(
        databaseURL: URL,
        db: Database,
        watermark: SourceWatermark?,
        fingerprint: FileFingerprint?,
        warnings: [UsageSourceWarning]
    ) throws -> UsageSourceLoadResult {
        var arguments = StatementArguments()
        var filter = ""
        let sessionTimestampScale = timestampScale(db: db, table: "sessions", column: "started_at")
        if let watermark {
            filter = "WHERE (started_at > ? OR (started_at = ? AND id > ?))"
            let ts = sqliteTimestamp(from: watermark.lastMtime, scale: sessionTimestampScale)
            arguments += [ts, ts, watermark.lastEventId ?? ""]
        }
        let hasSessionModel = hasColumn("model", in: "sessions", db: db)
        let modelSelect = hasSessionModel ? "model" : "NULL"
        let sessionRows = try Row.fetchAll(db, sql: """
        SELECT id,
               source,
               \(modelSelect) AS model_name,
               started_at,
               input_tokens,
               output_tokens,
               cache_read_tokens,
               cache_write_tokens,
               reasoning_tokens
        FROM sessions
        \(filter)
        ORDER BY started_at ASC, id ASC
        """, arguments: arguments)
        var events: [UsageEvent] = []
        for row in sessionRows {
            let sessionID: String = row["id"]
            let sessionSource: String = row["source"] ?? "hermes"
            // `sessions.source` is "cli" for every session on real Hermes
            // installs (37/37 on one verified machine), so it collapses every
            // session into one bucket on the project axis. Recover a real
            // project name by scanning messages for the first `"cwd": "..."`
            // pattern (tool calls emit this) and basenaming it.
            let projectName = derivedProjectName(forSession: sessionID, db: db) ?? sessionSource
            let inputTokens: Int = row["input_tokens"] ?? 0
            let outputTokens: Int = row["output_tokens"] ?? 0
            let cacheReadTokens: Int = row["cache_read_tokens"] ?? 0
            let cacheWriteTokens: Int = row["cache_write_tokens"] ?? 0
            let reasoningTokens: Int? = row["reasoning_tokens"]
            let modelName: String? = row["model_name"]
            guard inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + (reasoningTokens ?? 0) > 0 else {
                continue
            }
            events.append(
                UsageEvent(
                    id: "\(databaseURL.path)#hermes-session#\(sessionID)",
                    agent: .hermes,
                    projectPath: nil,
                    projectName: projectName,
                    sessionId: sessionID,
                    timestamp: hermesDate(from: row["started_at"]),
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheTokens: cacheReadTokens + cacheWriteTokens,
                    reasoningTokens: reasoningTokens,
                    modelName: modelName,
                    sourcePath: databaseURL.path,
                    parser: .hermes,
                    confidence: 1.0
                )
            )
        }

        var promptArguments = StatementArguments()
        var promptFilter = "WHERE m.role = 'user'"
        let promptTimestampScale = timestampScale(db: db, table: "messages", column: "timestamp")
        if let watermark {
            promptFilter += " AND (m.timestamp > ? OR (m.timestamp = ? AND CAST(m.id AS TEXT) > ?))"
            let ts = sqliteTimestamp(from: watermark.lastMtime, scale: promptTimestampScale)
            promptArguments += [ts, ts, watermark.lastEventId ?? ""]
        }
        let promptRows = try Row.fetchAll(db, sql: """
        SELECT CAST(m.id AS TEXT) AS id,
               m.session_id AS session_id,
               m.timestamp AS timestamp,
               m.role AS role,
               m.content AS content,
               COALESCE(s.source, 'hermes') AS project_name
        FROM messages m
        LEFT JOIN sessions s ON s.id = m.session_id
        \(promptFilter)
        ORDER BY m.timestamp ASC, m.id ASC
        """, arguments: promptArguments)
        let prompts = promptRows.compactMap { row -> PromptRecord? in
            let content: String = row["content"] ?? ""
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !PromptExtraction.isSystemReminder(trimmed), !looksLikeToolResult(trimmed) else {
                return nil
            }
            let contentHash = PromptExtraction.hash(trimmed)
            let messageID: String = row["id"] ?? "\(databaseURL.path)#prompt#\(contentHash)"
            return PromptRecord(
                id: "\(databaseURL.path)#prompt#\(messageID)#\(contentHash)",
                eventId: nil,
                agent: .hermes,
                projectName: row["project_name"] ?? "hermes",
                sessionId: row["session_id"] ?? "unknown",
                timestamp: hermesDate(from: row["timestamp"]),
                content: trimmed,
                contentHash: contentHash,
                sourcePath: databaseURL.path
            )
        }

        let maxEvent = events.max { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.sessionId < rhs.sessionId
            }
            return lhs.timestamp < rhs.timestamp
        }
        let nextWatermark = SourceWatermark(
            sourcePath: databaseURL.path,
            agent: .hermes,
            lastMtime: maxEvent?.timestamp ?? watermark?.lastMtime ?? .distantPast,
            lastByteOffset: 0,
            lastEventId: maxEvent?.sessionId ?? watermark?.lastEventId,
            lastInode: fingerprint?.inode ?? watermark?.lastInode,
            updatedAt: Date()
        )

        return UsageSourceLoadResult(events: events, prompts: prompts, nextWatermarks: [nextWatermark], warnings: warnings)
    }

    private static func hasColumn(_ column: String, in table: String, db: Database) -> Bool {
        guard let rows = try? Row.fetchAll(db, sql: "PRAGMA table_info(\(table))") else {
            return false
        }
        return rows.contains { row in
            let name: String = row["name"]
            return name == column
        }
    }

    private static func modelSelectClause(hasMessagesModel: Bool, hasSessionsModel: Bool) -> String {
        if hasMessagesModel {
            return hasSessionsModel
                ? "COALESCE(m.model, s.model)"
                : "m.model"
        }
        return hasSessionsModel ? "s.model" : "NULL"
    }

    private static func looksLikeToolResult(_ content: String) -> Bool {
        let lowered = content.lowercased()
        return lowered.contains("\"tool_result\"")
            || lowered.contains("<tool_result")
            || lowered.contains("tool result")
    }

    private static func hermesDate(from value: DatabaseValueConvertible?) -> Date {
        if let intValue = value as? Int64 {
            return dateFromEpoch(intValue)
        }
        if let intValue = value as? Int {
            return dateFromEpoch(Int64(intValue))
        }
        if let doubleValue = value as? Double {
            return dateFromEpoch(Int64(doubleValue))
        }
        if let stringValue = value as? String {
            if let intValue = Int64(stringValue) {
                return dateFromEpoch(intValue)
            }
            return CodexUsageParser.parseTimestamp(stringValue)
                ?? ClaudeUsageParser.parseTimestamp(stringValue)
                ?? .distantPast
        }
        return .distantPast
    }

    private static func dateFromEpoch(_ value: Int64) -> Date {
        if value > 10_000_000_000 {
            return .tokenBarDate(millisecondsSince1970: value)
        }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    private enum TimestampScale {
        case seconds
        case milliseconds
    }

    private static func timestampScale(db: Database, table: String, column: String) -> TimestampScale {
        guard
            let row = try? Row.fetchOne(
                db,
                sql: "SELECT \(column) AS value FROM \(table) WHERE \(column) IS NOT NULL ORDER BY \(column) DESC LIMIT 1"
            )
        else {
            return .seconds
        }

        if let doubleValue = row["value"] as Double? {
            return doubleValue > 10_000_000_000 ? .milliseconds : .seconds
        }
        if let intValue = row["value"] as Int64? {
            return intValue > 10_000_000_000 ? .milliseconds : .seconds
        }
        if let stringValue = row["value"] as String?, let doubleValue = Double(stringValue) {
            return doubleValue > 10_000_000_000 ? .milliseconds : .seconds
        }
        return .seconds
    }

    /// Hermes' `sessions.source` is always "cli" on real installs — every
    /// session ends up under one bucket on the project axis. Recover a
    /// meaningful project by finding the first tool-call message that
    /// embeds a `"cwd"` JSON field and returning its basename. Returns nil
    /// (callers fall back to `source`) when no cwd is present.
    static func derivedProjectName(forSession sessionID: String, db: Database) -> String? {
        let pattern = "%\"cwd\":%"
        guard let row = try? Row.fetchOne(
            db,
            sql: "SELECT content FROM messages WHERE session_id = ? AND content LIKE ? LIMIT 1",
            arguments: [sessionID, pattern]
        ) else {
            return nil
        }
        let content: String = row["content"] ?? ""
        guard let cwd = extractCWD(from: content) else { return nil }
        let basename = (cwd as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    /// Pulls the first `"cwd": "..."` value out of a JSON-ish blob. Handles
    /// both standard JSON (`"cwd": "/path"`) and embedded variants.
    static func extractCWD(from content: String) -> String? {
        guard let range = content.range(of: "\"cwd\"") else { return nil }
        let after = content[range.upperBound...]
        // Skip `:` and whitespace, then read the string value.
        guard let colon = after.firstIndex(of: ":") else { return nil }
        let valueStart = after[after.index(after: colon)...].drop { $0 == " " }
        guard valueStart.first == "\"" else { return nil }
        let body = valueStart.dropFirst()
        guard let closeQuote = body.firstIndex(of: "\"") else { return nil }
        return String(body[..<closeQuote])
    }

    private static func sqliteTimestamp(from date: Date, scale: TimestampScale) -> Double {
        switch scale {
        case .seconds:
            return date.timeIntervalSince1970
        case .milliseconds:
            return date.timeIntervalSince1970 * 1_000
        }
    }
}
