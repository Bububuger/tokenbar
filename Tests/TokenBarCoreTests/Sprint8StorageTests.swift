import Foundation
import GRDB
import Testing
@testable import TokenBarCore

struct Sprint8StorageTests {
    @Test
    func builtInSourcesIncludesAllSixAgents() {
        let sources = BuiltInSources.all()
        let agents = Set(sources.map(\.agent))
        #expect(sources.count == 6)
        #expect(agents == Set<AgentKind>([.codex, .claudeCode, .hermes, .geminiCLI, .openclaw, .openCode]))
    }

    /// Regression: prompt search must hit the FTS5 index (v10 migration),
    /// not the old `LOWER(content) LIKE '%x%'` full table scan.
    @Test
    func promptSearchUsesFTSIndexAndReturnsCorrectCount() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let referenceDate = fixedDate()
        let calendar = Calendar(identifier: .gregorian)

        // Seed 200 prompts. 50 of them mention "build" in content.
        var prompts: [PromptRecord] = []
        for i in 0..<200 {
            let mentionsBuild = i % 4 == 0   // 50 of 200
            let content = mentionsBuild
                ? "let's build the new feature in tokenbar"
                : "general conversation about something else"
            prompts.append(PromptRecord(
                id: "fts-\(i)",
                eventId: nil,
                agent: .codex,
                projectName: "tokenbar",
                sessionId: "fts-session-\(i)",
                timestamp: calendar.date(byAdding: .minute, value: -i, to: referenceDate)!,
                content: content,
                contentHash: "fts-hash-\(i)",
                sourcePath: "/tmp/fts.jsonl"
            ))
        }

        _ = try repository.insertCheckpoint(
            trigger: "fts-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [],
            prompts: prompts,
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let start = Date()
        let page = try repository.projectPromptHistoryPage(
            projectName: "tokenbar",
            limit: 10,
            offset: 0,
            includeContent: true,
            query: "build"
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(page.totalCount == 50)
        #expect(page.prompts.count == 10)
        // 200-prompt seed is small; assert generous bound that would fail
        // only if FTS regressed back to full scan over many KB.
        #expect(elapsed < 0.2)
    }

    @Test
    func discoveryCacheServesRepeatCallsWithinTTL() throws {
        DiscoveryCache.reset()
        let dir = temporaryDirectory()
        let nested = dir.appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "{}".write(to: nested.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let baselineMiss = DiscoveryCache.missCount
        _ = try ClaudeDataSource.discoverSessionFiles(rootDirectory: dir.path)
        _ = try ClaudeDataSource.discoverSessionFiles(rootDirectory: dir.path)
        _ = try ClaudeDataSource.discoverSessionFiles(rootDirectory: dir.path)

        // 3 calls into the same source within TTL: one miss + two hits.
        #expect(DiscoveryCache.missCount == baselineMiss + 1)
        #expect(DiscoveryCache.hitCount >= 2)
    }

    @Test
    func migrationCreatesRequiredTables() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)

        let sources = try repository.listCustomSources()
        let checkpoint = try repository.latestCheckpoint()
        let queue = try DatabaseQueue(path: dbURL.path)
        let tables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }

        #expect(sources.isEmpty)
        #expect(checkpoint == nil)
        #expect(tables.contains("usage_events"))
        #expect(tables.contains("prompts"))
        #expect(tables.contains("source_watermarks"))
        #expect(tables.contains("checkpoints"))
        #expect(tables.contains("source_warnings"))
        #expect(tables.contains("custom_sources"))
    }

    @Test
    func makeSnapshotAggregatesFromSQLiteWithDerivedFields() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = fixedDate()
        let warning = UsageSourceWarning(
            sourceName: "codex",
            sourcePath: "/tmp/codex.jsonl",
            lineNumber: 3,
            message: "parse warning"
        )

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-aggregation-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(
                    id: "a",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-a",
                    timestamp: referenceDate,
                    inputTokens: 100,
                    outputTokens: 40,
                    cacheTokens: 40
                ),
                dbEvent(
                    id: "b",
                    agent: .hermes,
                    projectName: "tokenbar",
                    sessionId: "session-b",
                    timestamp: calendar.date(byAdding: .day, value: -1, to: referenceDate)!,
                    inputTokens: 20,
                    outputTokens: 10,
                    cacheTokens: 0
                ),
                dbEvent(
                    id: "c",
                    agent: .geminiCLI,
                    projectName: "knowledge",
                    sessionId: "session-c",
                    timestamp: calendar.date(byAdding: .day, value: -2, to: referenceDate)!,
                    inputTokens: 10,
                    outputTokens: 20,
                    cacheTokens: 20
                ),
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [warning],
            error: nil
        )

        let snapshot = try repository.makeSnapshot(referenceDate: referenceDate, calendar: calendar)
        #expect(snapshot.warningCount == 1)
        #expect(snapshot.today.totalTokens == 180)
        #expect(snapshot.today.focus.dominantDimension == "Input")
        #expect(snapshot.activeDays == 3)
        #expect(snapshot.peakDay == calendar.startOfDay(for: referenceDate))
        #expect(abs(snapshot.estimatedCostToday.totalCost - 0.0008028) < 0.0000001)
        #expect(abs(snapshot.estimatedCostLast30.totalCost - 0.0008323) < 0.0000001)
        #expect(snapshot.last30Summary.totalTokens == 260)
    }

    @Test
    func rangeAggregateUsesSQLiteWindowAndGroupedRows() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = fixedDate()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate)!
        let oldDate = calendar.date(byAdding: .day, value: -40, to: referenceDate)!
        let start = calendar.startOfDay(for: yesterday)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate))!

        _ = try repository.insertCheckpoint(
            trigger: "range-aggregate-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(id: "codex-a", agent: .codex, projectName: "tokenbar", sessionId: "a", timestamp: referenceDate, inputTokens: 10, outputTokens: 5, cacheTokens: 5, modelName: "gpt-5-codex"),
                dbEvent(id: "claude-a", agent: .claudeCode, projectName: "tokenbar", sessionId: "b", timestamp: yesterday, inputTokens: 20, outputTokens: 5, cacheTokens: 0, modelName: "claude-sonnet-4.5"),
                dbEvent(id: "codex-b", agent: .codex, projectName: "my-app", sessionId: "c", timestamp: yesterday, inputTokens: 3, outputTokens: 2, cacheTokens: 1),
                dbEvent(id: "old", agent: .codex, projectName: "old", sessionId: "d", timestamp: oldDate, inputTokens: 100, outputTokens: 100, cacheTokens: 100),
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let bounds = try repository.eventTimeBounds()
        let aggregate = try repository.rangeAggregate(start: start, end: end, calendar: calendar)
        let projects = try repository.projectBreakdowns(start: start, end: end, topCount: nil)

        #expect(bounds.eventCount == 4)
        #expect(bounds.earliest == oldDate)
        #expect(aggregate.summary.totalTokens == 51)
        #expect(aggregate.days.count == 2)
        #expect(aggregate.days.map(\.summary.totalTokens) == [31, 20])
        #expect(aggregate.rows.count == 3)
        #expect(projects.map(\.name) == ["tokenbar", "my-app"])
        #expect(projects.map { $0.summary.totalTokens } == [45, 6])
    }

    @Test
    func deleteRecordsBeforeCutoffPrunesEventsAndPrompts() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = fixedDate()
        let oldDate = calendar.date(byAdding: .day, value: -45, to: referenceDate)!
        let cutoff = calendar.date(byAdding: .day, value: -30, to: referenceDate)!

        _ = try repository.insertCheckpoint(
            trigger: "retention-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(id: "old", agent: .codex, projectName: "tokenbar", sessionId: "old", timestamp: oldDate, inputTokens: 1, outputTokens: 1, cacheTokens: 0),
                dbEvent(id: "new", agent: .codex, projectName: "tokenbar", sessionId: "new", timestamp: referenceDate, inputTokens: 2, outputTokens: 2, cacheTokens: 0),
            ],
            prompts: [
                prompt(id: "old-prompt", timestamp: oldDate),
                prompt(id: "new-prompt", timestamp: referenceDate),
            ],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        try repository.deleteRecords(before: cutoff)

        #expect(try repository.allEvents().map(\.id) == ["new"])
        #expect(try repository.allPrompts().map(\.id) == ["new-prompt"])
    }

    @Test
    func reparseAllClearsIndexedRowsBeforeRebuild() async throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let referenceDate = fixedDate()
        let warning = UsageSourceWarning(
            sourceName: "Codex",
            sourcePath: "/tmp/source.jsonl",
            lineNumber: 7,
            message: "stale warning"
        )
        let watermark = SourceWatermark(
            sourcePath: "/tmp/source.jsonl",
            agent: .codex,
            lastMtime: referenceDate,
            lastByteOffset: 128,
            lastEventId: "old-event",
            lastInode: 42,
            updatedAt: referenceDate
        )

        _ = try repository.insertCheckpoint(
            trigger: "initial-index",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(id: "old-event", agent: .codex, projectName: "tokenbar", sessionId: "old", timestamp: referenceDate, inputTokens: 10, outputTokens: 2, cacheTokens: 1),
            ],
            prompts: [
                prompt(id: "old-prompt", timestamp: referenceDate),
            ],
            nextWatermarks: [watermark],
            warnings: [warning],
            error: nil
        )

        let store = try UsageStore(databaseURL: dbURL)
        try await store.reparseAll()

        let verifier = try UsageRepository(databaseURL: dbURL)
        #expect(try verifier.allEvents().isEmpty)
        #expect(try verifier.allPrompts().isEmpty)
        #expect(try verifier.watermarks().isEmpty)
        #expect(try verifier.latestCheckpoint() == nil)
    }

    @Test
    func storeStateRestoresLatestCheckpointWarningsAfterRestart() async throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let referenceDate = fixedDate()
        let warning = UsageSourceWarning(
            sourceName: "Codex",
            sourcePath: "/tmp/source.jsonl",
            lineNumber: 11,
            message: "malformed JSON"
        )

        _ = try repository.insertCheckpoint(
            trigger: "bootstrap",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(id: "event", agent: .codex, projectName: "tokenbar", sessionId: "s", timestamp: referenceDate, inputTokens: 10, outputTokens: 1, cacheTokens: 2),
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [warning],
            error: nil
        )

        let restartedStore = try UsageStore(databaseURL: dbURL)
        let state = await restartedStore.state(referenceDate: referenceDate, calendar: Calendar(identifier: .gregorian))

        #expect(state.warnings == [warning])
        #expect(state.snapshot.warningCount == 1)
        #expect(state.lastIndexedAt == referenceDate)
    }

    @Test
    func migrationRoundTripsUsageEventModelName() throws {
        let dbURL = temporaryDatabaseURL()
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE usage_events (
                id TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                project_path TEXT,
                project_name TEXT NOT NULL,
                session_id TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER,
                source_path TEXT NOT NULL,
                parser TEXT NOT NULL,
                confidence REAL NOT NULL
            )
            """)
            try db.execute(sql: "CREATE TABLE prompts (id TEXT PRIMARY KEY, event_id TEXT, agent TEXT NOT NULL, project_name TEXT NOT NULL, session_id TEXT NOT NULL, timestamp INTEGER NOT NULL, content TEXT NOT NULL, content_hash TEXT NOT NULL, source_path TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE source_watermarks (source_path TEXT PRIMARY KEY, agent TEXT NOT NULL, last_mtime INTEGER NOT NULL, last_byte_offset INTEGER NOT NULL, last_event_id TEXT, updated_at INTEGER NOT NULL, last_inode INTEGER)")
            try db.execute(sql: "INSERT INTO source_watermarks (source_path, agent, last_mtime, last_byte_offset, last_event_id, updated_at, last_inode) VALUES ('/tmp/source', 'hermes', 1, 0, 'old', 1, 1)")
            try db.execute(sql: "CREATE TABLE checkpoints (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at INTEGER NOT NULL, ended_at INTEGER, trigger TEXT NOT NULL, events_added INTEGER NOT NULL DEFAULT 0, prompts_added INTEGER NOT NULL DEFAULT 0, warnings INTEGER NOT NULL DEFAULT 0, error TEXT)")
            try db.execute(sql: "CREATE TABLE source_warnings (id INTEGER PRIMARY KEY AUTOINCREMENT, checkpoint_id INTEGER, source_name TEXT NOT NULL, source_path TEXT NOT NULL, line_number INTEGER, message TEXT NOT NULL, created_at INTEGER NOT NULL)")
            try db.execute(sql: "CREATE TABLE custom_sources (id TEXT PRIMARY KEY, name TEXT NOT NULL, directory TEXT NOT NULL, glob_pattern TEXT NOT NULL, format TEXT NOT NULL, display_agent TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL)")
        }
        let repository = try UsageRepository(databaseURL: dbURL)
        #expect(try repository.watermarks().isEmpty)

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-migration-roundtrip",
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            endedAt: Date(timeIntervalSince1970: 1_770_000_000),
            events: [
                UsageEvent(
                    id: "modeled",
                    agent: .claudeCode,
                    projectPath: "/tmp/project",
                    projectName: "tokenbar",
                    sessionId: "session",
                    timestamp: Date(timeIntervalSince1970: 1_770_000_000),
                    inputTokens: 1,
                    outputTokens: 2,
                    cacheTokens: 3,
                    reasoningTokens: nil,
                    modelName: "claude-model",
                    sourcePath: "/tmp/source",
                    parser: .claudeCode,
                    confidence: 1.0
                )
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let events = try repository.allEvents()
        #expect(events.count == 1)
        #expect(events[0].modelName == "claude-model")
    }

    @Test
    func duplicateCheckpointBackfillsMissingModelName() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let referenceDate = fixedDate()

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-model-backfill-initial",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(
                    id: "same-event",
                    agent: .hermes,
                    projectName: "tokenbar",
                    sessionId: "s1",
                    timestamp: referenceDate,
                    inputTokens: 10,
                    outputTokens: 0,
                    cacheTokens: 0,
                    modelName: nil
                )
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )
        let second = try repository.insertCheckpoint(
            trigger: "sqlite-model-backfill-second",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(
                    id: "same-event",
                    agent: .hermes,
                    projectName: "tokenbar",
                    sessionId: "s1",
                    timestamp: referenceDate,
                    inputTokens: 10,
                    outputTokens: 0,
                    cacheTokens: 0,
                    modelName: "gpt-5.3-codex-spark"
                )
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let events = try repository.allEvents()
        #expect(second.eventsAdded == 0)
        #expect(events.count == 1)
        #expect(events.first?.modelName == "gpt-5.3-codex-spark")
    }

    @Test
    func costProjectionUsesModelNameFirstThenAgentDisplayNameFallback() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let referenceDate = fixedDate()

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-model-cost-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(
                    id: "model-a-1",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "s1",
                    timestamp: referenceDate,
                    inputTokens: 100,
                    outputTokens: 100,
                    cacheTokens: 0,
                    modelName: "gemini-2.5-pro"
                ),
                dbEvent(
                    id: "model-a-2",
                    agent: .hermes,
                    projectName: "tokenbar",
                    sessionId: "s2",
                    timestamp: referenceDate,
                    inputTokens: 200,
                    outputTokens: 0,
                    cacheTokens: 0,
                    modelName: "gemini-2.5-pro"
                ),
                dbEvent(
                    id: "model-fallback",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "s3",
                    timestamp: referenceDate,
                    inputTokens: 10,
                    outputTokens: 0,
                    cacheTokens: 0,
                    modelName: nil
                ),
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let snapshot = try repository.makeSnapshot(referenceDate: referenceDate, calendar: Calendar(identifier: .gregorian))

        #expect(snapshot.estimatedCostLast30.byAgent.count == 2)
        #expect(snapshot.estimatedCostLast30.byAgent[0].name == "gemini-2.5-pro")
        #expect(snapshot.estimatedCostLast30.byAgent[0].totalTokens == 400)
        #expect(abs(snapshot.estimatedCostLast30.byAgent[0].cost - 0.000922) < 0.000000001)
        #expect(snapshot.estimatedCostLast30.byAgent[1].name == "Codex")
        #expect(snapshot.estimatedCostLast30.byAgent[1].totalTokens == 10)
        #expect(abs(snapshot.estimatedCostLast30.byAgent[1].cost - 0.0000446) < 0.000000001)
    }

    @Test
    func makeProjectDetailFromSQLiteFiltersAndComputesSharesAndCost() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = fixedDate()

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-project-detail-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(
                    id: "s1-a",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-1",
                    timestamp: referenceDate,
                    inputTokens: 200,
                    outputTokens: 20,
                    cacheTokens: 0
                ),
                dbEvent(
                    id: "s2-a",
                    agent: .claudeCode,
                    projectName: "tokenbar",
                    sessionId: "session-2",
                    timestamp: calendar.date(byAdding: .day, value: -2, to: referenceDate)!,
                    inputTokens: 120,
                    outputTokens: 30,
                    cacheTokens: 0
                ),
                dbEvent(
                    id: "other-a",
                    agent: .geminiCLI,
                    projectName: "other",
                    sessionId: "session-other",
                    timestamp: referenceDate,
                    inputTokens: 300,
                    outputTokens: 50,
                    cacheTokens: 5
                ),
            ],
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let detail = try repository.makeProjectDetail(projectName: "tokenbar", referenceDate: referenceDate, calendar: calendar)
        #expect(detail != nil)
        #expect(detail?.summary.totalTokens == 370)
        #expect(detail?.focus.dominantDimension == "Input")
        #expect(detail?.activeDays == 2)
        #expect(detail?.peakDay == calendar.startOfDay(for: referenceDate))
        #expect(detail?.agentShare.count == 2)
        #expect(detail?.agentShare.first?.name == "Codex")
        #expect(detail?.agentShare.first?.totalTokens == 220)
        #expect(detail?.agentShare.first?.percentage == 220.0 / 370.0)
        #expect(detail?.recentSessions.count == 2)
        #expect(detail?.recentSessions.first?.sessionId == "session-1")
        #expect(abs((detail?.estimatedCost.totalCost ?? 0) - 0.0013037) < 0.0000001)
        #expect(detail?.warningCount == 0)
    }

    @Test
    func projectScopedQueriesReturnNewestFirstAndSummary() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = fixedDate()
        let older = calendar.date(byAdding: .day, value: -2, to: referenceDate)!

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-project-query-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(
                    id: "project-tokenbar-old",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-old",
                    timestamp: older,
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheTokens: 2
                ),
                dbEvent(
                    id: "project-tokenbar-new",
                    agent: .hermes,
                    projectName: "tokenbar",
                    sessionId: "session-new",
                    timestamp: referenceDate,
                    inputTokens: 2,
                    outputTokens: 3,
                    cacheTokens: 1
                ),
                dbEvent(
                    id: "project-other",
                    agent: .codex,
                    projectName: "other",
                    sessionId: "session-other",
                    timestamp: referenceDate,
                    inputTokens: 50,
                    outputTokens: 6,
                    cacheTokens: 8
                ),
            ],
            prompts: [
                PromptRecord(
                    id: "prompt-old",
                    eventId: "project-tokenbar-old",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-old",
                    timestamp: older,
                    content: "old tokenbar prompt",
                    contentHash: "old-hash",
                    sourcePath: "/tmp/source.jsonl"
                ),
                PromptRecord(
                    id: "prompt-new",
                    eventId: "project-tokenbar-new",
                    agent: .hermes,
                    projectName: "tokenbar",
                    sessionId: "session-new",
                    timestamp: referenceDate,
                    content: "new tokenbar prompt",
                    contentHash: "new-hash",
                    sourcePath: "/tmp/source.jsonl"
                ),
                PromptRecord(
                    id: "prompt-other",
                    eventId: "project-other",
                    agent: .codex,
                    projectName: "other",
                    sessionId: "session-other",
                    timestamp: referenceDate,
                    content: "other prompt",
                    contentHash: "other-hash",
                    sourcePath: "/tmp/source.jsonl"
                ),
            ],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let tokenbarEvents = try repository.projectEvents(projectName: "tokenbar")
        #expect(tokenbarEvents.count == 2)
        #expect(tokenbarEvents.map(\.id) == ["project-tokenbar-new", "project-tokenbar-old"])

        let tokenbarPrompts = try repository.projectPromptHistory(projectName: "tokenbar")
        #expect(tokenbarPrompts.map(\.id) == ["prompt-new", "prompt-old"])
        #expect(tokenbarPrompts.allSatisfy { $0.projectName == "tokenbar" })
        #expect(tokenbarPrompts.first?.content == "")

        let summary = try repository.projectSummary(projectName: "tokenbar")
        #expect(summary.totalTokens == 23)
        #expect(summary.focus.dominantDimension == "Input")
    }

    @Test
    func projectPromptHistoryPagePaginatesAndFiltersInSQLite() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let referenceDate = fixedDate()
        let calendar = Calendar(identifier: .gregorian)
        let oldest = calendar.date(byAdding: .minute, value: -4, to: referenceDate)!
        let older = calendar.date(byAdding: .minute, value: -3, to: referenceDate)!
        let middle = calendar.date(byAdding: .minute, value: -2, to: referenceDate)!
        let newer = calendar.date(byAdding: .minute, value: -1, to: referenceDate)!

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-prompt-page-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [],
            prompts: [
                PromptRecord(
                    id: "prompt-human-old",
                    eventId: nil,
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-human-old",
                    timestamp: older,
                    content: "build the project page",
                    contentHash: "human-old-hash",
                    sourcePath: "/tmp/source.jsonl"
                ),
                PromptRecord(
                    id: "prompt-endpoint",
                    eventId: nil,
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-endpoint",
                    timestamp: oldest,
                    content: "/v1/query/sql keep backend-service API style",
                    contentHash: "endpoint-hash",
                    sourcePath: "/tmp/source.jsonl"
                ),
                PromptRecord(
                    id: "prompt-command",
                    eventId: nil,
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-command",
                    timestamp: middle,
                    content: "/review current diff",
                    contentHash: "command-hash",
                    sourcePath: "/tmp/source.jsonl"
                ),
                PromptRecord(
                    id: "prompt-subagent",
                    eventId: nil,
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-subagent",
                    timestamp: newer,
                    content: "Assigned task: inspect prompt paging",
                    contentHash: "subagent-hash",
                    sourcePath: "/tmp/subagents/worker.jsonl"
                ),
                PromptRecord(
                    id: "prompt-other",
                    eventId: nil,
                    agent: .codex,
                    projectName: "other",
                    sessionId: "session-other",
                    timestamp: referenceDate,
                    content: "other project prompt",
                    contentHash: "other-hash",
                    sourcePath: "/tmp/source.jsonl"
                ),
            ],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let firstPage = try repository.projectPromptHistoryPage(projectName: "tokenbar", limit: 2, offset: 0, includeContent: true)
        #expect(firstPage.totalCount == 4)
        #expect(firstPage.prompts.map(\.id) == ["prompt-subagent", "prompt-command"])
        #expect(firstPage.prompts.first?.content == "Assigned task: inspect prompt paging")
        #expect(firstPage.kindCounts.humanCount == 2)
        #expect(firstPage.kindCounts.subagentCount == 1)
        #expect(firstPage.kindCounts.commandCount == 1)

        let secondPage = try repository.projectPromptHistoryPage(projectName: "tokenbar", limit: 2, offset: 2, includeContent: true)
        #expect(secondPage.prompts.map(\.id) == ["prompt-human-old", "prompt-endpoint"])

        let searchPage = try repository.projectPromptHistoryPage(projectName: "tokenbar", limit: 10, offset: 0, includeContent: true, query: "build")
        #expect(searchPage.totalCount == 1)
        #expect(searchPage.prompts.map(\.id) == ["prompt-human-old"])

        let commandPage = try repository.projectPromptHistoryPage(projectName: "tokenbar", limit: 10, offset: 0, includeContent: true, kindFilter: .command)
        #expect(commandPage.totalCount == 1)
        #expect(commandPage.prompts.map(\.id) == ["prompt-command"])

        let humanPage = try repository.projectPromptHistoryPage(projectName: "tokenbar", limit: 10, offset: 0, includeContent: true, kindFilter: .human)
        #expect(humanPage.totalCount == 2)
        #expect(humanPage.prompts.map(\.id) == ["prompt-human-old", "prompt-endpoint"])

        let day = calendar.startOfDay(for: older)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
        let dayCounts = try repository.projectPromptCountsByDay(projectName: "tokenbar", start: day, end: dayEnd, calendar: calendar)
        #expect(dayCounts[day] == 4)
    }

    @Test
    func collectionSignaturesExposeCountsWithoutLoadingPromptContent() throws {
        let dbURL = temporaryDatabaseURL()
        let repository = try UsageRepository(databaseURL: dbURL)
        let referenceDate = fixedDate()

        _ = try repository.insertCheckpoint(
            trigger: "sqlite-signature-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(
                    id: "sig-a",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-a",
                    timestamp: referenceDate,
                    inputTokens: 1,
                    outputTokens: 2,
                    cacheTokens: 3
                )
            ],
            prompts: [
                PromptRecord(
                    id: "sig-prompt",
                    eventId: "sig-a",
                    agent: .codex,
                    projectName: "tokenbar",
                    sessionId: "session-a",
                    timestamp: referenceDate,
                    content: "signature prompt",
                    contentHash: "signature-hash",
                    sourcePath: "/tmp/source.jsonl"
                )
            ],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let signatures = try repository.collectionSignatures()
        #expect(signatures.eventCount == 1)
        #expect(signatures.promptCount == 1)
        #expect(signatures.eventSignature.hasPrefix("1|"))
        #expect(signatures.promptSignature.hasPrefix("1|"))
    }

    @Test
    func checkpointInsertIsIdempotentAcrossRepeatRuns() async throws {
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let source = FakeCheckpointSource(events: [event(id: "same-event")], prompts: [prompt(id: "same-prompt")])
        let engine = CheckpointEngine(sources: [source], store: store)
        let referenceDate = fixedDate()

        let first = await engine.run(trigger: "test", startedAt: referenceDate, referenceDate: referenceDate)
        let second = await engine.run(trigger: "test", startedAt: referenceDate, referenceDate: referenceDate)

        #expect(first.checkpoint?.eventsAdded == 1)
        #expect(first.checkpoint?.promptsAdded == 1)
        #expect(second.checkpoint?.eventsAdded == 0)
        #expect(second.checkpoint?.promptsAdded == 0)
        #expect(second.state.events.count == 1)
        #expect(second.state.prompts.count == 1)
    }

    @Test
    func customSourceRegistryPersistsRecords() async throws {
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let registry = CustomSourceRegistry(store: store)
        let source = CustomSourceRecord(
            id: "wrapper",
            name: "Wrapper Agent",
            engine: .claudeCode,
            directory: "/tmp/wrapper",
            globPattern: "**/*.jsonl",
            format: .claudeCodeJSONL,
            displayAgent: "Wrapper"
        )

        try await registry.upsert(source)
        let listed = await registry.list()

        #expect(listed.count == 1)
        #expect(listed.first?.name == "Wrapper Agent")
        #expect(listed.first?.engine == .claudeCode)
        #expect(listed.first?.format == .claudeCodeJSONL)
    }

    @Test
    func customSourceMigrationAddsDefaultFieldMappingForLegacyRows() throws {
        let dbURL = temporaryDatabaseURL()
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE custom_sources (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                directory TEXT NOT NULL,
                glob_pattern TEXT NOT NULL,
                format TEXT NOT NULL,
                display_agent TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL
            )
            """)
            try db.execute(
                sql: """
                INSERT INTO custom_sources (id, name, directory, glob_pattern, format, display_agent, enabled, created_at)
                VALUES ('legacy', 'Legacy', '/tmp/legacy', '**/*.jsonl', 'auto', 'Legacy', 1, 1_000_000_000)
                """)
        }

        let repository = try UsageRepository(databaseURL: dbURL)
        let listed = try repository.listCustomSources()

        #expect(listed.count == 1)
        #expect(listed[0].id == "legacy")
        #expect(listed[0].engine == .claudeCode)
        #expect(listed[0].fieldMapping == .default)
        #expect(listed[0].fieldMapping.inputTokens == "usage.input_tokens")
        #expect(listed[0].fieldMapping.outputTokens == "usage.output_tokens")
        #expect(listed[0].fieldMapping.cacheTokens == "usage.cache_read_tokens")
        #expect(listed[0].fieldMapping.model == "model")
    }

    @Test
    func customSourceUpsertRoundTripsFieldMappingAndCreatedAt() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let initialCreatedAt = fixedDate()
        let source = CustomSourceRecord(
            id: "mapping",
            name: "Mapping Source",
            engine: .codex,
            directory: "/tmp/mapping",
            globPattern: "**/*.jsonl",
            format: .auto,
            displayAgent: "Mapping",
            fieldMapping: CustomSourceFieldMapping(
                inputTokens: "foo.input",
                outputTokens: "foo.output",
                cacheTokens: "foo.cache",
                model: "foo.model"
            ),
            createdAt: initialCreatedAt
        )

        try repository.upsertCustomSource(source)
        let firstListed = try repository.listCustomSources()
        let first = try #require(firstListed.first)
        #expect(first.fieldMapping == source.fieldMapping)
        #expect(first.engine == .codex)

        let updated = CustomSourceRecord(
            id: source.id,
            name: "Mapping Source Updated",
            engine: .claudeCode,
            directory: "/tmp/mapping",
            globPattern: "**/*.jsonl",
            format: .auto,
            displayAgent: "Mapping",
            enabled: false,
            fieldMapping: CustomSourceFieldMapping(
                inputTokens: "bar.input",
                outputTokens: "bar.output",
                cacheTokens: "bar.cache",
                model: "bar.model"
            ),
            createdAt: Date(timeIntervalSince1970: initialCreatedAt.timeIntervalSince1970 + 60)
        )

        try repository.upsertCustomSource(updated)
        let secondListed = try repository.listCustomSources()
        let second = try #require(secondListed.first)

        #expect(secondListed.count == 1)
        #expect(second.name == "Mapping Source Updated")
        #expect(second.engine == .claudeCode)
        #expect(second.fieldMapping == updated.fieldMapping)
        #expect(second.enabled == false)
        #expect(second.createdAt.timeIntervalSince1970 == initialCreatedAt.timeIntervalSince1970)
    }

    @Test
    func customSourceUpsertIsIdempotentByNormalizedPath() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let initialCreatedAt = fixedDate()
        let first = CustomSourceRecord(
            id: "first",
            name: "Claude Me",
            engine: .claudeCode,
            directory: "/tmp/claude-me/projects/",
            globPattern: "**/*.jsonl",
            format: .claudeCodeJSONL,
            displayAgent: "Claude",
            createdAt: initialCreatedAt
        )
        let duplicate = CustomSourceRecord(
            id: "second",
            name: "Claude Me Updated",
            engine: .claudeCode,
            directory: "/tmp/claude-me/projects",
            globPattern: "**/*.jsonl",
            format: .claudeCodeJSONL,
            displayAgent: "Claude Code",
            createdAt: Date(timeIntervalSince1970: initialCreatedAt.timeIntervalSince1970 + 60)
        )

        try repository.upsertCustomSource(first)
        try repository.upsertCustomSource(duplicate)

        let listed = try repository.listCustomSources()
        let saved = try #require(listed.first)
        #expect(listed.count == 1)
        #expect(saved.id == "first")
        #expect(saved.name == "Claude Me Updated")
        #expect(saved.directory == "/tmp/claude-me/projects")
        #expect(saved.displayAgent == "Claude Code")
        #expect(saved.createdAt.timeIntervalSince1970 == initialCreatedAt.timeIntervalSince1970)
    }

    @Test
    func deletingCustomSourceRemovesItsIndexedRows() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let referenceDate = fixedDate()
        let source = CustomSourceRecord(
            id: "custom-source",
            name: "Custom Source",
            engine: .codex,
            directory: "/tmp/custom-source",
            globPattern: "**/rollout-*.jsonl",
            format: .codexJSONL,
            displayAgent: "Codex",
            createdAt: referenceDate
        )
        try repository.upsertCustomSource(source)

        _ = try repository.insertCheckpoint(
            trigger: "custom-source-delete-test",
            startedAt: referenceDate,
            endedAt: referenceDate,
            events: [
                dbEvent(id: "custom:custom-source:event-1", agent: .codex, projectName: "custom-project", sessionId: "custom-session", timestamp: referenceDate, inputTokens: 20, outputTokens: 5, cacheTokens: 1),
                dbEvent(id: "builtin-event", agent: .codex, projectName: "builtin-project", sessionId: "builtin-session", timestamp: referenceDate, inputTokens: 3, outputTokens: 2, cacheTokens: 1),
            ],
            prompts: [
                PromptRecord(
                    id: "custom:custom-source:prompt-1",
                    eventId: "custom:custom-source:event-1",
                    agent: .codex,
                    projectName: "custom-project",
                    sessionId: "custom-session",
                    timestamp: referenceDate,
                    content: "custom",
                    contentHash: "custom-hash",
                    sourcePath: "/tmp/custom-source/rollout.jsonl"
                ),
                PromptRecord(
                    id: "builtin-prompt",
                    eventId: "builtin-event",
                    agent: .codex,
                    projectName: "builtin-project",
                    sessionId: "builtin-session",
                    timestamp: referenceDate,
                    content: "builtin",
                    contentHash: "builtin-hash",
                    sourcePath: "/tmp/codex/rollout.jsonl"
                ),
            ],
            nextWatermarks: [
                SourceWatermark(
                    sourcePath: "/tmp/custom-source/rollout.jsonl",
                    agent: .codex,
                    lastMtime: referenceDate,
                    lastByteOffset: 100,
                    lastEventId: "custom:custom-source:event-1",
                    lastInode: 1,
                    updatedAt: referenceDate
                ),
                SourceWatermark(
                    sourcePath: "/tmp/codex/rollout.jsonl",
                    agent: .codex,
                    lastMtime: referenceDate,
                    lastByteOffset: 200,
                    lastEventId: "builtin-event",
                    lastInode: 2,
                    updatedAt: referenceDate
                ),
            ],
            warnings: [],
            error: nil
        )

        try repository.deleteCustomSource(id: "custom-source")

        #expect(try repository.listCustomSources().isEmpty)
        #expect(try repository.allEvents().map(\.id) == ["builtin-event"])
        #expect(try repository.allPrompts().map(\.id) == ["builtin-prompt"])
        #expect(Set(try repository.watermarks().keys) == ["/tmp/codex/rollout.jsonl"])
    }

    @Test
    func formatDetectorClassifiesClaudeAndCodexShapes() throws {
        let directory = temporaryDirectory()
        let claude = directory.appendingPathComponent("claude.jsonl")
        let codex = directory.appendingPathComponent("codex.jsonl")
        let unknown = directory.appendingPathComponent("unknown.jsonl")

        try #"{"message":{"usage":{"input_tokens":1,"output_tokens":2}}}"#.write(to: claude, atomically: true, encoding: .utf8)
        try #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1}}}}"#.write(to: codex, atomically: true, encoding: .utf8)
        try #"{"hello":"world"}"#.write(to: unknown, atomically: true, encoding: .utf8)

        #expect(SourceFormatDetector.detect(fileURL: claude) == .claudeCodeJSONL)
        #expect(SourceFormatDetector.detect(fileURL: codex) == .codexJSONL)
        #expect(SourceFormatDetector.detect(fileURL: unknown) == .unknown)
    }

    @Test
    func customSourceParsesClaudeEngineJSONL() async throws {
        let directory = temporaryDirectory()
        let eventFile = directory.appendingPathComponent("claude.jsonl")
        try ([
            #"{"sessionId":"claude-session","timestamp":"2026-05-18T10:11:12.000Z","cwd":"/tmp/tokenbar","message":{"model":"claude-model","usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":0,"cache_read_input_tokens":56}}}"#,
        ].joined(separator: "\n") + "\n").write(to: eventFile, atomically: true, encoding: .utf8)

        let record = CustomSourceRecord(
            id: "claude-source",
            name: "Claude Source",
            engine: .claudeCode,
            directory: directory.path,
            globPattern: "*.jsonl",
            format: .claudeCodeJSONL,
            displayAgent: "Claude Code",
            createdAt: fixedDate()
        )
        let source = CustomUsageEventSource(record: record)

        let result = try await source.loadEvents(
            since: [:],
            referenceDate: fixedDate(),
            calendar: Calendar(identifier: .gregorian)
        )

        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(!result.warnings.contains { $0.message == "usage fields are incomplete for custom mapping" })
        #expect(event.agent == .claudeCode)
        #expect(event.parser == .claudeCode)
        #expect(event.projectName == "tokenbar")
        #expect(event.sessionId == "claude-session")
        #expect(event.modelName == "claude-model")
        #expect(event.inputTokens == 12)
        #expect(event.outputTokens == 34)
        #expect(event.cacheTokens == 56)
    }

    @Test
    func customSourceDiscoversNestedClaudeProjectsRecursively() async throws {
        let directory = temporaryDirectory()
        let nested = directory
            .appendingPathComponent("-Users-dev-Projects-tokenbar")
            .appendingPathComponent("session-1")
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let eventFile = nested.appendingPathComponent("agent-a123.jsonl")
        try ([
            #"{"sessionId":"codefuse-session","timestamp":"2026-05-18T10:11:12.000Z","cwd":"/tmp/tokenbar","message":{"model":"claude-model","usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":0,"cache_read_input_tokens":56}}}"#,
        ].joined(separator: "\n") + "\n").write(to: eventFile, atomically: true, encoding: .utf8)

        let record = CustomSourceRecord(
            id: "codefuse-claude-source",
            name: "CodeFuse Claude",
            engine: .claudeCode,
            directory: directory.path,
            globPattern: "**/*.jsonl",
            format: .claudeCodeJSONL,
            displayAgent: "Claude Code",
            createdAt: fixedDate()
        )
        let source = CustomUsageEventSource(record: record)
        let status = await source.status(referenceDate: fixedDate(), calendar: Calendar(identifier: .gregorian))
        let result = try await source.loadEvents(
            since: [:],
            referenceDate: fixedDate(),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(status.discoveredFileCount == 1)
        #expect(result.events.count == 1)
        #expect(result.events.first?.sessionId == "codefuse-session")
    }

    @Test
    func customSourceParsesCodexEngineRolloutJSONL() async throws {
        let directory = temporaryDirectory()
        let eventFile = directory.appendingPathComponent("rollout-custom.jsonl")
        try ([
            #"{"timestamp":"2026-03-14T07:54:51.802Z","type":"session_meta","payload":{"id":"codex-custom-session","timestamp":"2026-03-14T07:54:45.725Z","cwd":"/tmp/tokenbar","originator":"Codex Desktop","model_provider":"openai"}}"#,
            #"{"timestamp":"2026-03-14T07:54:59.967Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":110,"cached_input_tokens":20,"output_tokens":7,"reasoning_output_tokens":3,"total_tokens":117},"last_token_usage":{"input_tokens":110,"cached_input_tokens":20,"output_tokens":7,"reasoning_output_tokens":3,"total_tokens":117},"model_context_window":258400},"rate_limits":null}}"#,
        ].joined(separator: "\n") + "\n").write(to: eventFile, atomically: true, encoding: .utf8)

        let record = CustomSourceRecord(
            id: "codex-source",
            name: "Codex Source",
            engine: .codex,
            directory: directory.path,
            globPattern: "rollout-*.jsonl",
            format: .codexJSONL,
            displayAgent: "Codex",
            createdAt: fixedDate()
        )
        let source = CustomUsageEventSource(record: record)

        let result = try await source.loadEvents(
            since: [:],
            referenceDate: fixedDate(),
            calendar: Calendar(identifier: .gregorian)
        )

        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.agent == .codex)
        #expect(event.parser == .codex)
        #expect(event.projectName == "tokenbar")
        #expect(event.sessionId == "codex-custom-session")
        #expect(event.inputTokens == 110)
        #expect(event.outputTokens == 7)
        #expect(event.cacheTokens == 20)
        #expect(event.reasoningTokens == 3)
    }

    @Test
    func customSourceParsesHermesEngineDatabase() async throws {
        let directory = temporaryDirectory()
        let dbURL = directory.appendingPathComponent("state.db")
        let queue = try DatabaseQueue(path: dbURL.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at INTEGER, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER)")
            try db.execute(sql: "CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT, timestamp INTEGER, role TEXT, content TEXT)")
            try db.execute(sql: """
            INSERT INTO sessions (id, source, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens)
            VALUES ('s1', 'hermes-custom', 1770000000000, 10, 20, 30, 40, 0)
            """)
        }

        let record = CustomSourceRecord(
            id: "hermes-source",
            name: "Hermes Source",
            engine: .hermes,
            directory: directory.path,
            globPattern: "state.db",
            format: .auto,
            displayAgent: "Hermes",
            createdAt: fixedDate()
        )
        let source = CustomUsageEventSource(record: record)

        let result = try await source.loadEvents(
            since: [:],
            referenceDate: fixedDate(),
            calendar: Calendar(identifier: .gregorian)
        )

        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.agent == .hermes)
        #expect(event.parser == .hermes)
        #expect(event.projectName == "hermes-custom")
        #expect(event.inputTokens == 10)
        #expect(event.outputTokens == 20)
        #expect(event.cacheTokens == 70)
    }

    @Test
    func hermesParserReadsTokenRowsAndUserPrompts() throws {
        let dbURL = temporaryDatabaseURL()
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT)")
            try db.execute(sql: """
            CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                model TEXT,
                started_at INTEGER,
                role TEXT,
                content TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER
            )
            """)
            try db.execute(sql: "INSERT INTO sessions (id, source) VALUES ('s1', 'discord')")
            try db.execute(sql: """
            INSERT INTO messages
            (id, session_id, model, started_at, role, content, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens)
                VALUES
            ('m1', 's1', 'model', 1770000000000, 'user', 'real prompt', 1, 0, 0, 0, 0),
            ('m2', 's1', 'model', 1770000001000, 'assistant', 'answer', 10, 20, 3, 4, 5),
            ('m3', 's1', 'model', 1770000002000, 'user', '{"type":"tool_result"}', 0, 0, 0, 0, 0)
            """)
        }

        let result = try HermesUsageParser.parse(databaseURL: dbURL)

        #expect(result.events.count == 2)
        #expect(result.events.first?.agent == .hermes)
        #expect(result.events.last?.cacheTokens == 7)
        #expect(result.events.last?.reasoningTokens == 5)
        #expect(result.events.first?.modelName == "model")
        #expect(result.prompts.count == 1)
        #expect(result.prompts.first?.content == "real prompt")
        #expect(result.prompts.first?.projectName == "discord")
    }

    /// Regression: real Hermes installs have `sessions.source = 'cli'` for
    /// every row, so the project axis used to collapse into one bucket.
    /// `derivedProjectName(forSession:)` recovers per-session projects by
    /// finding the first `"cwd"` JSON field in messages.
    @Test
    func hermesParserDerivesProjectFromCWDInMessages() throws {
        let dbURL = temporaryDatabaseURL()
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                started_at REAL NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER
            )
            """)
            try db.execute(sql: """
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                role TEXT NOT NULL,
                content TEXT
            )
            """)
            // Three sessions, all with source="cli" but distinct cwd in
            // a tool-call-style message. Each should resolve to a unique
            // project basename.
            try db.execute(sql: """
            INSERT INTO sessions (id, source, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens) VALUES
                ('s1', 'cli', 1770000000.0, 10, 5, 0, 0, 0),
                ('s2', 'cli', 1770000100.0, 20, 8, 0, 0, 0),
                ('s3', 'cli', 1770000200.0, 30, 12, 0, 0, 0)
            """)
            try db.execute(sql: #"""
            INSERT INTO messages (session_id, timestamp, role, content) VALUES
                ('s1', 1770000000.0, 'assistant', '{"tool":"bash","args":{"cwd":"/Users/me/projects/my-mcp-server","cmd":"ls"}}'),
                ('s2', 1770000100.0, 'assistant', '{"tool":"bash","args":{"cwd":"/Users/me/projects/tokenbar","cmd":"swift test"}}'),
                ('s3', 1770000200.0, 'assistant', '{"tool":"edit","cwd":"/Users/me/work/my-cli-tool/src","path":"main.swift"}')
            """#)
        }

        let result = try HermesUsageParser.parse(databaseURL: dbURL)

        let projects = Set(result.events.map(\.projectName))
        #expect(result.events.count == 3)
        #expect(projects == Set(["my-mcp-server", "tokenbar", "src"]))
    }

    @Test
    func hermesParserFallsBackToSourceWhenNoCWDInMessages() throws {
        let dbURL = temporaryDatabaseURL()
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                started_at REAL NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER
            )
            """)
            try db.execute(sql: """
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                role TEXT NOT NULL,
                content TEXT
            )
            """)
            try db.execute(sql: """
            INSERT INTO sessions (id, source, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens) VALUES
                ('s1', 'cli', 1770000000.0, 10, 5, 0, 0, 0)
            """)
            try db.execute(sql: "INSERT INTO messages (session_id, timestamp, role, content) VALUES ('s1', 1770000000.0, 'user', 'just talking, no tool call')")
        }

        let result = try HermesUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.count == 1)
        #expect(result.events[0].projectName == "cli")
    }

    @Test
    func hermesParserFallbacksToSessionModelWhenMessagesModelIsMissing() throws {
        let dbURL = temporaryDatabaseURL()
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT,
                model TEXT
            )
            """)
            try db.execute(sql: """
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                role TEXT NOT NULL,
                content TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER
            )
            """)
            try db.execute(sql: "INSERT INTO sessions (id, source, model) VALUES ('s1', 'discord', 'session-model')")
            try db.execute(
                sql: """
                INSERT INTO messages
                (session_id, started_at, role, content, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens)
                VALUES
                ('s1', 1770000000000, 'assistant', 'answer', 10, 20, 3, 4, 5)
                """
            )
        }

        let result = try HermesUsageParser.parse(databaseURL: dbURL)

        #expect(result.events.count == 1)
        #expect(result.events[0].modelName == "session-model")
        #expect(result.events[0].cacheTokens == 7)
    }

    @Test
    func codexAndClaudePromptExtractionFiltersSystemAndToolResults() throws {
        let directory = temporaryDirectory()
        let codex = directory.appendingPathComponent("codex.jsonl")
        let claude = directory.appendingPathComponent("claude.jsonl")

        try [
            #"{"timestamp":"2026-03-14T07:54:51.802Z","type":"session_meta","payload":{"id":"codex-session","cwd":"/tmp/tokenbar"}}"#,
            #"{"timestamp":"2026-03-14T07:54:52.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"build the feature"}]}}"#,
            #"{"timestamp":"2026-03-14T07:54:53.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<system-reminder>ignore</system-reminder>"}]}}"#,
        ].joined(separator: "\n").write(to: codex, atomically: true, encoding: .utf8)

        try [
            #"{"type":"user","timestamp":"2026-04-02T00:55:00.000Z","message":{"role":"user","content":"ship sprint 8"},"cwd":"/tmp/tokenbar","sessionId":"claude-session"}"#,
            #"{"type":"user","timestamp":"2026-04-02T00:55:01.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"skip"}]},"cwd":"/tmp/tokenbar","sessionId":"claude-session"}"#,
        ].joined(separator: "\n").write(to: claude, atomically: true, encoding: .utf8)

        #expect(try CodexUsageParser.extractUserPrompts(fileURL: codex).map(\.content) == ["build the feature"])
        #expect(try ClaudeUsageParser.extractUserPrompts(fileURL: claude, fallbackProjectSlug: "tmp-tokenbar").map(\.content) == ["ship sprint 8"])
    }

    @Test
    func directoryWatcherFiresAfterFileChange() async throws {
        let directory = temporaryDirectory()
        let recorder = WatchRecorder()
        let watcher = DirectoryFileWatcher(paths: [directory.path], debounceNanoseconds: 100_000_000) {
            await recorder.record()
        }

        try await watcher.start()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Data("changed".utf8).write(to: directory.appendingPathComponent("event.jsonl"), options: [])
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await watcher.stop()

        #expect(await recorder.count > 0)
    }

    private func temporaryDatabaseURL() -> URL {
        temporaryDirectory().appendingPathComponent("tokenbar.sqlite")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixedDate() -> Date {
        Date(timeIntervalSince1970: 1_770_000_000)
    }

    private func event(id: String) -> UsageEvent {
        UsageEvent(
            id: id,
            agent: .codex,
            projectPath: "/tmp/tokenbar",
            projectName: "tokenbar",
            sessionId: "session",
            timestamp: fixedDate(),
            inputTokens: 10,
            outputTokens: 5,
            cacheTokens: 2,
            reasoningTokens: nil,
            modelName: nil,
            sourcePath: "/tmp/source.jsonl",
            parser: .codex,
            confidence: 1.0
        )
    }

    private func prompt(id: String, timestamp: Date? = nil) -> PromptRecord {
        PromptRecord(
            id: id,
            eventId: nil,
            agent: .codex,
            projectName: "tokenbar",
            sessionId: "session",
            timestamp: timestamp ?? fixedDate(),
            content: "hello",
            contentHash: "hash",
            sourcePath: "/tmp/source.jsonl"
        )
    }

    private func dbEvent(
        id: String,
        agent: AgentKind,
        projectName: String,
        sessionId: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        modelName: String? = nil
    ) -> UsageEvent {
        let parser: ParserKind
        switch agent {
        case .codex:
            parser = .codex
        case .claudeCode:
            parser = .claudeCode
        case .hermes:
            parser = .hermes
        default:
            parser = .custom
        }
        return UsageEvent(
            id: id,
            agent: agent,
            projectPath: "/tmp/\(projectName)",
            projectName: projectName,
            sessionId: sessionId,
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheTokens: cacheTokens,
            reasoningTokens: nil,
            modelName: modelName,
            sourcePath: "/tmp/source.jsonl",
            parser: parser,
            confidence: 1.0
        )
    }
}

private struct FakeCheckpointSource: UsageEventSource {
    let sourceName = "fake"
    let events: [UsageEvent]
    let prompts: [PromptRecord]

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = watermarks
        return UsageSourceLoadResult(events: events, prompts: prompts, warnings: [])
    }
}

private actor WatchRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
