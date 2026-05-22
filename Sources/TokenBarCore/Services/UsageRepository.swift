import Foundation
import GRDB

public struct UsageRepository: Sendable {
    private let database: UsageDatabase

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
        try database.queue.write { db in
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
                   input_tokens, output_tokens, cache_tokens, reasoning_tokens, model_name,
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
        topCount: Int = 3
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
                    cacheTokens: 0
                )
            ) { total, day in
                UsageSummary(
                    inputTokens: total.inputTokens + day.summary.inputTokens,
                    outputTokens: total.outputTokens + day.summary.outputTokens,
                    cacheTokens: total.cacheTokens + day.summary.cacheTokens
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
                   SUM(cache_tokens) AS cache_tokens
            FROM usage_events
            WHERE project_name = ? AND timestamp >= ? AND timestamp < ?
            GROUP BY agent
            ORDER BY (SUM(input_tokens) + SUM(output_tokens) + SUM(cache_tokens)) DESC, agent ASC
            LIMIT ?
            """, arguments: [projectName, windowStart.tokenBarMillisecondsSince1970, windowEnd.tokenBarMillisecondsSince1970, topAgentCount])
            let agentShare = agentRows.map { row in
                let name = agentDisplayName(row["agent"] as String)
                let totalTokens = ((row["input_tokens"] as Int?) ?? 0) + ((row["output_tokens"] as Int?) ?? 0) + ((row["cache_tokens"] as Int?) ?? 0)
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
                   SUM(cache_tokens) AS cache_tokens
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
                        cacheTokens: row["cache_tokens"]
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
            SELECT id, name, directory, glob_pattern, format, display_agent, enabled, field_mapping, created_at
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
            try db.execute(
                sql: """
                INSERT INTO custom_sources (id, name, directory, glob_pattern, format, display_agent, enabled, field_mapping, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    directory = excluded.directory,
                    glob_pattern = excluded.glob_pattern,
                    format = excluded.format,
                    display_agent = excluded.display_agent,
                    enabled = excluded.enabled,
                    field_mapping = excluded.field_mapping
                """,
                arguments: [
                    source.id,
                    source.name,
                    source.directory,
                    source.globPattern,
                    source.format.rawValue,
                    source.displayAgent,
                    source.enabled ? 1 : 0,
                    encodeFieldMapping(source.fieldMapping),
                    source.createdAt.tokenBarMillisecondsSince1970,
                ]
            )
        }
    }

    public func deleteCustomSource(id: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM custom_sources WHERE id = ?", arguments: [id])
        }
    }

    private func insertEvent(_ event: UsageEvent, db: Database) throws -> Int {
        let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_events WHERE id = ?", arguments: [event.id]) ?? 0
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO usage_events
            (id, agent, project_path, project_name, session_id, timestamp, input_tokens, output_tokens, cache_tokens, reasoning_tokens, model_name, source_path, parser, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                event.reasoningTokens,
                event.modelName,
                event.sourcePath,
                event.parser.rawValue,
                event.confidence,
            ]
        )
        if exists > 0, event.modelName != nil {
            try db.execute(
                sql: "UPDATE usage_events SET model_name = COALESCE(model_name, ?) WHERE id = ?",
                arguments: [event.modelName, event.id]
            )
        }
        return exists == 0 ? 1 : 0
    }

    private func insertPrompt(_ prompt: PromptRecord, db: Database) throws -> Int {
        let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM prompts WHERE id = ?", arguments: [prompt.id]) ?? 0
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
        return exists == 0 ? 1 : 0
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
               COALESCE(SUM(cache_tokens), 0) AS cache_tokens
        FROM usage_events
        \(whereClause)
        """, arguments: arguments)
        return UsageSummary(
            inputTokens: row?["input_tokens"] ?? 0,
            outputTokens: row?["output_tokens"] ?? 0,
            cacheTokens: row?["cache_tokens"] ?? 0
        )
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
               SUM(cache_tokens) AS cache_tokens
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
                cacheTokens: row["cache_tokens"]
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
               SUM(cache_tokens) AS cache_tokens
        FROM usage_events
        WHERE timestamp >= ? AND timestamp < ? \(projectFilter)
        GROUP BY \(groupColumn)
        ORDER BY (SUM(input_tokens) + SUM(output_tokens) + SUM(cache_tokens)) DESC, name ASC
        LIMIT ?
        """, arguments: arguments)
        return rows.map { row in
            UsageBreakdown(
                name: mapName(row["name"] as String),
                summary: UsageSummary(
                    inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"],
                    cacheTokens: row["cache_tokens"]
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
            cacheTokens: row["cache_tokens"],
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
            directory: row["directory"],
            globPattern: row["glob_pattern"],
            format: CustomSourceFormat(rawValue: row["format"] as String) ?? .unknown,
            displayAgent: row["display_agent"],
            enabled: (row["enabled"] as Int) != 0,
            fieldMapping: decodeFieldMapping(row["field_mapping"]),
            createdAt: .tokenBarDate(millisecondsSince1970: row["created_at"])
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
}
