import Foundation
import GRDB
import Testing
@testable import TokenBarCore

struct Sprint8StorageTests {
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
            directory: "/tmp/wrapper",
            globPattern: "**/*.jsonl",
            format: .claudeCodeJSONL,
            displayAgent: "Wrapper"
        )

        try await registry.upsert(source)
        let listed = await registry.list()

        #expect(listed.count == 1)
        #expect(listed.first?.name == "Wrapper Agent")
        #expect(listed.first?.format == .claudeCodeJSONL)
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
