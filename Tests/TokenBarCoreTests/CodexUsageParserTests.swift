import Foundation
import GRDB
import Testing
@testable import TokenBarCore

struct CodexUsageParserTests {
    @Test
    func codexFixturesAreLoadable() throws {
        #expect(try fixtureURL(named: "session-valid").isFileURL)
        #expect(try fixtureURL(named: "session-fallback").isFileURL)
        #expect(try fixtureURL(named: "session-malformed").isFileURL)
        #expect(try fixtureURL(named: "session-model-context").isFileURL)
    }

    @Test
    func parserEmitsUsageEventsFromTokenCountRecords() throws {
        let result = try CodexUsageParser.parse(fileURL: fixtureURL(named: "session-valid"))

        #expect(result.events.count == 2)
        #expect(result.warnings.isEmpty)
        #expect(result.events[0].agent == .codex)
        #expect(result.events[0].projectName == "tokenbar")
        #expect(result.events[0].inputTokens == 24_049)
        #expect(result.events[0].cacheTokens == 3_456)
        #expect(result.events[0].outputTokens == 141)
        #expect(result.events[0].reasoningTokens == 54)
        #expect(result.events[1].inputTokens == 537)
        #expect(result.events[1].cacheTokens == 27_008)
        #expect(result.events[1].outputTokens == 57)
        #expect(result.events[1].reasoningTokens == 9)
    }

    @Test
    func parserFallsBackToTotalUsageWhenLastUsageIsMissing() throws {
        let result = try CodexUsageParser.parse(fileURL: fixtureURL(named: "session-fallback"))

        #expect(result.events.count == 1)
        #expect(result.events[0].projectName == "knowledge")
        #expect(result.events[0].inputTokens == 4_616)
        #expect(result.events[0].cacheTokens == 7_296)
        #expect(result.events[0].outputTokens == 263)
        #expect(result.events[0].reasoningTokens == 164)
    }

    @Test
    func parserCarriesMostRecentModelFromSessionAndTurnContext() throws {
        let result = try CodexUsageParser.parse(fileURL: fixtureURL(named: "session-model-context"))

        #expect(result.events.count == 2)
        #expect(result.events[0].modelName == "gemini-2.5-pro")
        #expect(result.events[1].modelName == "gpt-4.1-mini")
    }

    @Test
    func parserReportsWarningsForMalformedAndInvalidLines() throws {
        let result = try CodexUsageParser.parse(fileURL: fixtureURL(named: "session-malformed"))

        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 2)
    }

    @Test
    func ordinaryActiveRolloutKeepsPathBasedEventAndPromptIDs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root
            .appendingPathComponent("2026/04/27", isDirectory: true)
            .appendingPathComponent("rollout-2026-04-27T12-00-00-compat.jsonl")
        try writeRollout(to: file)

        let result = try CodexUsageParser.parse(fileURL: file)

        #expect(result.events.count == 1)
        #expect(result.events[0].id == "\(file.path)#3")
        #expect(result.events[0].sourcePath == file.path)
        #expect(result.prompts.count == 1)
        #expect(result.prompts[0].id.hasPrefix("\(file.path)#prompt#2#"))
        #expect(result.prompts[0].sourcePath == file.path)
    }

    @Test
    func activeAndArchiveCopiesShareStableIDsButKeepPhysicalSourcePaths() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let basename = "rollout-2026-04-27T12-00-00-stable.jsonl"
        let active = parent
            .appendingPathComponent("sessions/2026/04/27", isDirectory: true)
            .appendingPathComponent(basename)
        let archived = parent
            .appendingPathComponent("archived_sessions", isDirectory: true)
            .appendingPathComponent(basename)
        try writeRollout(to: active)
        try writeRollout(to: archived)

        let activeResult = try CodexUsageParser.parse(fileURL: active)
        let archiveResult = try CodexUsageParser.parse(fileURL: archived)

        #expect(activeResult.events.count == 1)
        #expect(archiveResult.events.count == 1)
        #expect(activeResult.events[0].id == archiveResult.events[0].id)
        #expect(activeResult.events[0].sourcePath == active.path)
        #expect(archiveResult.events[0].sourcePath == archived.path)
        #expect(activeResult.prompts.count == 1)
        #expect(archiveResult.prompts.count == 1)
        #expect(activeResult.prompts[0].id == archiveResult.prompts[0].id)
        #expect(activeResult.prompts[0].sourcePath == active.path)
        #expect(archiveResult.prompts[0].sourcePath == archived.path)
    }

    @Test
    func eventSourceDoesNotDoubleCountAnActiveRolloutPresentInArchive() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let activeRoot = parent.appendingPathComponent("sessions", isDirectory: true)
        let archiveRoot = parent.appendingPathComponent("archived_sessions", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!
        let basename = "rollout-2026-04-27T12-00-00-total.jsonl"
        let active = activeRoot.appendingPathComponent("2026/04/27", isDirectory: true).appendingPathComponent(basename)
        let archived = archiveRoot.appendingPathComponent(basename)
        try writeRollout(to: active)
        try writeRollout(to: archived)

        let source = CodexUsageEventSource(
            rootPath: activeRoot.path,
            archiveRootPath: archiveRoot.path,
            daysBack: 1
        )
        let loaded = try await source.loadEvents(
            since: [:],
            referenceDate: referenceDate,
            calendar: calendar
        )

        #expect(loaded.events.count == 1)
        #expect(loaded.events.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } == 12)
        #expect(loaded.prompts.count == 1)
    }

    @Test
    func eventSourceHandlesArchiveRootWithArbitraryDirectoryName() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let activeRoot = parent.appendingPathComponent("sessions", isDirectory: true)
        let archiveRoot = parent.appendingPathComponent("codex-history", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!
        let basename = "rollout-2026-04-27T12-00-00-arbitrary.jsonl"
        let active = activeRoot.appendingPathComponent("2026/04/27", isDirectory: true).appendingPathComponent(basename)
        let archived = archiveRoot.appendingPathComponent(basename)
        try writeRollout(to: active)
        try writeRollout(to: archived)

        let activeResult = try CodexUsageParser.parse(fileURL: active, canonicalActiveRootPath: activeRoot.path)
        let archiveResult = try CodexUsageParser.parse(fileURL: archived, canonicalActiveRootPath: activeRoot.path)
        try FileManager.default.removeItem(at: active)
        let source = CodexUsageEventSource(
            rootPath: activeRoot.path,
            archiveRootPath: archiveRoot.path,
            daysBack: 1
        )
        let loaded = try await source.loadEvents(since: [:], referenceDate: referenceDate, calendar: calendar)

        #expect(activeResult.events[0].id == archiveResult.events[0].id)
        #expect(activeResult.prompts[0].id == archiveResult.prompts[0].id)
        #expect(loaded.events.count == 1)
        #expect(loaded.prompts.count == 1)
        #expect(loaded.events[0].id == activeResult.events[0].id)
        #expect(loaded.prompts[0].id == activeResult.prompts[0].id)
        #expect(URL(fileURLWithPath: loaded.events[0].sourcePath).standardizedFileURL.path == archived.standardizedFileURL.path)
        #expect(URL(fileURLWithPath: loaded.prompts[0].sourcePath).standardizedFileURL.path == archived.standardizedFileURL.path)
    }

    @Test
    func eventSourceWithArchiveAsRootUsesSiblingSessionsForStableIDs() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let archiveRoot = parent.appendingPathComponent("archived_sessions", isDirectory: true)
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!
        let basename = "rollout-2026-04-27T12-00-00-archive-root.jsonl"
        let archived = archiveRoot.appendingPathComponent(basename)
        try writeRollout(to: archived)

        let source = CodexUsageEventSource(rootPath: archiveRoot.path, daysBack: 1)
        let loaded = try await source.loadEvents(since: [:], referenceDate: referenceDate, calendar: calendar)
        let expectedActivePath = parent
            .appendingPathComponent("sessions/2026/04/27", isDirectory: true)
            .appendingPathComponent(basename)
            .path

        #expect(loaded.events.count == 1)
        #expect(loaded.events[0].id == "\(expectedActivePath)#3")
        #expect(URL(fileURLWithPath: loaded.events[0].sourcePath).standardizedFileURL.path == archived.standardizedFileURL.path)
        #expect(loaded.prompts.count == 1)
        #expect(loaded.prompts[0].id.hasPrefix("\(expectedActivePath)#prompt#2#"))
        #expect(URL(fileURLWithPath: loaded.prompts[0].sourcePath).standardizedFileURL.path == archived.standardizedFileURL.path)
    }

    /// Regression: Codex emits the same `last_token_usage` payload twice
    /// per turn (initial + render-complete). Parser must collapse them so
    /// totals match reality — real rollouts showed a 1.16-1.19x over-count
    /// without this dedup.
    @Test
    func parserDedupesConsecutiveIdenticalTokenCountPayloads() throws {
        let result = try CodexUsageParser.parse(fileURL: fixtureURL(named: "session-dedup"))

        // Fixture has 4 token_count events but only 2 distinct payloads;
        // duplicates of each must collapse.
        #expect(result.events.count == 2)
        #expect(result.events[0].inputTokens == 100)
        #expect(result.events[1].inputTokens == 150)
        // Total input must equal sum of distinct payloads, not the doubled raw.
        let totalInput = result.events.reduce(0) { $0 + $1.inputTokens }
        #expect(totalInput == 250)
    }

    @Test
    func parserSplitsCodexInputIntoMutuallyExclusiveBuckets() {
        let result = parseJSONLines([
            tokenCount(last: usage(input: 100, read: 40, write: 30, output: 10, reasoning: 5, total: 110)),
        ])

        #expect(result.events.count == 1)
        let event = result.events[0]
        #expect(event.inputTokens == 30)
        #expect(event.cacheReadTokens == 40)
        #expect(event.cacheCreationTokens == 30)
        #expect(event.outputTokens == 10)
        #expect(event.reasoningTokens == 5)
        #expect(totalTokens(event) == 110)
    }

    @Test
    func parserPrefersLastUsageAndDiffsTotalOnlyRecords() {
        let preferred = parseJSONLines([
            tokenCount(
                last: usage(input: 100, read: 0, output: 10, total: 110),
                total: usage(input: 999, read: 0, output: 99, total: 1_098)
            ),
        ])
        #expect(preferred.events.count == 1)
        #expect(totalTokens(preferred.events[0]) == 110)

        let totalOnly = parseJSONLines([
            tokenCount(total: usage(input: 100, read: 0, output: 0, total: 100)),
            tokenCount(total: usage(input: 180, read: 0, output: 0, total: 180)),
        ])
        #expect(totalOnly.events.count == 2)
        #expect(totalOnly.events.reduce(0) { $0 + totalTokens($1) } == 180)
    }

    @Test
    func parserHandlesTotalResetAndFiltersSyntheticContextUsage() {
        let result = parseJSONLines([
            tokenCount(total: usage(input: 100, read: 0, output: 0, total: 100)),
            tokenCount(total: usage(input: 30, read: 0, output: 0, total: 30)),
            tokenCount(total: usage(input: 0, read: 0, output: 0, total: 200)),
        ])

        #expect(result.events.count == 2)
        #expect(result.events.map(\.inputTokens) == [100, 30])
    }

    @Test
    func parserDefaultsMissingCacheWriteToZero() {
        let result = parseJSONLines([
            tokenCount(last: usage(input: 100, read: 40, output: 10, total: 110)),
        ])

        #expect(result.events.count == 1)
        #expect(result.events[0].inputTokens == 60)
        #expect(result.events[0].cacheReadTokens == 40)
        #expect(result.events[0].cacheCreationTokens == 0)
    }

    @Test
    func parserDedupKeyIncludesCacheWrite() {
        let result = parseJSONLines([
            tokenCount(last: usage(input: 100, read: 40, write: 10, output: 10, total: 110)),
            tokenCount(last: usage(input: 110, read: 40, write: 20, output: 10, total: 120)),
        ])

        #expect(result.events.count == 2)
        #expect(result.events.map(\.inputTokens) == [50, 50])
        #expect(result.events.map(\.cacheCreationTokens) == [10, 20])
    }

    @Test
    func parserKeepsIdenticalUsageFromDistinctCumulativeCompletions() {
        let completion = usage(input: 100, read: 40, output: 10, total: 110)
        let result = parseJSONLines([
            tokenCount(
                last: completion,
                total: usage(input: 100, read: 40, output: 10, total: 110)
            ),
            tokenCount(
                last: completion,
                total: usage(input: 200, read: 80, output: 20, total: 220)
            ),
        ])

        #expect(result.events.count == 2)
        #expect(result.events.reduce(0) { $0 + totalTokens($1) } == 220)
    }

    @Test
    func asyncParserKeepsIdenticalUsageAcrossTurnBoundary() async {
        let completion = usage(input: 100, read: 40, output: 10, total: 110)
        let result = await parseJSONLinesAsync([
            tokenCount(last: completion),
            turnContext(),
            tokenCount(last: completion),
        ])

        #expect(result.events.count == 2)
        #expect(result.events.reduce(0) { $0 + totalTokens($1) } == 220)
    }

    @Test
    func parserSafelyConstrainsOverflowingCacheClassifications() {
        let result = parseJSONLines([
            tokenCount(
                last: usage(
                    input: Int.max,
                    read: Int.max,
                    write: Int.max,
                    output: 0,
                    total: Int.max
                )
            ),
        ])

        #expect(result.events.count == 1)
        #expect(result.events[0].inputTokens == 0)
        #expect(result.events[0].cacheReadTokens == Int.max)
        #expect(result.events[0].cacheCreationTokens == 0)
        #expect(totalTokens(result.events[0]) == Int.max)
    }

    @Test
    func parserTreatsMalformedNegativeCumulativeBoundaryAsReset() {
        let result = parseJSONLines([
            tokenCount(total: usage(input: Int.min, read: 0, output: 0, total: Int.min)),
            tokenCount(total: usage(input: Int.max, read: 0, output: 0, total: Int.max)),
        ])

        #expect(result.events.count == 2)
        #expect(result.events[0].inputTokens == 0)
        #expect(result.events[1].inputTokens == Int.max)
    }

    @Test
    func parserNormalizesLegacySeparateReasoningWithoutEmittingSyntheticUsage() {
        let result = parseJSONLines([
            tokenCount(last: usage(input: 100, read: 0, output: 10, reasoning: 5, total: 115)),
            tokenCount(last: usage(input: 0, read: 0, output: 0, reasoning: 0, total: 50)),
        ])

        #expect(result.events.count == 1)
        #expect(result.events[0].outputTokens == 15)
        #expect(result.events[0].reasoningTokens == 5)
        #expect(totalTokens(result.events[0]) == 115)
    }

    @Test
    func databaseMigrationRemovesHistoricalCodexCacheReadDoubleCount() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/test-artifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try UsageDatabase(url: directory.appendingPathComponent("usage.sqlite"))
        try database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO usage_events (
                    id, agent, project_name, session_id, timestamp,
                    input_tokens, output_tokens, cache_tokens,
                    reasoning_tokens, source_path, parser, confidence,
                    cache_read_tokens, cache_creation_tokens
                ) VALUES
                    ('codex', 'codex', 'p', 's', 0, 100, 10, 40, NULL, 'f', 'codex', 1, 40, 10),
                    ('claude', 'claudeCode', 'p', 's', 0, 100, 10, 40, NULL, 'f', 'claudeCode', 1, 40, 0)
                """
            )
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v19_normalize_codex_cached_input"]
            )
        }

        try UsageDatabase.migrator.migrate(database.queue)
        let inputs = try database.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, input_tokens FROM usage_events ORDER BY id")
                .reduce(into: [String: Int]()) { values, row in
                    values[row["id"]] = row["input_tokens"]
                }
        }
        #expect(inputs["codex"] == 50)
        #expect(inputs["claude"] == 100)
    }

    private func fixtureURL(named name: String) throws -> URL {
        guard let url = fixtureBundle.url(forResource: name, withExtension: "jsonl") else {
            throw FixtureError.missing(name)
        }
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: root,
            create: true
        )
    }

    private func writeRollout(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-04-27T12:00:00Z","type":"session_meta","payload":{"id":"stable-session","cwd":"/tmp/tokenbar"}}"#,
            #"{"timestamp":"2026-04-27T12:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"same prompt"}]}}"#,
            #"{"timestamp":"2026-04-27T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":12}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func parseJSONLines(_ json: [String]) -> CodexParseResult {
        CodexUsageParser.parse(
            lines: lineRecords(json),
            fileURL: parserFixtureURL
        )
    }

    private func parseJSONLinesAsync(_ json: [String]) async -> CodexParseResult {
        await CodexUsageParser.parse(
            lines: lineRecords(json),
            fileURL: parserFixtureURL,
            resourceThrottle: nil
        )
    }

    private func lineRecords(_ json: [String]) -> [JSONLLineRecord] {
        json.enumerated().map {
            JSONLLineRecord(
                text: $0.element,
                lineNumber: $0.offset + 1,
                startOffset: 0,
                endOffset: 0
            )
        }
    }

    private var parserFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("codex-parser-test.jsonl")
    }

    private func totalTokens(_ event: UsageEvent) -> Int {
        event.inputTokens
            + event.cacheReadTokens
            + event.cacheCreationTokens
            + event.outputTokens
    }

    private func tokenCount(last: String? = nil, total: String? = nil) -> String {
        let fields = [
            last.map { "\"last_token_usage\":\($0)" },
            total.map { "\"total_token_usage\":\($0)" },
        ].compactMap { $0 }.joined(separator: ",")
        return """
        {"timestamp":"2026-07-24T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{\(fields)}}}
        """
    }

    private func turnContext() -> String {
        """
        {"timestamp":"2026-07-24T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6"}}
        """
    }

    private func usage(
        input: Int,
        read: Int,
        write: Int? = nil,
        output: Int,
        reasoning: Int = 0,
        total: Int
    ) -> String {
        let writeField = write.map { ",\"cache_write_input_tokens\":\($0)" } ?? ""
        return """
        {"input_tokens":\(input),"cached_input_tokens":\(read)\(writeField),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)}
        """
    }
}

private enum FixtureError: Error {
    case missing(String)
}

struct UsageSummaryMetricsTests {
    @Test
    func cacheReadRateUsesOnlyTotalInput() {
        let summary = UsageSummary(
            inputTokens: 30,
            outputTokens: 10,
            cacheReadTokens: 40,
            cacheCreationTokens: 30
        )

        #expect(summary.totalTokens == 110)
        #expect(summary.totalInputTokens == 100)
        #expect(summary.cacheReadRate == 0.4)
    }

    @Test
    func cacheReadRateExcludesOutputTokens() {
        let summary = UsageSummary(
            inputTokens: 60,
            outputTokens: 900,
            cacheReadTokens: 40,
            cacheCreationTokens: 0
        )

        #expect(summary.cacheReadRate == 0.4)
    }

    @Test
    func cacheWritesAreNotCacheReads() {
        let summary = UsageSummary(
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 60
        )

        #expect(summary.totalInputTokens == 60)
        #expect(summary.cacheReadRate == 0)
    }
}
