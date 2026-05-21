import Foundation
import GRDB
import Testing
@testable import TokenBarCore

struct Sprint9IncrementalTests {
    @Test
    func readStrategyCoversWatermarkTruthTable() throws {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let watermark = SourceWatermark(
            sourcePath: "/tmp/session.jsonl",
            agent: .codex,
            lastMtime: now,
            lastByteOffset: 10,
            lastEventId: "event-1",
            lastInode: 11,
            updatedAt: now
        )

        #expect(JSONLIncrementalReader.decide(current: FileFingerprint(inode: 11, size: 20, mtime: now), watermark: nil) == .fullReparse(reason: "no watermark"))
        #expect(JSONLIncrementalReader.decide(current: FileFingerprint(inode: 12, size: 20, mtime: now), watermark: watermark) == .fullReparse(reason: "inode changed 11 -> 12"))
        #expect(JSONLIncrementalReader.decide(current: FileFingerprint(inode: 11, size: 5, mtime: now), watermark: watermark) == .fullReparse(reason: "size shrink 10 -> 5"))
        #expect(JSONLIncrementalReader.decide(current: FileFingerprint(inode: 11, size: 20, mtime: now.addingTimeInterval(-10)), watermark: watermark) == .fullReparse(reason: "mtime regress"))
        #expect(JSONLIncrementalReader.decide(current: FileFingerprint(inode: 11, size: 20, mtime: now), watermark: watermark) == .incremental(fromByteOffset: 10))
    }

    @Test
    func jsonlReaderReadsOnlyAppendedCleanLinesAndRewindsPartialTrailingLine() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("rollout-test.jsonl")
        try writeLines(["{\"a\":1}"], to: fileURL, trailingNewline: true)

        let first = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Codex", agent: .codex, watermark: nil)
        #expect(first.lines.map(\.text) == ["{\"a\":1}"])

        try append("{\"b\":2}\n{\"partial\":", to: fileURL)
        let second = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Codex", agent: .codex, watermark: first.nextWatermark)

        #expect(second.lines.map(\.text) == ["{\"b\":2}"])
        #expect(second.warnings.contains { $0.message.contains("partial trailing JSONL line") })
        #expect(second.nextWatermark.lastByteOffset < Int64((try Data(contentsOf: fileURL)).count))
    }

    @Test
    func jsonlReaderForcesFullReparseOnTruncateAndRenameRecreate() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("session.jsonl")
        try writeLines(["{\"a\":1}", "{\"b\":2}"], to: fileURL, trailingNewline: true)
        let first = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Claude Code", agent: .claudeCode, watermark: nil)

        let truncateHandle = try FileHandle(forWritingTo: fileURL)
        try truncateHandle.truncate(atOffset: 0)
        try truncateHandle.close()
        let truncated = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Claude Code", agent: .claudeCode, watermark: first.nextWatermark)
        #expect(truncated.forcedFullReparseReason?.contains("size shrink") == true)

        try writeLines(["{\"c\":3}"], to: fileURL, trailingNewline: true)
        let afterTruncate = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Claude Code", agent: .claudeCode, watermark: truncated.nextWatermark)
        let rotatedURL = directory.appendingPathComponent("session.jsonl.1")
        try FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        try writeLines(["{\"d\":4}"], to: fileURL, trailingNewline: true)
        let rotated = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Claude Code", agent: .claudeCode, watermark: afterTruncate.nextWatermark)
        #expect(rotated.forcedFullReparseReason?.contains("inode changed") == true)
    }

    @Test
    func codexSourceSecondCheckpointIsNoOpThenAppendAddsOneEvent() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 8))!
        let root = codexFixtureRoot(referenceDate: referenceDate)
        let fileURL = root
            .appendingPathComponent("2026")
            .appendingPathComponent("05")
            .appendingPathComponent("14")
            .appendingPathComponent("rollout-test.jsonl")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeLines([
            #"{"timestamp":"2026-05-14T00:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/tokenbar"}}"#,
            tokenCountLine(timestamp: "2026-05-14T00:01:00.000Z", input: 10, cache: 1, output: 2),
        ], to: fileURL, trailingNewline: true)

        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let source = CodexUsageEventSource(rootPath: root.path, daysBack: 2)
        let engine = CheckpointEngine(sources: [source], store: store)

        let first = await engine.run(trigger: "test", startedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)
        let second = await engine.run(trigger: "test", startedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)
        try append(tokenCountLine(timestamp: "2026-05-14T00:02:00.000Z", input: 20, cache: 2, output: 3) + "\n", to: fileURL)
        let third = await engine.run(trigger: "test", startedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)

        #expect(first.checkpoint?.eventsAdded == 1)
        #expect(second.checkpoint?.eventsAdded == 0)
        #expect(second.checkpoint?.promptsAdded == 0)
        #expect(third.checkpoint?.eventsAdded == 1)
        #expect(third.state.events.count == 2)
    }

    @Test
    func hermesSessionAggregateIncrementalDoesNotReemitRows() async throws {
        let dbURL = temporaryDatabaseURL()
        try seedHermes(dbURL: dbURL, sessions: [("s1", 1_770_000_000_000, 10)])
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let source = HermesUsageEventSource(rootPath: dbURL.path)
        let engine = CheckpointEngine(sources: [source], store: store)
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        let first = await engine.run(trigger: "hermes", startedAt: now, referenceDate: now)
        try insertHermesSession(dbURL: dbURL, id: "s2", startedAt: 1_770_000_001_000, input: 20)
        let second = await engine.run(trigger: "hermes", startedAt: now, referenceDate: now)
        let third = await engine.run(trigger: "hermes", startedAt: now, referenceDate: now)

        #expect(first.checkpoint?.eventsAdded == 1)
        #expect(second.checkpoint?.eventsAdded == 1)
        #expect(third.checkpoint?.eventsAdded == 0)
        #expect(third.state.events.count == 2)
    }

    @Test
    func recursiveWatcherFiresForDeepPathWriteAndLateRootCreation() async throws {
        let root = temporaryDirectory().appendingPathComponent("missing-root")
        let recorder = WatchRecorder()
        let watcher = RecursiveFSEventsWatcher(
            paths: [root.path],
            debounceNanoseconds: 100_000_000,
            missingRootPollNanoseconds: 100_000_000
        ) {
            await recorder.record()
        }

        try await watcher.start()
        let deep = root.appendingPathComponent("2026/05/14")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        try "line\n".write(to: deep.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 600_000_000)
        await watcher.stop()

        #expect(await recorder.count > 0)
    }

    @Test
    func checkpointActorCollapsesConcurrentTriggersIntoOneFollowupRun() async throws {
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let source = SlowWatermarkedSource()
        let engine = CheckpointEngine(sources: [source], store: store)
        let now = Date(timeIntervalSince1970: 1_770_000_000)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = await engine.trigger("trigger-\(index)", startedAt: now, referenceDate: now)
                }
            }
        }

        let state = await store.state(referenceDate: now)
        #expect(state.lastCheckpoint?.id == 2)
    }

    private func codexFixtureRoot(referenceDate: Date) -> URL {
        _ = referenceDate
        return temporaryDirectory()
    }

    private func temporaryDatabaseURL() -> URL {
        temporaryDirectory().appendingPathComponent("tokenbar.sqlite")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-sprint9-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeLines(_ lines: [String], to url: URL, trailingNewline: Bool) throws {
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func tokenCountLine(timestamp: String, input: Int, cache: Int, output: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cache),"output_tokens":\#(output),"reasoning_output_tokens":0}}}}"#
    }

    private func seedHermes(dbURL: URL, sessions: [(String, Int64, Int)]) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                started_at REAL NOT NULL,
                input_tokens INTEGER DEFAULT 0,
                output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0,
                cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0
            )
            """)
            try db.execute(sql: """
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT,
                timestamp REAL NOT NULL
            )
            """)
        }
        for session in sessions {
            try insertHermesSession(dbURL: dbURL, id: session.0, startedAt: session.1, input: session.2)
        }
    }

    private func insertHermesSession(dbURL: URL, id: String, startedAt: Int64, input: Int) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (id, source, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens) VALUES (?, 'cli', ?, ?, 1, 2, 3, 0)",
                arguments: [id, startedAt, input]
            )
            try db.execute(
                sql: "INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, 'user', 'prompt', ?)",
                arguments: [id, startedAt]
            )
        }
    }
}

private actor WatchRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private struct SlowWatermarkedSource: UsageEventSource {
    let sourceName = "slow"

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        try await Task.sleep(nanoseconds: 150_000_000)
        return UsageSourceLoadResult(events: [], prompts: [], nextWatermarks: [
            SourceWatermark(
                sourcePath: "/tmp/slow",
                agent: .custom,
                lastMtime: referenceDate,
                lastByteOffset: 0,
                lastEventId: nil,
                lastInode: 1,
                updatedAt: referenceDate
            ),
        ], warnings: [])
    }
}
