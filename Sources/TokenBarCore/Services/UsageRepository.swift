import Foundation
import GRDB

public struct UsageRepository: Sendable {
    private let database: UsageDatabase

    public struct CollectionSignatures: Sendable, Hashable {
        public let eventCount: Int
        public let promptCount: Int
        public let eventSignature: String
        public let promptSignature: String

        public init(
            eventCount: Int,
            promptCount: Int,
            eventSignature: String,
            promptSignature: String
        ) {
            self.eventCount = eventCount
            self.promptCount = promptCount
            self.eventSignature = eventSignature
            self.promptSignature = promptSignature
        }
    }

    public init(database: UsageDatabase) {
        self.database = database
    }

    public init(databaseURL: URL = UsageDatabase.defaultDatabaseURL()) throws {
        self.database = try UsageDatabase(url: databaseURL)
    }

    @discardableResult
    public func replaceEvents(_ events: [UsageEvent]) throws -> Int {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM usage_events")
            try db.execute(sql: "DELETE FROM prompts")
            var inserted = 0
            for event in events {
                inserted += try insertEvent(event, db: db)
            }
            return inserted
        }
    }

    public func insertCheckpoint(
        trigger: String,
        startedAt: Date,
        endedAt: Date,
        events: [UsageEvent],
        prompts: [PromptRecord],
        nextWatermarks: [SourceWatermark],
        warnings: [UsageSourceWarning],
        error: String?
    ) throws -> CheckpointSummary {
        try database.queue.write { db in
            var eventsAdded = 0
            var promptsAdded = 0

            for event in events {
                eventsAdded += try insertEvent(event, db: db)
            }
            for prompt in prompts {
                promptsAdded += try insertPrompt(prompt, db: db)
            }
            for watermark in nextWatermarks {
                try upsertWatermark(watermark, db: db)
            }

            try db.execute(
                sql: """
                INSERT INTO checkpoints (started_at, ended_at, trigger, events_added, prompts_added, warnings, error)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    startedAt.tokenBarMillisecondsSince1970,
                    endedAt.tokenBarMillisecondsSince1970,
                    trigger,
                    eventsAdded,
                    promptsAdded,
                    warnings.count,
                    error,
                ]
            )

            let id = db.lastInsertedRowID
            for warning in warnings {
                try db.execute(
                    sql: """
                    INSERT INTO source_warnings (checkpoint_id, source_name, source_path, line_number, message, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        warning.sourceName,
                        warning.sourcePath,
                        warning.lineNumber,
                        warning.message,
                        endedAt.tokenBarMillisecondsSince1970,
                    ]
                )
            }
            return CheckpointSummary(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                trigger: trigger,
                eventsAdded: eventsAdded,
                promptsAdded: promptsAdded,
                warnings: warnings.count,
                error: error
            )
        }
    }

    public func deleteWatermark(sourcePath: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM source_watermarks WHERE source_path = ?", arguments: [sourcePath])
        }
    }

    public func deleteAllWatermarks() throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM source_watermarks")
        }
    }

    public func resetIndexForFullReparse() throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM usage_events")
            try db.execute(sql: "DELETE FROM prompts")
            try db.execute(sql: "DELETE FROM source_watermarks")
            try db.execute(sql: "DELETE FROM source_warnings")
            try db.execute(sql: "DELETE FROM checkpoints")
        }
    }

    public func resetAllData() throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM usage_events")
            try db.execute(sql: "DELETE FROM prompts")
            try db.execute(sql: "DELETE FROM source_watermarks")
            try db.execute(sql: "DELETE FROM source_warnings")
            try db.execute(sql: "DELETE FROM checkpoints")
            try db.execute(sql: "DELETE FROM custom_sources")
            try db.execute(sql: "DELETE FROM saved_prompts")
        }
        try database.queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    public func deleteRecords(before cutoff: Date) throws {
        try database.queue.write { db in
            let millis = cutoff.tokenBarMillisecondsSince1970
            try db.execute(sql: "DELETE FROM prompts WHERE timestamp < ?", arguments: [millis])
            try db.execute(sql: "DELETE FROM usage_events WHERE timestamp < ?", arguments: [millis])
        }
    }

    /// CL-P1-021: hard-wipe every prompt row and VACUUM so the database file
    /// shrinks. Token usage rows are untouched.
    public func deleteAllPromptsAndVacuum() throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM prompts")
        }
        try database.queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    public func watermarks() throws -> [String: SourceWatermark] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT source_path, agent, last_mtime, last_byte_offset, last_event_id, last_inode, updated_at
            FROM source_watermarks
            """)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, SourceWatermark)? in
                guard let watermark = watermark(from: row) else {
                    return nil
                }
                return (watermark.sourcePath, watermark)
            })
        }
    }

    public func watermark(for sourcePath: String) throws -> SourceWatermark? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
            SELECT source_path, agent, last_mtime, last_byte_offset, last_event_id, last_inode, updated_at
            FROM source_watermarks
            WHERE source_path = ?
            """, arguments: [sourcePath]) else {
                return nil
            }
            return watermark(from: row)
        }
    }

    public func allEvents() throws -> [UsageEvent] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, agent, project_path, project_name, session_id, timestamp,
                   input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, reasoning_tokens, model_name,
                   source_path, parser, confidence
            FROM usage_events
            ORDER BY timestamp ASC, id ASC
            """)
            return rows.compactMap(event(from:))
        }
    }

    public func allPrompts() throws -> [PromptRecord] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, agent, project_name, session_id, timestamp,
                   content, content_hash, source_path
            FROM prompts
            ORDER BY timestamp ASC, id ASC
            """)
            return rows.compactMap(prompt(from:))
        }
    }

    public func projectEvents(projectName: String, limit: Int? = nil) throws -> [UsageEvent] {
        try database.queue.read { db in
            var rows: [Row]
            if let limit {
                rows = try Row.fetchAll(db, sql: """
                SELECT id, agent, project_path, project_name, session_id, timestamp,
                       input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, reasoning_tokens, model_name,
                       source_path, parser, confidence
                FROM usage_events
                WHERE project_name = ?
                ORDER BY timestamp DESC, id DESC
                LIMIT ?
                """, arguments: [projectName, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                SELECT id, agent, project_path, project_name, session_id, timestamp,
                       input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, reasoning_tokens, model_name,
                       source_path, parser, confidence
                FROM usage_events
                WHERE project_name = ?
                ORDER BY timestamp DESC, id DESC
                """, arguments: [projectName])
            }
            return rows.compactMap(event(from:))
        }
    }

    public func projectPromptHistory(projectName: String, limit: Int? = nil, includeContent: Bool = false) throws -> [PromptRecord] {
        try database.queue.read { db in
            let contentSelection = includeContent ? "content" : "'' AS content"
            var rows: [Row]
            if let limit {
                rows = try Row.fetchAll(db, sql: """
                SELECT id, event_id, agent, project_name, session_id, timestamp,
                       \(contentSelection), content_hash, source_path
                FROM prompts
                WHERE project_name = ?
                ORDER BY timestamp DESC, id DESC
                LIMIT ?
                """, arguments: [projectName, limit])
            } else {
                rows = try Row.fetchAll(db, sql: """
                SELECT id, event_id, agent, project_name, session_id, timestamp,
                       \(contentSelection), content_hash, source_path
                FROM prompts
                WHERE project_name = ?
                ORDER BY timestamp DESC, id DESC
                """, arguments: [projectName])
            }
            return rows.compactMap { row in
                guard
                    let id: String = row["id"],
                    let agent = AgentKind(rawValue: row["agent"] as String),
                    let projectName: String = row["project_name"],
                    let sessionId: String = row["session_id"],
                    let timestampMillis: Int64 = row["timestamp"],
                    let content: String = row["content"],
                    let contentHash: String = row["content_hash"],
                    let sourcePath: String = row["source_path"]
                else {
                    return nil
                }
                return PromptRecord(
                    id: id,
                    eventId: row["event_id"],
                    agent: agent,
                    projectName: projectName,
                    sessionId: sessionId,
                    timestamp: .tokenBarDate(millisecondsSince1970: timestampMillis),
                    content: content,
                    contentHash: contentHash,
                    sourcePath: sourcePath
                )
            }
        }
    }

    public func projectPromptHistoryPage(
        projectName: String,
        limit: Int,
        offset: Int,
        includeContent: Bool = false,
        query: String = "",
        kindFilter: PromptHistoryKindFilter = .all,
        bookmarkedIds: Set<String> = []
    ) throws -> PromptHistoryPage {
        let safeLimit = max(1, limit)
        let safeOffset = max(0, offset)
        return try database.queue.read { db in
            let contentSelection = includeContent ? "content" : "'' AS content"
            let baseFilter = promptBaseFilter(projectName: projectName, query: query)
            let kindClause = promptKindClause(filter: kindFilter, bookmarkedIds: bookmarkedIds)
            let combinedSQL: String
            var combinedArguments = baseFilter.arguments
            if let kindClause {
                combinedSQL = "\(baseFilter.sql) AND \(kindClause.sql)"
                combinedArguments += kindClause.arguments
            } else {
                combinedSQL = baseFilter.sql
            }

            // Bookmarked filter with empty restrict-set yields zero results
            // without touching the DB row set.
            if kindFilter == .bookmarked && bookmarkedIds.isEmpty {
                let kindCounts = try promptKindCounts(
                    db: db,
                    baseFilter: baseFilter,
                    bookmarkedIds: bookmarkedIds
                )
                return PromptHistoryPage(
                    prompts: [],
                    totalCount: 0,
                    kindCounts: kindCounts,
                    limit: safeLimit,
                    offset: safeOffset
                )
            }

            let totalCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM prompts WHERE \(combinedSQL)",
                arguments: combinedArguments
            ) ?? 0
            let kindCounts = try promptKindCounts(
                db: db,
                baseFilter: baseFilter,
                bookmarkedIds: bookmarkedIds
            )

            var pageArguments = combinedArguments
            pageArguments += [safeLimit, safeOffset]
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, event_id, agent, project_name, session_id, timestamp,
                       \(contentSelection), content_hash, source_path
                FROM prompts
                WHERE \(combinedSQL)
                ORDER BY timestamp DESC, id DESC
                LIMIT ? OFFSET ?
                """, arguments: pageArguments)

            return PromptHistoryPage(
                prompts: rows.compactMap(prompt(from:)),
                totalCount: totalCount,
                kindCounts: kindCounts,
                limit: safeLimit,
                offset: safeOffset
            )
        }
    }

    public func projectPromptCountsByDay(
        projectName: String,
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws -> [Date: Int] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT timestamp
                FROM prompts
                WHERE project_name = ?
                  AND timestamp >= ?
                  AND timestamp < ?
                """, arguments: [
                    projectName,
                    start.tokenBarMillisecondsSince1970,
                    end.tokenBarMillisecondsSince1970,
                ])

            var counts: [Date: Int] = [:]
            counts.reserveCapacity(rows.count)
            for row in rows {
                let timestampMillis: Int64 = row["timestamp"]
                let day = calendar.startOfDay(for: .tokenBarDate(millisecondsSince1970: timestampMillis))
                counts[day, default: 0] += 1
            }
            return counts
        }
    }

    private struct PromptSQLFilter {
        let sql: String
        let arguments: StatementArguments
    }

    private func promptBaseFilter(projectName: String, query: String) -> PromptSQLFilter {
        var sql = "project_name = ?"
        var arguments = StatementArguments()
        arguments += [projectName]

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            // Route content matching through the FTS5 index (v10 migration).
            // Previously `LOWER(content) LIKE '%x%'` was a per-keystroke full
            // table scan (~10MB UTF-8 walked on a 5k-prompt project). FTS5
            // with `porter unicode61` brings query latency under 100ms.
            // Session/agent/source still use LIKE — they're short strings not
            // worth indexing — but stay OR-joined with the content match.
            let pattern = "%\(trimmedQuery.lowercased())%"
            let ftsQuery = makeFTSQuery(from: trimmedQuery)
            sql += """
             AND (
                rowid IN (SELECT rowid FROM prompts_fts WHERE prompts_fts MATCH ?)
                OR LOWER(session_id) LIKE ?
                OR LOWER(agent) LIKE ?
                OR LOWER(source_path) LIKE ?
             )
            """
            arguments += [ftsQuery, pattern, pattern, pattern]
        }

        return PromptSQLFilter(sql: sql, arguments: arguments)
    }

    /// Turn a free-text user query into an FTS5 MATCH expression.
    /// - Drops characters that FTS5 treats as syntax to avoid query errors.
    /// - Adds a `*` suffix so partial typing matches as the user is typing.
    private func makeFTSQuery(from rawQuery: String) -> String {
        // FTS5 reserves `" ( ) * : ^ {` and a few more — strip the problematic
        // ones, keep word/space/dash/underscore. Tokens get prefix-matched.
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_/"))
        let sanitized = rawQuery.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
        return sanitized.isEmpty ? "\"\"" : sanitized
    }

    private func promptKindClause(filter: PromptHistoryKindFilter, bookmarkedIds: Set<String>) -> PromptSQLFilter? {
        switch filter {
        case .all:
            return nil
        case .command:
            return PromptSQLFilter(sql: "(\(Self.promptCommandSQL))", arguments: [])
        case .subagent:
            return PromptSQLFilter(
                sql: "NOT (\(Self.promptCommandSQL)) AND (\(Self.promptSubagentSQL))",
                arguments: []
            )
        case .human:
            return PromptSQLFilter(
                sql: "NOT (\(Self.promptCommandSQL)) AND NOT (\(Self.promptSubagentSQL))",
                arguments: []
            )
        case .bookmarked:
            guard !bookmarkedIds.isEmpty else {
                return PromptSQLFilter(sql: "0", arguments: [])
            }
            let placeholders = Array(repeating: "?", count: bookmarkedIds.count).joined(separator: ", ")
            var args = StatementArguments()
            for id in bookmarkedIds {
                args += [id]
            }
            return PromptSQLFilter(sql: "id IN (\(placeholders))", arguments: args)
        }
    }

    private func promptKindCounts(
        db: Database,
        baseFilter: PromptSQLFilter,
        bookmarkedIds: Set<String>
    ) throws -> PromptHistoryKindCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COALESCE(SUM(CASE WHEN \(Self.promptCommandSQL) THEN 1 ELSE 0 END), 0) AS command_count,
                COALESCE(SUM(CASE WHEN NOT (\(Self.promptCommandSQL)) AND (\(Self.promptSubagentSQL)) THEN 1 ELSE 0 END), 0) AS subagent_count,
                COALESCE(SUM(CASE WHEN NOT (\(Self.promptCommandSQL)) AND NOT (\(Self.promptSubagentSQL)) THEN 1 ELSE 0 END), 0) AS human_count
            FROM prompts
            WHERE \(baseFilter.sql)
            """, arguments: baseFilter.arguments)

        let bookmarkedCount: Int
        if bookmarkedIds.isEmpty {
            bookmarkedCount = 0
        } else {
            let placeholders = Array(repeating: "?", count: bookmarkedIds.count).joined(separator: ", ")
            var args = baseFilter.arguments
            for id in bookmarkedIds {
                args += [id]
            }
            bookmarkedCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM prompts WHERE \(baseFilter.sql) AND id IN (\(placeholders))",
                arguments: args
            ) ?? 0
        }

        return PromptHistoryKindCounts(
            humanCount: row?["human_count"] ?? 0,
            subagentCount: row?["subagent_count"] ?? 0,
            commandCount: row?["command_count"] ?? 0,
            bookmarkedCount: bookmarkedCount
        )
    }

    private static var promptCommandSQL: String {
        let firstToken = promptFirstTokenSQL
        return """
        LENGTH(\(firstToken)) > 1
        AND \(firstToken) GLOB '/[A-Za-z0-9_-]*'
        AND SUBSTR(\(firstToken), 2) NOT GLOB '*[^A-Za-z0-9_-]*'
        """
    }

    private static var promptFirstTokenSQL: String {
        let normalized = promptNormalizedContentSQL
        return """
        CASE
            WHEN INSTR(\(normalized), ' ') > 0
            THEN SUBSTR(\(normalized), 1, INSTR(\(normalized), ' ') - 1)
            ELSE \(normalized)
        END
        """
    }

    private static var promptNormalizedContentSQL: String {
        "TRIM(REPLACE(REPLACE(REPLACE(content, CHAR(10), ' '), CHAR(13), ' '), CHAR(9), ' '))"
    }

    private static let promptSubagentSQL = """
    LOWER(source_path) LIKE '%/subagents/%'
    OR LOWER(content) LIKE '%subagent%'
    OR LOWER(content) LIKE '%sub-agent%'
    OR LOWER(content) LIKE '%mainagent%'
    OR LOWER(content) LIKE '%main agent%'
    OR LOWER(content) LIKE '%assigned task%'
    OR LOWER(content) LIKE '%you are not alone in the codebase%'
    """

    public func projectSummary(projectName: String) throws -> UsageSummary {
        try database.queue.read { db in
            try summary(db: db, start: nil, end: nil, projectName: projectName)
        }
    }

    public func eventTimeBounds() throws -> UsageEventTimeBounds {
        try database.queue.read { db in
            let row = try Row.fetchOne(db, sql: """
            SELECT MIN(timestamp) AS min_timestamp,
                   MAX(timestamp) AS max_timestamp,
                   COUNT(*) AS event_count
            FROM usage_events
            """)
            let minTimestamp: Int64? = row?["min_timestamp"]
            let maxTimestamp: Int64? = row?["max_timestamp"]
            return UsageEventTimeBounds(
                earliest: minTimestamp.map(Date.tokenBarDate(millisecondsSince1970:)),
                latest: maxTimestamp.map(Date.tokenBarDate(millisecondsSince1970:)),
                eventCount: row?["event_count"] ?? 0
            )
        }
    }

    public func projectBreakdowns(
        start: Date,
        end: Date,
        topCount: Int? = nil
    ) throws -> [UsageBreakdown] {
        try database.queue.read { db in
            try projectBreakdowns(db: db, start: start, end: end, topCount: topCount)
        }
    }

    public func rangeAggregate(
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws -> UsageRangeAggregate {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT project_name,
                   agent,
                   COALESCE(model_name, '') AS model_name,
                   SUM(input_tokens) AS input_tokens,
                   SUM(output_tokens) AS output_tokens,
                   SUM(cache_read_tokens) AS cache_read_tokens,
                   SUM(cache_creation_tokens) AS cache_creation_tokens
            FROM usage_events
            WHERE timestamp >= ? AND timestamp < ?
            GROUP BY project_name, agent, COALESCE(model_name, '')
            """, arguments: [
                start.tokenBarMillisecondsSince1970,
                end.tokenBarMillisecondsSince1970,
            ])

            let aggregateRows = rows.compactMap { row -> UsageRangeAggregateRow? in
                guard let agent = AgentKind(rawValue: row["agent"] as String) else {
                    return nil
                }
                let rawModelName = row["model_name"] as String
                return UsageRangeAggregateRow(
                    projectName: row["project_name"],
                    agent: agent,
                    modelName: rawModelName.isEmpty ? nil : rawModelName,
                    summary: UsageSummary(
                        inputTokens: row["input_tokens"],
                        outputTokens: row["output_tokens"],
                        cacheReadTokens: row["cache_read_tokens"],
                        cacheCreationTokens: row["cache_creation_tokens"]
                    )
                )
            }

            return UsageRangeAggregate(
                start: start,
                end: end,
                days: try usageDays(db: db, start: start, end: end, calendar: calendar, projectName: nil),
                rows: aggregateRows
            )
        }
    }

    public func collectionSignatures() throws -> CollectionSignatures {
        try database.queue.read { db in
            let eventSignature = try collectionSignatureForEvents(db: db)
            let promptSignature = try collectionSignatureForPrompts(db: db)
            return CollectionSignatures(
                eventCount: eventSignature.count,
                promptCount: promptSignature.count,
                eventSignature: eventSignature.signature,
                promptSignature: promptSignature.signature
            )
        }
    }

    public func latestCheckpoint() throws -> CheckpointSummary? {
        try database.queue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
            SELECT id, started_at, ended_at, trigger, events_added, prompts_added, warnings, error
            FROM checkpoints
            ORDER BY id DESC
            LIMIT 1
            """) else {
                return nil
            }
            return checkpoint(from: row)
        }
    }

    public func recentCheckpoints(limit: Int = 20) throws -> [CheckpointSummary] {
        let safeLimit = max(1, limit)
        return try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, started_at, ended_at, trigger, events_added, prompts_added, warnings, error
            FROM checkpoints
            ORDER BY id DESC
            LIMIT ?
            """, arguments: [safeLimit])
            return rows.map(checkpoint(from:))
        }
    }

    public func latestWarnings(limit: Int = 50) throws -> [UsageSourceWarning] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT source_name, source_path, line_number, message
            FROM source_warnings
            WHERE checkpoint_id = (
                SELECT id FROM checkpoints ORDER BY id DESC LIMIT 1
            )
            ORDER BY id DESC
            LIMIT ?
            """, arguments: [limit])

            return rows.map { row in
                UsageSourceWarning(
                    sourceName: row["source_name"],
                    sourcePath: row["source_path"],
                    lineNumber: row["line_number"],
                    message: row["message"]
                )
            }
        }
    }

    public func makeSnapshot(
        referenceDate: Date,
        calendar: Calendar,
        days: Int = 30,
        topCount: Int = 5
    ) throws -> UsageSnapshot {
        try database.queue.read { db in
            let todayStart = calendar.startOfDay(for: referenceDate)
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
            let last30Start = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
            let last30End = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
            let today = try summary(db: db, start: todayStart, end: tomorrowStart, projectName: nil)

            var daysOut: [UsageDay] = []
            for offset in stride(from: days - 1, through: 0, by: -1) {
                let start = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                let daySummary = try summary(db: db, start: start, end: end, projectName: nil)
                daysOut.append(UsageDay(date: start, summary: daySummary, intensity: 0))
            }

            let maxTotal = Double(daysOut.map(\.summary.totalTokens).max() ?? 0)
            let normalizedDays = daysOut.map { day in
                UsageDay(
                    date: day.date,
                    summary: day.summary,
                    intensity: maxTotal > 0 ? Double(day.summary.totalTokens) / maxTotal : 0
                )
            }
            let activeDays = normalizedDays.filter { $0.summary.totalTokens > 0 }.count
            let peakDay = normalizedDays
                .filter { $0.summary.totalTokens > 0 }
                .max { lhs, rhs in lhs.summary.totalTokens < rhs.summary.totalTokens }
                .map(\.date)
            let todayCost = try costProjection(db: db, start: todayStart, end: tomorrowStart, projectName: nil)
            let last30Cost = try costProjection(db: db, start: last30Start, end: last30End, projectName: nil)
            let focusToday = today.focus
            let focusLast30 = normalizedDays.reduce(
                UsageSummary(
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0
                )
            ) { total, day in
                UsageSummary(
                    inputTokens: total.inputTokens + day.summary.inputTokens,
                    outputTokens: total.outputTokens + day.summary.outputTokens,
                    cacheReadTokens: total.cacheReadTokens + day.summary.cacheReadTokens,
                    cacheCreationTokens: total.cacheCreationTokens + day.summary.cacheCreationTokens
                )
            }.focus

            return UsageSnapshot(
                generatedAt: referenceDate,
                today: today,
                last30Days: normalizedDays,
                topAgentsToday: try rankedBreakdowns(db: db, groupColumn: "agent", start: todayStart, end: tomorrowStart, projectName: nil, topCount: topCount, mapName: agentDisplayName),
                topProjectsToday: try rankedBreakdowns(db: db, groupColumn: "project_name", start: todayStart, end: tomorrowStart, projectName: nil, topCount: topCount, mapName: { $0 }),
                topAgents: try rankedBreakdowns(db: db, groupColumn: "agent", start: last30Start, end: last30End, projectName: nil, topCount: topCount, mapName: agentDisplayName),
                topProjects: try rankedBreakdowns(db: db, groupColumn: "project_name", start: last30Start, end: last30End, projectName: nil, topCount: topCount, mapName: { $0 }),
                focusToday: focusToday,
                focusLast30: focusLast30,
                activeDays: activeDays,
                peakDay: peakDay,
                estimatedCostToday: todayCost,
                estimatedCostLast30: last30Cost,
                warningCount: try latestWarningCount(db: db)
            )
        }
    }

    public func makeProjectDetail(
        projectName: String,
        referenceDate: Date,
        calendar: Calendar,
        days: Int = 30,
        topAgentCount: Int = 5,
        sessionCount: Int = 5
    ) throws -> ProjectDetailSnapshot? {
        try database.queue.read { db in
            let todayStart = calendar.startOfDay(for: referenceDate)
            let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
            let windowEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
            let total = try summary(db: db, start: windowStart, end: windowEnd, projectName: projectName)
            guard total.totalTokens > 0 else {
                return nil
            }

            var daysOut: [UsageDay] = []
            for offset in stride(from: days - 1, through: 0, by: -1) {
                let start = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                let daySummary = try summary(db: db, start: start, end: end, projectName: projectName)
                daysOut.append(UsageDay(date: start, summary: daySummary, intensity: 0))
            }
            let maxTotal = Double(daysOut.map(\.summary.totalTokens).max() ?? 0)
            let normalizedDays = daysOut.map { day in
                UsageDay(date: day.date, summary: day.summary, intensity: maxTotal > 0 ? Double(day.summary.totalTokens) / maxTotal : 0)
            }
            let activeDays = normalizedDays.filter { $0.summary.totalTokens > 0 }.count
            let peakDay = normalizedDays
                .filter { $0.summary.totalTokens > 0 }
                .max { lhs, rhs in lhs.summary.totalTokens < rhs.summary.totalTokens }
                .map(\.date)
            let estimatedCost = try costProjection(db: db, start: windowStart, end: windowEnd, projectName: projectName)
            let focus = total.focus

            let agentRows = try Row.fetchAll(db, sql: """
            SELECT agent,
                   SUM(input_tokens) AS input_tokens,
                   SUM(output_tokens) AS output_tokens,
                   SUM(cache_read_tokens) AS cache_read_tokens,
                   SUM(cache_creation_tokens) AS cache_creation_tokens
            FROM usage_events
            WHERE project_name = ? AND timestamp >= ? AND timestamp < ?
            GROUP BY agent
            ORDER BY (SUM(input_tokens) + SUM(output_tokens) + SUM(cache_read_tokens) + SUM(cache_creation_tokens)) DESC, agent ASC
            LIMIT ?
            """, arguments: [projectName, windowStart.tokenBarMillisecondsSince1970, windowEnd.tokenBarMillisecondsSince1970, topAgentCount])
            let agentShare = agentRows.map { row in
                let name = agentDisplayName(row["agent"] as String)
                let totalTokens = ((row["input_tokens"] as Int?) ?? 0) + ((row["output_tokens"] as Int?) ?? 0) + ((row["cache_read_tokens"] as Int?) ?? 0) + ((row["cache_creation_tokens"] as Int?) ?? 0)
                return AgentShareSlice(
                    name: name,
                    totalTokens: totalTokens,
                    percentage: total.totalTokens > 0 ? Double(totalTokens) / Double(total.totalTokens) : 0
                )
            }

            let sessionRows = try Row.fetchAll(db, sql: """
            SELECT session_id,
                   agent,
                   MAX(timestamp) AS timestamp,
                   SUM(input_tokens) AS input_tokens,
                   SUM(output_tokens) AS output_tokens,
                   SUM(cache_read_tokens) AS cache_read_tokens,
                   SUM(cache_creation_tokens) AS cache_creation_tokens
            FROM usage_events
            WHERE project_name = ? AND timestamp >= ? AND timestamp < ?
            GROUP BY session_id, agent
            ORDER BY MAX(timestamp) DESC
            LIMIT ?
            """, arguments: [projectName, windowStart.tokenBarMillisecondsSince1970, windowEnd.tokenBarMillisecondsSince1970, sessionCount])
            let sessions = sessionRows.map { row in
                ProjectSessionSummary(
                    sessionId: row["session_id"],
                    agentName: agentDisplayName(row["agent"] as String),
                    timestamp: .tokenBarDate(millisecondsSince1970: row["timestamp"]),
                    summary: UsageSummary(
                        inputTokens: row["input_tokens"],
                        outputTokens: row["output_tokens"],
                        cacheReadTokens: row["cache_read_tokens"],
                        cacheCreationTokens: row["cache_creation_tokens"]
                    )
                )
            }

            return ProjectDetailSnapshot(
                projectName: projectName,
                summary: total,
                last30Days: normalizedDays,
                agentShare: agentShare,
                recentSessions: sessions,
                focus: focus,
                activeDays: activeDays,
                peakDay: peakDay,
                estimatedCost: estimatedCost,
                warningCount: try latestWarningCount(db: db)
            )
        }
    }

    public func listCustomSources() throws -> [CustomSourceRecord] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, name, plugin, directory, glob_pattern, format, display_agent, enabled, field_mapping, created_at,
                   plugin_id, plugin_version, input_includes_cached, timestamp_format, sqlite_query, executable_config
            FROM custom_sources
            ORDER BY created_at ASC, name ASC
            """)
            return rows.map { row in
                customSourceRecord(from: row)
            }
        }
    }

    public func upsertCustomSource(_ source: CustomSourceRecord) throws {
        try database.queue.write { db in
            let matchingRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, directory, glob_pattern
                FROM custom_sources
                ORDER BY created_at ASC, name ASC
                """
            )
            .filter { row in
                let directory: String = row["directory"]
                let globPattern: String = row["glob_pattern"]
                return CustomSourceRecord.sourcePathKey(directory: directory, globPattern: globPattern) == source.sourcePathKey
            }
            let targetID = (matchingRows.first?["id"] as String?) ?? source.id
            try db.execute(
                sql: """
                INSERT INTO custom_sources (id, name, plugin, directory, glob_pattern, format, display_agent, enabled, field_mapping, created_at,
                    plugin_id, plugin_version, input_includes_cached, timestamp_format, sqlite_query, executable_config)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    plugin = excluded.plugin,
                    directory = excluded.directory,
                    glob_pattern = excluded.glob_pattern,
                    format = excluded.format,
                    display_agent = excluded.display_agent,
                    enabled = excluded.enabled,
                    field_mapping = excluded.field_mapping,
                    plugin_id = excluded.plugin_id,
                    plugin_version = excluded.plugin_version,
                    input_includes_cached = excluded.input_includes_cached,
                    timestamp_format = excluded.timestamp_format,
                    sqlite_query = excluded.sqlite_query,
                    executable_config = excluded.executable_config
                """,
                arguments: [
                    targetID,
                    source.name,
                    source.plugin.rawValue,
                    source.directory,
                    source.globPattern,
                    source.format.rawValue,
                    source.displayAgent,
                    source.enabled ? 1 : 0,
                    encodeFieldMapping(source.fieldMapping),
                    source.createdAt.tokenBarMillisecondsSince1970,
                    source.pluginId,
                    source.pluginVersion,
                    source.inputIncludesCached ? 1 : 0,
                    source.timestampFormat.rawValue,
                    encodeJSON(source.sqliteQuery),
                    encodeJSON(source.executableConfig),
                ]
            )
            for row in matchingRows.dropFirst() {
                let duplicateID: String = row["id"]
                try db.execute(sql: "DELETE FROM custom_sources WHERE id = ?", arguments: [duplicateID])
            }
            if targetID != source.id {
                try db.execute(sql: "DELETE FROM custom_sources WHERE id = ?", arguments: [source.id])
            }
        }
    }

    public func deleteCustomSource(id: String) throws {
        try database.queue.write { db in
            try deleteCustomSourceData(id: id, db: db)
            try db.execute(sql: "DELETE FROM custom_sources WHERE id = ?", arguments: [id])
        }
    }

    public func deleteCustomSourceData(id: String) throws {
        try database.queue.write { db in
            try deleteCustomSourceData(id: id, db: db)
        }
    }

    public func allSavedPrompts() throws -> [SavedPrompt] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT id, slug, title, body, source_prompt_id, created_at, updated_at,
                   argument_hint, allowed_tools
            FROM saved_prompts
            ORDER BY updated_at DESC
            """)
            return rows.map(savedPrompt(from:))
        }
    }

    public func savedPrompt(slug: String) throws -> SavedPrompt? {
        try database.queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, slug, title, body, source_prompt_id, created_at, updated_at,
                       argument_hint, allowed_tools
                FROM saved_prompts WHERE slug = ?
                """,
                arguments: [slug]
            )
            return row.map(savedPrompt(from:))
        }
    }

    public func upsertSavedPrompt(_ prompt: SavedPrompt) throws {
        try database.queue.write { db in
            // Empty allowedTools serializes to NULL so a SELECT against a v10
            // row (pre-migration backup) and a v11 row with no tools look the
            // same in code.
            let toolsString: String? = prompt.allowedTools.isEmpty
                ? nil
                : prompt.allowedTools.joined(separator: ",")
            try db.execute(
                sql: """
                INSERT INTO saved_prompts (id, slug, title, body, source_prompt_id, created_at, updated_at, argument_hint, allowed_tools)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    slug = excluded.slug,
                    title = excluded.title,
                    body = excluded.body,
                    source_prompt_id = excluded.source_prompt_id,
                    updated_at = excluded.updated_at,
                    argument_hint = excluded.argument_hint,
                    allowed_tools = excluded.allowed_tools
                """,
                arguments: [
                    prompt.id,
                    prompt.slug,
                    prompt.title,
                    prompt.body,
                    prompt.sourcePromptId,
                    prompt.createdAt.tokenBarMillisecondsSince1970,
                    prompt.updatedAt.tokenBarMillisecondsSince1970,
                    prompt.argumentHint,
                    toolsString,
                ]
            )
        }
    }

    public func deleteSavedPrompt(id: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM saved_prompts WHERE id = ?", arguments: [id])
        }
    }

    private func savedPrompt(from row: Row) -> SavedPrompt {
        let toolsRaw: String? = row["allowed_tools"]
        let tools: [String] = toolsRaw?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return SavedPrompt(
            id: row["id"],
            slug: row["slug"],
            title: row["title"],
            body: row["body"],
            sourcePromptId: row["source_prompt_id"],
            createdAt: Date.tokenBarDate(millisecondsSince1970: row["created_at"]),
            updatedAt: Date.tokenBarDate(millisecondsSince1970: row["updated_at"]),
            argumentHint: row["argument_hint"],
            allowedTools: tools
        )
    }

    private func deleteCustomSourceData(id: String, db: Database) throws {
        let prefix = "custom:\(id):"
        let prefixLength = prefix.count
        try db.execute(
            sql: """
            DELETE FROM prompts
            WHERE substr(id, 1, ?) = ?
               OR (event_id IS NOT NULL AND substr(event_id, 1, ?) = ?)
            """,
            arguments: [prefixLength, prefix, prefixLength, prefix]
        )
        try db.execute(
            sql: "DELETE FROM usage_events WHERE substr(id, 1, ?) = ?",
            arguments: [prefixLength, prefix]
        )
        try db.execute(
            sql: """
            DELETE FROM source_watermarks
            WHERE last_event_id IS NOT NULL
              AND substr(last_event_id, 1, ?) = ?
            """,
            arguments: [prefixLength, prefix]
        )
    }

    private func insertEvent(_ event: UsageEvent, db: Database) throws -> Int {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO usage_events
            (id, agent, project_path, project_name, session_id, timestamp, input_tokens, output_tokens, cache_tokens, cache_read_tokens, cache_creation_tokens, reasoning_tokens, model_name, source_path, parser, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                event.id,
                event.agent.rawValue,
                event.projectPath,
                event.projectName,
                event.sessionId,
                event.timestamp.tokenBarMillisecondsSince1970,
                event.inputTokens,
                event.outputTokens,
                event.cacheTokens,
                event.cacheReadTokens,
                event.cacheCreationTokens,
                event.reasoningTokens,
                event.modelName,
                event.sourcePath,
                event.parser.rawValue,
                event.confidence,
            ]
        )
        // INSERT OR IGNORE: changesCount==1 → inserted, 0 → row already existed.
        // Avoids a pre-INSERT existence probe per row (was 240k extra queries
        // during cold-start indexing of ~120k events).
        let inserted = db.changesCount > 0
        if !inserted, event.modelName != nil {
            try db.execute(
                sql: "UPDATE usage_events SET model_name = COALESCE(model_name, ?) WHERE id = ?",
                arguments: [event.modelName, event.id]
            )
        }
        return inserted ? 1 : 0
    }

    private func insertPrompt(_ prompt: PromptRecord, db: Database) throws -> Int {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO prompts
            (id, event_id, agent, project_name, session_id, timestamp, content, content_hash, source_path)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                prompt.id,
                prompt.eventId,
                prompt.agent.rawValue,
                prompt.projectName,
                prompt.sessionId,
                prompt.timestamp.tokenBarMillisecondsSince1970,
                prompt.content,
                prompt.contentHash,
                prompt.sourcePath,
            ]
        )
        return db.changesCount > 0 ? 1 : 0
    }

    private func upsertWatermark(_ watermark: SourceWatermark, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO source_watermarks (source_path, agent, last_mtime, last_byte_offset, last_event_id, updated_at, last_inode)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_path) DO UPDATE SET
                agent = excluded.agent,
                last_mtime = excluded.last_mtime,
                last_byte_offset = excluded.last_byte_offset,
                last_event_id = excluded.last_event_id,
                updated_at = excluded.updated_at,
                last_inode = excluded.last_inode
            """,
            arguments: [
                watermark.sourcePath,
                watermark.agent.rawValue,
                watermark.lastMtime.tokenBarMillisecondsSince1970,
                watermark.lastByteOffset,
                watermark.lastEventId,
                watermark.updatedAt.tokenBarMillisecondsSince1970,
                watermark.lastInode.map(Int64.init),
            ]
        )
    }

    private func summary(db: Database, start: Date?, end: Date?, projectName: String?) throws -> UsageSummary {
        var clauses: [String] = []
        var arguments = StatementArguments()
        if let start {
            clauses.append("timestamp >= ?")
            arguments += [start.tokenBarMillisecondsSince1970]
        }
        if let end {
            clauses.append("timestamp < ?")
            arguments += [end.tokenBarMillisecondsSince1970]
        }
        if let projectName {
            clauses.append("project_name = ?")
            arguments += [projectName]
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let row = try Row.fetchOne(db, sql: """
        SELECT COALESCE(SUM(input_tokens), 0) AS input_tokens,
               COALESCE(SUM(output_tokens), 0) AS output_tokens,
               COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
               COALESCE(SUM(cache_creation_tokens), 0) AS cache_creation_tokens
        FROM usage_events
        \(whereClause)
        """, arguments: arguments)
        return UsageSummary(
            inputTokens: row?["input_tokens"] ?? 0,
            outputTokens: row?["output_tokens"] ?? 0,
            cacheReadTokens: row?["cache_read_tokens"] ?? 0,
            cacheCreationTokens: row?["cache_creation_tokens"] ?? 0
        )
    }

    private func usageDays(
        db: Database,
        start: Date,
        end: Date,
        calendar: Calendar,
        projectName: String?
    ) throws -> [UsageDay] {
        var dayRanges: [(date: Date, end: Date)] = []
        var cursor = start
        while cursor < end {
            let next = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end
            dayRanges.append((date: cursor, end: min(next, end)))
            cursor = next
        }
        guard !dayRanges.isEmpty else {
            return []
        }

        var arguments = StatementArguments()
        let valuesSQL = dayRanges.enumerated().map { index, range in
            arguments += [
                index,
                range.date.tokenBarMillisecondsSince1970,
                range.end.tokenBarMillisecondsSince1970,
            ]
            return "(?, ?, ?)"
        }.joined(separator: ", ")
        let projectJoinClause: String
        if let projectName {
            projectJoinClause = "AND usage_events.project_name = ?"
            arguments += [projectName]
        } else {
            projectJoinClause = ""
        }

        let rows = try Row.fetchAll(db, sql: """
        WITH days(day_index, start_ms, end_ms) AS (
            VALUES \(valuesSQL)
        )
        SELECT days.day_index AS day_index,
               COALESCE(SUM(usage_events.input_tokens), 0) AS input_tokens,
               COALESCE(SUM(usage_events.output_tokens), 0) AS output_tokens,
               COALESCE(SUM(usage_events.cache_read_tokens), 0) AS cache_read_tokens,
               COALESCE(SUM(usage_events.cache_creation_tokens), 0) AS cache_creation_tokens
        FROM days
        LEFT JOIN usage_events
          ON usage_events.timestamp >= days.start_ms
         AND usage_events.timestamp < days.end_ms
         \(projectJoinClause)
        GROUP BY days.day_index
        ORDER BY days.day_index ASC
        """, arguments: arguments)

        var summariesByIndex: [Int: UsageSummary] = [:]
        summariesByIndex.reserveCapacity(rows.count)
        for row in rows {
            summariesByIndex[row["day_index"] as Int] = UsageSummary(
                inputTokens: row["input_tokens"],
                outputTokens: row["output_tokens"],
                cacheReadTokens: row["cache_read_tokens"],
                cacheCreationTokens: row["cache_creation_tokens"]
            )
        }

        let days = dayRanges.enumerated().map { index, range in
            UsageDay(
                date: range.date,
                summary: summariesByIndex[index] ?? UsageSummary(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0),
                intensity: 0
            )
        }

        let maxTotal = Double(days.map(\.summary.totalTokens).max() ?? 0)
        return days.map { day in
            UsageDay(
                date: day.date,
                summary: day.summary,
                intensity: maxTotal > 0 ? Double(day.summary.totalTokens) / maxTotal : 0
            )
        }
    }

    private func projectBreakdowns(
        db: Database,
        start: Date,
        end: Date,
        topCount: Int?
    ) throws -> [UsageBreakdown] {
        var arguments: StatementArguments = [
            start.tokenBarMillisecondsSince1970,
            end.tokenBarMillisecondsSince1970,
        ]
        let limitSQL: String
        if let topCount {
            limitSQL = "LIMIT ?"
            arguments += [topCount]
        } else {
            limitSQL = ""
        }
        let rows = try Row.fetchAll(db, sql: """
        SELECT project_name AS name,
               SUM(input_tokens) AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(cache_read_tokens) AS cache_read_tokens,
               SUM(cache_creation_tokens) AS cache_creation_tokens
        FROM usage_events
        WHERE timestamp >= ? AND timestamp < ?
        GROUP BY project_name
        ORDER BY (SUM(input_tokens) + SUM(output_tokens) + SUM(cache_read_tokens) + SUM(cache_creation_tokens)) DESC, name ASC
        \(limitSQL)
        """, arguments: arguments)
        return rows.map { row in
            UsageBreakdown(
                name: row["name"] as String,
                summary: UsageSummary(
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    cacheReadTokens: row["cache_read_tokens"],
                    cacheCreationTokens: row["cache_creation_tokens"]
                )
            )
        }
    }

    private func costProjection(
        db: Database,
        start: Date?,
        end: Date?,
        projectName: String?
    ) throws -> UsageCostProjection {
        let byModel = try summaryByModel(db: db, start: start, end: end, projectName: projectName)
        let totalTokens = byModel.reduce(0) { $0 + $1.totalTokens }
        let costByAgent = byModel
            .map { summary -> UsageCostBreakdown in
                let percentage = totalTokens > 0 ? Double(summary.totalTokens) / Double(totalTokens) : 0
                return UsageCostBreakdown(
                    name: summary.name,
                    totalTokens: summary.totalTokens,
                    cost: summary.cost,
                    percentage: percentage
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalTokens == rhs.totalTokens {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.totalTokens > rhs.totalTokens
            }
        let totalCost = costByAgent.reduce(0.0) { $0 + $1.cost }
        let blendedRatePerMillion = totalTokens > 0
            ? totalCost / Double(totalTokens) * 1_000_000
            : 0
        return UsageCostProjection(
            totalCost: totalCost,
            blendedRatePerMillion: blendedRatePerMillion,
            byAgent: costByAgent
        )
    }

    private func summaryByModel(
        db: Database,
        start: Date?,
        end: Date?,
        projectName: String?
    ) throws -> [UsageModelSummary] {
        var clauses: [String] = []
        var arguments = StatementArguments()
        if let start {
            clauses.append("timestamp >= ?")
            arguments += [start.tokenBarMillisecondsSince1970]
        }
        if let end {
            clauses.append("timestamp < ?")
            arguments += [end.tokenBarMillisecondsSince1970]
        }
        if let projectName {
            clauses.append("project_name = ?")
            arguments += [projectName]
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let rows = try Row.fetchAll(db, sql: """
        SELECT COALESCE(model_name, '') AS model_name,
               agent,
               SUM(input_tokens) AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(cache_read_tokens) AS cache_read_tokens,
               SUM(cache_creation_tokens) AS cache_creation_tokens
        FROM usage_events
        \(whereClause)
        GROUP BY COALESCE(model_name, ''), agent
        """, arguments: arguments)

        var outputByModel: [String: UsageModelSummary] = [:]
        for row in rows {
            guard
                let rawAgent = row["agent"] as String?,
                let agent = AgentKind(rawValue: rawAgent)
            else {
                continue
            }
            let summary = UsageSummary(
                inputTokens: row["input_tokens"],
                outputTokens: row["output_tokens"],
                cacheReadTokens: row["cache_read_tokens"],
                cacheCreationTokens: row["cache_creation_tokens"]
            )
            let rawModelName = row["model_name"] as String?
            let modelName = rawModelName?.isEmpty == false ? rawModelName! : agent.displayName
            let existing = outputByModel[modelName] ?? UsageModelSummary(name: modelName, totalTokens: 0, cost: 0)
            outputByModel[modelName] = UsageModelSummary(
                name: modelName,
                totalTokens: existing.totalTokens + summary.totalTokens,
                cost: existing.cost + (Double(summary.totalTokens) * agent.defaultCostPerMillionTokens / 1_000_000)
            )
        }
        return Array(outputByModel.values)
    }

    private func rankedBreakdowns(
        db: Database,
        groupColumn: String,
        start: Date,
        end: Date,
        projectName: String?,
        topCount: Int,
        mapName: (String) -> String
    ) throws -> [UsageBreakdown] {
        precondition(["agent", "project_name"].contains(groupColumn))
        var arguments: StatementArguments = [
            start.tokenBarMillisecondsSince1970,
            end.tokenBarMillisecondsSince1970,
        ]
        var projectFilter = ""
        if let projectName {
            projectFilter = "AND project_name = ?"
            arguments += [projectName]
        }
        arguments += [topCount]
        let rows = try Row.fetchAll(db, sql: """
        SELECT \(groupColumn) AS name,
               SUM(input_tokens) AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(cache_read_tokens) AS cache_read_tokens,
               SUM(cache_creation_tokens) AS cache_creation_tokens
        FROM usage_events
        WHERE timestamp >= ? AND timestamp < ? \(projectFilter)
        GROUP BY \(groupColumn)
        ORDER BY (SUM(input_tokens) + SUM(output_tokens) + SUM(cache_read_tokens) + SUM(cache_creation_tokens)) DESC, name ASC
        LIMIT ?
        """, arguments: arguments)
        return rows.map { row in
            UsageBreakdown(
                name: mapName(row["name"] as String),
                summary: UsageSummary(
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    cacheReadTokens: row["cache_read_tokens"],
                    cacheCreationTokens: row["cache_creation_tokens"]
                )
            )
        }
    }

    private func event(from row: Row) -> UsageEvent? {
        guard
            let agent = AgentKind(rawValue: row["agent"] as String),
            let parser = ParserKind(rawValue: row["parser"] as String)
        else {
            return nil
        }

        return UsageEvent(
            id: row["id"],
            agent: agent,
            projectPath: row["project_path"],
            projectName: row["project_name"],
            sessionId: row["session_id"],
            timestamp: .tokenBarDate(millisecondsSince1970: row["timestamp"]),
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            cacheReadTokens: row["cache_read_tokens"],
            cacheCreationTokens: row["cache_creation_tokens"],
            reasoningTokens: row["reasoning_tokens"],
            modelName: row["model_name"],
            sourcePath: row["source_path"],
            parser: parser,
            confidence: row["confidence"]
        )
    }

    private struct UsageModelSummary: Sendable, Hashable {
        let name: String
        let totalTokens: Int
        let cost: Double
    }

    private func prompt(from row: Row) -> PromptRecord? {
        guard let agent = AgentKind(rawValue: row["agent"] as String) else {
            return nil
        }
        return PromptRecord(
            id: row["id"],
            eventId: row["event_id"],
            agent: agent,
            projectName: row["project_name"],
            sessionId: row["session_id"],
            timestamp: .tokenBarDate(millisecondsSince1970: row["timestamp"]),
            content: row["content"],
            contentHash: row["content_hash"],
            sourcePath: row["source_path"]
        )
    }

    private func customSourceRecord(from row: Row) -> CustomSourceRecord {
        CustomSourceRecord(
            id: row["id"],
            name: row["name"],
            plugin: CustomSourcePlugin(rawValue: row["plugin"] as String) ?? .claudeCode,
            directory: row["directory"],
            globPattern: row["glob_pattern"],
            format: CustomSourceFormat(rawValue: row["format"] as String) ?? .unknown,
            displayAgent: row["display_agent"],
            enabled: (row["enabled"] as Int) != 0,
            fieldMapping: decodeFieldMapping(row["field_mapping"]),
            createdAt: .tokenBarDate(millisecondsSince1970: row["created_at"]),
            pluginId: row["plugin_id"] as String?,
            pluginVersion: row["plugin_version"] as String?,
            inputIncludesCached: ((row["input_includes_cached"] as Int?) ?? 0) != 0,
            timestampFormat: PluginTimestampFormat(rawValue: (row["timestamp_format"] as String?) ?? "iso8601") ?? .iso8601,
            sqliteQuery: decodeJSON(row["sqlite_query"] as String?),
            executableConfig: decodeJSON(row["executable_config"] as String?)
        )
    }

    private func decodeFieldMapping(_ raw: String?) -> CustomSourceFieldMapping {
        guard let raw, let data = raw.data(using: .utf8) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(CustomSourceFieldMapping.self, from: data)
        } catch {
            return .default
        }
    }

    private func encodeFieldMapping(_ mapping: CustomSourceFieldMapping) -> String {
        (try? String(data: JSONEncoder().encode(mapping), encoding: .utf8)) ?? "{}"
    }

    private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        return try? String(data: JSONEncoder().encode(value), encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func checkpoint(from row: Row) -> CheckpointSummary {
        CheckpointSummary(
            id: row["id"],
            startedAt: .tokenBarDate(millisecondsSince1970: row["started_at"]),
            endedAt: (row["ended_at"] as Int64?).map(Date.tokenBarDate(millisecondsSince1970:)),
            trigger: row["trigger"],
            eventsAdded: row["events_added"],
            promptsAdded: row["prompts_added"],
            warnings: row["warnings"],
            error: row["error"]
        )
    }

    private func watermark(from row: Row) -> SourceWatermark? {
        guard let agent = AgentKind(rawValue: row["agent"] as String) else {
            return nil
        }
        let inode: Int64? = row["last_inode"]
        return SourceWatermark(
            sourcePath: row["source_path"],
            agent: agent,
            lastMtime: .tokenBarDate(millisecondsSince1970: row["last_mtime"]),
            lastByteOffset: row["last_byte_offset"],
            lastEventId: row["last_event_id"],
            lastInode: inode.map(UInt64.init),
            updatedAt: .tokenBarDate(millisecondsSince1970: row["updated_at"])
        )
    }

    private func agentDisplayName(_ rawValue: String) -> String {
        AgentKind(rawValue: rawValue)?.displayName ?? rawValue
    }

    private func latestWarningCount(db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(warnings, 0) FROM checkpoints ORDER BY id DESC LIMIT 1"
        ) ?? 0
    }

    private struct CollectionFingerprint: Sendable {
        let count: Int
        let signature: String
    }

    private func collectionSignatureForEvents(db: Database) throws -> CollectionFingerprint {
        let row = try Row.fetchOne(db, sql: """
        SELECT COALESCE(COUNT(*), 0) AS total_count,
               COALESCE(MIN(timestamp), 0) AS min_timestamp,
               COALESCE(MAX(timestamp), 0) AS max_timestamp,
               COALESCE(MIN(id), '') AS min_id,
               COALESCE(MAX(id), '') AS max_id,
               COALESCE(SUM(LENGTH(id)), 0) AS id_bytes
        FROM usage_events
        """)
        return CollectionFingerprint(
            count: row?["total_count"] ?? 0,
            signature: makeCollectionSignature(
                count: row?["total_count"] ?? 0,
                minTimestamp: row?["min_timestamp"] ?? Int64.zero,
                maxTimestamp: row?["max_timestamp"] ?? Int64.zero,
                minMarker: row?["min_id"] ?? "",
                maxMarker: row?["max_id"] ?? "",
                markerBytes: row?["id_bytes"] ?? 0
            )
        )
    }

    private func collectionSignatureForPrompts(db: Database) throws -> CollectionFingerprint {
        let row = try Row.fetchOne(db, sql: """
        SELECT COALESCE(COUNT(*), 0) AS total_count,
               COALESCE(MIN(timestamp), 0) AS min_timestamp,
               COALESCE(MAX(timestamp), 0) AS max_timestamp,
               COALESCE(MIN(content_hash), '') AS min_hash,
               COALESCE(MAX(content_hash), '') AS max_hash,
               COALESCE(SUM(LENGTH(content_hash)), 0) AS hash_bytes
        FROM prompts
        """)
        return CollectionFingerprint(
            count: row?["total_count"] ?? 0,
            signature: makeCollectionSignature(
                count: row?["total_count"] ?? 0,
                minTimestamp: row?["min_timestamp"] ?? Int64.zero,
                maxTimestamp: row?["max_timestamp"] ?? Int64.zero,
                minMarker: row?["min_hash"] ?? "",
                maxMarker: row?["max_hash"] ?? "",
                markerBytes: row?["hash_bytes"] ?? 0
            )
        )
    }

    private func makeCollectionSignature(
        count: Int,
        minTimestamp: Int64,
        maxTimestamp: Int64,
        minMarker: String,
        maxMarker: String,
        markerBytes: Int
    ) -> String {
        "\(count)|\(minTimestamp)|\(maxTimestamp)|\(markerBytes)|\(minMarker)|\(maxMarker)"
    }

    // MARK: - Library

    public func upsertLibrarySkills(_ skills: [ScannedSkill], scope: LibraryScope) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "DELETE FROM library_skills WHERE scope = ?",
                arguments: [scope.rawValue]
            )
            for skill in skills {
                let allowedToolsJSON: String? = skill.allowedTools.map { tools in
                    (try? JSONSerialization.data(withJSONObject: tools))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                }
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO library_skills (path, scope, scope_root, name, is_symlink, resolved_target, is_broken, size_bytes, estimated_tokens, description, allowed_tools, plugin_id, modified_at, scanned_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        skill.path.path,
                        skill.scope.rawValue,
                        skill.scopeRoot.path,
                        skill.name,
                        skill.isSymlink ? 1 : 0,
                        skill.resolvedTarget?.path,
                        skill.isBroken ? 1 : 0,
                        skill.sizeBytes,
                        skill.estimatedTokens,
                        skill.description,
                        allowedToolsJSON,
                        skill.pluginId,
                        skill.modifiedAt.timeIntervalSince1970,
                        skill.scannedAt.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    public func upsertLibraryMcp(_ servers: [ScannedMcpServer], scope: LibraryScope) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "DELETE FROM library_mcp WHERE scope = ?",
                arguments: [scope.rawValue]
            )
            for server in servers {
                let argsJSON = (try? JSONSerialization.data(withJSONObject: server.args))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let envKeysJSON = (try? JSONSerialization.data(withJSONObject: server.envKeys))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(
                    sql: """
                    INSERT INTO library_mcp (scope, source_file, name, command, args, env_keys, estimated_tokens, is_disabled, project_root, scanned_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        server.scope.rawValue,
                        server.sourceFile.path,
                        server.name,
                        server.command,
                        argsJSON,
                        envKeysJSON,
                        server.estimatedTokens,
                        server.isDisabled ? 1 : 0,
                        server.projectRoot,
                        server.scannedAt.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    public func upsertLibraryScanState(_ state: LibraryScanState) throws {
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO library_scan_state (scope, last_scan_at, last_error, skill_count, mcp_count)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    state.scope.rawValue,
                    state.lastScanAt.timeIntervalSince1970,
                    state.lastError,
                    state.skillCount,
                    state.mcpCount,
                ]
            )
        }
    }

    public func upsertLibraryPlugins(_ plugins: [ScannedClaudePlugin]) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM library_plugins")
            for plugin in plugins {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO library_plugins (full_id, name, marketplace, version, scope, install_path, project_path, installed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        plugin.fullId,
                        plugin.name,
                        plugin.marketplace,
                        plugin.version,
                        plugin.scope,
                        plugin.installPath,
                        plugin.projectPath,
                        plugin.installedAt?.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    public func loadLibraryPlugins() throws -> [ScannedClaudePlugin] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM library_plugins ORDER BY full_id")
            return rows.map { row in
                ScannedClaudePlugin(
                    fullId: row["full_id"] ?? "",
                    name: row["name"] ?? "",
                    marketplace: row["marketplace"] ?? "",
                    version: row["version"] ?? "",
                    scope: row["scope"] ?? "",
                    installPath: row["install_path"] ?? "",
                    projectPath: row["project_path"] as String?,
                    installedAt: (row["installed_at"] as Double?).map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
    }

    public func loadLibrarySkills() throws -> [ScannedSkill] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM library_skills ORDER BY scope, name")
            return rows.compactMap { row -> ScannedSkill? in
                guard let scopeStr: String = row["scope"],
                      let scope = LibraryScope(rawValue: scopeStr) else { return nil }
                let allowedTools: [String]? = (row["allowed_tools"] as String?).flatMap { str in
                    guard let data = str.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
                    return arr
                }
                return ScannedSkill(
                    scope: scope,
                    scopeRoot: URL(fileURLWithPath: row["scope_root"] as String? ?? ""),
                    name: row["name"] ?? "",
                    path: URL(fileURLWithPath: row["path"] as String? ?? ""),
                    isSymlink: (row["is_symlink"] as Int?) == 1,
                    resolvedTarget: (row["resolved_target"] as String?).map { URL(fileURLWithPath: $0) },
                    isBroken: (row["is_broken"] as Int?) == 1,
                    sizeBytes: row["size_bytes"] ?? 0,
                    estimatedTokens: row["estimated_tokens"] ?? 0,
                    description: row["description"],
                    allowedTools: allowedTools,
                    pluginId: row["plugin_id"] as String?,
                    modifiedAt: Date(timeIntervalSince1970: row["modified_at"] ?? 0),
                    scannedAt: Date(timeIntervalSince1970: row["scanned_at"] ?? 0)
                )
            }
        }
    }

    public func loadLibraryMcp() throws -> [ScannedMcpServer] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM library_mcp ORDER BY scope, name")
            return rows.compactMap { row -> ScannedMcpServer? in
                guard let scopeStr: String = row["scope"],
                      let scope = LibraryScope(rawValue: scopeStr) else { return nil }
                let args: [String] = (row["args"] as String?).flatMap { str in
                    guard let data = str.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
                    return arr
                } ?? []
                let envKeys: [String] = (row["env_keys"] as String?).flatMap { str in
                    guard let data = str.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
                    return arr
                } ?? []
                return ScannedMcpServer(
                    scope: scope,
                    sourceFile: URL(fileURLWithPath: row["source_file"] as String? ?? ""),
                    name: row["name"] ?? "",
                    command: row["command"] ?? "",
                    args: args,
                    envKeys: envKeys,
                    estimatedTokens: row["estimated_tokens"] ?? 0,
                    isDisabled: (row["is_disabled"] as Int?) == 1,
                    projectRoot: row["project_root"] as String?,
                    scannedAt: Date(timeIntervalSince1970: row["scanned_at"] ?? 0)
                )
            }
        }
    }

    public func loadLibraryScanStates() throws -> [LibraryScope: LibraryScanState] {
        try database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM library_scan_state")
            var result: [LibraryScope: LibraryScanState] = [:]
            for row in rows {
                guard let scopeStr: String = row["scope"],
                      let scope = LibraryScope(rawValue: scopeStr) else { continue }
                result[scope] = LibraryScanState(
                    scope: scope,
                    lastScanAt: Date(timeIntervalSince1970: row["last_scan_at"] ?? 0),
                    lastError: row["last_error"],
                    skillCount: row["skill_count"] ?? 0,
                    mcpCount: row["mcp_count"] ?? 0
                )
            }
            return result
        }
    }
}
