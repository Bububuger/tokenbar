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

    /// Regression: a persisted `lastMtime` rounded above the real file mtime
    /// made `decide` report "mtime regress" on every checkpoint for files
    /// whose mtime carries a sub-millisecond fraction ≥0.5ms.
    @Test
    func persistedWatermarkMtimeNeverLeadsRealMtime() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for (index, fractionMs) in [(0, 0.6), (1, 0.4)] {
            let realMtime = Date(timeIntervalSince1970: 1_700_000_000.123 + fractionMs / 1_000)
            let path = "/tmp/mtime-\(index).jsonl"
            _ = try repository.insertCheckpoint(
                trigger: "test",
                startedAt: now,
                endedAt: now,
                events: [],
                prompts: [],
                nextWatermarks: [SourceWatermark(
                    sourcePath: path,
                    agent: .codex,
                    lastMtime: realMtime,
                    lastByteOffset: 10,
                    lastEventId: nil,
                    lastInode: 11,
                    updatedAt: now
                )],
                warnings: [],
                error: nil
            )

            let stored = try #require(try repository.watermark(for: path))
            #expect(stored.lastMtime <= realMtime)
            let current = FileFingerprint(inode: 11, size: 20, mtime: realMtime)
            #expect(JSONLIncrementalReader.decide(current: current, watermark: stored) == .incremental(fromByteOffset: 10))
        }
    }

    /// Upgrade path: old `.rounded()` watermarks may force one mtime-regress
    /// reparse; after the first successful floored checkpoint, further runs stay
    /// incremental with stable event ids / token totals and zero duplicate inserts.
    @Test
    func oldRoundedWatermarkUpgradeReparsesAtMostOnce() async throws {
        DiscoveryCache.reset()
        let root = temporaryDirectory()
        let dbURL = root.appendingPathComponent("tokenbar.sqlite")
        let repository = try UsageRepository(databaseURL: dbURL)
        let now = Date(timeIntervalSince1970: 1_700_000_100)

        // Two session files: ≥0.5ms fraction (old rounded watermark leads) and
        // <0.5ms (old rounded equals floor). Fixed content + trailing partial.
        let specs: [(name: String, fractionMs: Double, eventID: String, input: Int, output: Int)] = [
            ("hi-frac", 0.6, "evt-hi", 10, 4),
            ("lo-frac", 0.4, "evt-lo", 6, 2),
        ]

        var seededEvents: [UsageEvent] = []
        var cleanOffsets: [String: Int64] = [:]
        var realMtimes: [String: Date] = [:]

        for spec in specs {
            let fileURL = root.appendingPathComponent("\(spec.name).jsonl")
            let complete = #"{"id":"\#(spec.eventID)","timestamp":1700000100000,"input_tokens":\#(spec.input),"output_tokens":\#(spec.output)}"# + "\n"
            let partial = #"{"id":"partial","input_tokens":"#
            try (complete + partial).write(to: fileURL, atomically: true, encoding: .utf8)
            let desiredMtime = Date(timeIntervalSince1970: 1_700_000_000.123 + spec.fractionMs / 1_000)
            try FileManager.default.setAttributes([.modificationDate: desiredMtime], ofItemAtPath: fileURL.path)
            let fingerprint = try JSONLIncrementalReader.fingerprint(at: fileURL.path)
            realMtimes[fileURL.path] = fingerprint.mtime
            cleanOffsets[fileURL.path] = Int64(complete.utf8.count)

            let parsed = AntigravityUsageParser.parse(
                lines: [JSONLLineRecord(text: String(complete.dropLast()), lineNumber: 1, startOffset: 0, endOffset: Int64(complete.utf8.count - 1))],
                fileURL: fileURL
            )
            #expect(parsed.events.count == 1)
            seededEvents.append(contentsOf: parsed.events)
        }

        // Synthetic Codex / Devin / Grok rows must survive the upgrade reparses.
        let preserved: [UsageEvent] = [
            makeSyntheticEvent(id: "preserve-codex", agent: .codex, parser: .codex, input: 1, output: 1),
            makeSyntheticEvent(id: "preserve-devin", agent: .devin, parser: .devin, input: 2, output: 2),
            makeSyntheticEvent(id: "preserve-grok", agent: .grok, parser: .grok, input: 3, output: 3),
        ]
        let allSeeded = seededEvents + preserved
        let seedSummary = try repository.insertCheckpoint(
            trigger: "seed",
            startedAt: now,
            endedAt: now,
            events: allSeeded,
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )
        #expect(seedSummary.eventsAdded == allSeeded.count)

        // Install legacy rounded watermarks (ceiling-ish) as a prior version would.
        let queue = try DatabaseQueue(path: dbURL.path)
        var expectedFirstPassRegressFiles = 0
        for spec in specs {
            let fileURL = root.appendingPathComponent("\(spec.name).jsonl")
            let fingerprint = try JSONLIncrementalReader.fingerprint(at: fileURL.path)
            let realMtime = fingerprint.mtime
            let roundedMs = Int64((realMtime.timeIntervalSince1970 * 1_000).rounded())
            let flooredMs = realMtime.tokenBarMillisecondsSince1970Floor
            // If the filesystem dropped sub-ms precision, synthesize the old
            // leading watermark for the ≥0.5ms case so the upgrade path still
            // exercises a one-time mtime-regress reparse.
            let legacyMs: Int64
            if spec.fractionMs >= 0.5 {
                legacyMs = max(roundedMs, flooredMs + 1)
                expectedFirstPassRegressFiles += 1
            } else {
                legacyMs = roundedMs
            }
            let cleanOffset = try #require(cleanOffsets[fileURL.path])
            let lastEventId = seededEvents.first(where: { $0.sourcePath == fileURL.path })?.id
            // Prefer the async DatabaseQueue.write overload inside async tests.
            try await queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO source_watermarks
                    (source_path, agent, last_mtime, last_byte_offset, last_event_id, updated_at, last_inode)
                    VALUES (?, 'antigravity', ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        fileURL.path,
                        legacyMs,
                        cleanOffset,
                        lastEventId,
                        now.tokenBarMillisecondsSince1970,
                        Int64(fingerprint.inode),
                    ]
                )
            }
        }

        let baselineEvents = try repository.allEvents()
        let baselineIDs = Set(baselineEvents.map(\.id))
        let baselineTokens = baselineEvents.reduce(0) { $0 + totalTokens($1) }
        #expect(baselineIDs.count == allSeeded.count)

        let source = AntigravityUsageEventSource(roots: [root.path])
        var mtimeRegressByCheckpoint: [Int] = []
        var totalEventsAdded = 0

        for checkpointIndex in 1...3 {
            let watermarks = try repository.watermarks()
            let loaded = try await source.loadEvents(
                since: watermarks,
                referenceDate: now,
                calendar: Calendar(identifier: .gregorian)
            )
            let mtimeWarningCount = loaded.warnings.filter {
                $0.message.localizedCaseInsensitiveContains("mtime regress")
            }.count
            mtimeRegressByCheckpoint.append(mtimeWarningCount)
            // Partial-line warnings may legitimately repeat; do not treat them
            // as the mtime-regress failure mode under test.
            let hasPartialWarning = loaded.warnings.contains(where: {
                $0.message.localizedCaseInsensitiveContains("partial trailing JSONL line")
            })
            #expect(hasPartialWarning)

            let summary = try repository.insertCheckpoint(
                trigger: "upgrade-\(checkpointIndex)",
                startedAt: now,
                endedAt: now,
                events: loaded.events,
                prompts: [],
                nextWatermarks: loaded.nextWatermarks,
                warnings: loaded.warnings,
                error: nil
            )
            totalEventsAdded += summary.eventsAdded
        }

        #expect(mtimeRegressByCheckpoint[0] == expectedFirstPassRegressFiles)
        #expect(mtimeRegressByCheckpoint[1] == 0)
        #expect(mtimeRegressByCheckpoint[2] == 0)
        #expect(totalEventsAdded == 0)

        let finalEvents = try repository.allEvents()
        let finalIDs = Set(finalEvents.map(\.id))
        let finalTokens = finalEvents.reduce(0) { $0 + totalTokens($1) }
        #expect(finalIDs == baselineIDs)
        #expect(finalTokens == baselineTokens)
        let preservedCodex = finalEvents.contains { $0.id == "preserve-codex" && $0.agent == .codex }
        let preservedDevin = finalEvents.contains { $0.id == "preserve-devin" && $0.agent == .devin }
        let preservedGrok = finalEvents.contains { $0.id == "preserve-grok" && $0.agent == .grok }
        #expect(preservedCodex)
        #expect(preservedDevin)
        #expect(preservedGrok)

        // After upgrade, stored watermarks must not lead real mtimes.
        for spec in specs {
            let fileURL = root.appendingPathComponent("\(spec.name).jsonl")
            let stored = try #require(try repository.watermark(for: fileURL.path))
            let realMtime = try #require(realMtimes[fileURL.path])
            #expect(stored.lastMtime <= realMtime)
            let current = try JSONLIncrementalReader.fingerprint(at: fileURL.path)
            let strategy = JSONLIncrementalReader.decide(current: current, watermark: stored)
            #expect(strategy == .incremental(fromByteOffset: stored.lastByteOffset))
        }
    }

    private func makeSyntheticEvent(
        id: String,
        agent: AgentKind,
        parser: ParserKind,
        input: Int,
        output: Int
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            agent: agent,
            projectPath: "/tmp/preserve",
            projectName: "preserve",
            sessionId: "preserve",
            timestamp: Date(timeIntervalSince1970: 1_700_000_050),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            sourcePath: "/tmp/preserve/\(agent.rawValue).jsonl",
            parser: parser,
            confidence: 1.0
        )
    }

    private func totalTokens(_ event: UsageEvent) -> Int {
        event.inputTokens + event.outputTokens + event.cacheReadTokens + event.cacheCreationTokens + (event.reasoningTokens ?? 0)
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
    func jsonlReaderContextBytesReemitsLookbehindFromLineBoundary() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("ctx.jsonl")
        try writeLines(["{\"a\":1}", "{\"bb\":22}", "{\"ccc\":333}"], to: fileURL, trailingNewline: true)
        let first = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Codex", agent: .codex, watermark: nil)
        #expect(first.lines.map(\.lineNumber) == [1, 2, 3])

        try append("{\"d\":4}\n", to: fileURL)

        // Window lands mid-line inside line 2; the partial head is dropped
        // and the lookbehind re-emits from line 3's boundary. Line numbers
        // must match a full re-parse.
        let contextBytes = Int64("{\"ccc\":333}\n".utf8.count + 5)
        let second = try JSONLIncrementalReader.read(
            fileURL: fileURL,
            sourceName: "Codex",
            agent: .codex,
            watermark: first.nextWatermark,
            contextBytes: contextBytes
        )

        #expect(second.lines.map(\.text) == ["{\"ccc\":333}", "{\"d\":4}"])
        #expect(second.lines.map(\.lineNumber) == [3, 4])
        // Watermark still advances to EOF, never regresses into the context.
        #expect(second.nextWatermark.lastByteOffset == Int64((try Data(contentsOf: fileURL)).count))
    }

    @Test
    func jsonlReaderContextBytesAsyncMatchesSyncLineNumbers() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("ctx-async.jsonl")
        try writeLines(["{\"a\":1}", "{\"bb\":22}", "{\"ccc\":333}"], to: fileURL, trailingNewline: true)
        let first = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Codex", agent: .codex, watermark: nil)
        try append("{\"d\":4}\n", to: fileURL)

        let contextBytes = Int64("{\"ccc\":333}\n".utf8.count + 5)
        let second = try await JSONLIncrementalReader.read(
            fileURL: fileURL,
            sourceName: "Codex",
            agent: .codex,
            watermark: first.nextWatermark,
            contextBytes: contextBytes,
            resourceThrottle: nil
        )

        #expect(second.lines.map(\.text) == ["{\"ccc\":333}", "{\"d\":4}"])
        #expect(second.lines.map(\.lineNumber) == [3, 4])
        #expect(second.nextWatermark.lastByteOffset == Int64((try Data(contentsOf: fileURL)).count))
    }

    @Test
    func jsonlReaderContextBytesZeroIsIncrementalOnlyAndOversizedReadsWholeFile() throws {
        let fileURL = temporaryDirectory().appendingPathComponent("ctx-bounds.jsonl")
        try writeLines(["{\"a\":1}", "{\"b\":2}"], to: fileURL, trailingNewline: true)
        let first = try JSONLIncrementalReader.read(fileURL: fileURL, sourceName: "Codex", agent: .codex, watermark: nil)
        try append("{\"c\":3}\n", to: fileURL)

        let incrementalOnly = try JSONLIncrementalReader.read(
            fileURL: fileURL,
            sourceName: "Codex",
            agent: .codex,
            watermark: first.nextWatermark,
            contextBytes: 0
        )
        #expect(incrementalOnly.lines.map(\.text) == ["{\"c\":3}"])

        let oversized = try JSONLIncrementalReader.read(
            fileURL: fileURL,
            sourceName: "Codex",
            agent: .codex,
            watermark: first.nextWatermark,
            contextBytes: .max
        )
        #expect(oversized.lines.map(\.lineNumber) == [1, 2, 3])
    }

    @Test
    func codexSourceContextLookbehindPairsAppendedResponseWithEarlierDispatch() async throws {
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
            #"{"timestamp":"2026-05-14T00:00:10.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}}"#,
        ], to: fileURL, trailingNewline: true)

        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let source = CodexUsageEventSource(rootPath: root.path, daysBack: 2)
        let engine = CheckpointEngine(sources: [source], store: store)

        let first = await engine.run(trigger: "test", startedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)
        #expect(first.checkpoint?.eventsAdded == 0)

        try append(tokenCountLine(timestamp: "2026-05-14T00:00:15.000Z", input: 20, cache: 2, output: 3) + "\n", to: fileURL)
        let second = await engine.run(trigger: "test", startedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)

        // The dispatch record sits behind the watermark; the 1 MiB
        // lookbehind re-reads it so the appended response carries real
        // generation timing rather than nil.
        #expect(second.checkpoint?.eventsAdded == 1)
        let event = try #require(second.state.events.last)
        #expect(event.generationStartMs == 1_778_716_810_000)
        #expect(event.generationEndMs == 1_778_716_815_000)
        #expect(event.generationDurationMs == 5_000)
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
