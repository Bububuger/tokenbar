import Foundation
import Testing
@testable import TokenBarCore

/// Devin CLI transcript (ATIF) parsing: each step with `metrics` is one
/// model request. `prompt_tokens` is the FULL prompt size and
/// `cached_tokens` is the cache-hit subset of it, so fresh input =
/// `prompt − cached`. Transcripts carry no cwd; project attribution comes
/// from the caller-supplied session → path map.
struct DevinUsageParserTests {
    private static let transcript = """
    {
      "schema_version": "ATIF-v1.7",
      "session_id": "test-rose",
      "agent": {"name": "devin", "version": "3000.11.3", "model_name": "SWE-2 Max"},
      "steps": [
        {"step_id": "s1", "timestamp": "2026-09-28T08:32:42.353333+00:00", "source": "agent", "model_name": "swe-2-max", "metrics": {"prompt_tokens": 127996, "cached_tokens": 127020, "completion_tokens": 202}},
        {"step_id": "s2", "timestamp": "2026-09-28T08:40:00.000000+00:00", "source": "agent", "metrics": {"prompt_tokens": 500, "cached_tokens": 0, "completion_tokens": 0}},
        {"step_id": "s3", "timestamp": "2026-09-28T08:41:00.000000+00:00", "source": "agent"},
        {"step_id": "s4", "timestamp": "2026-09-28T08:42:00.000000+00:00", "source": "agent", "metrics": {"prompt_tokens": 0, "cached_tokens": 0, "completion_tokens": 0}}
      ],
      "final_metrics": {"total_prompt_tokens": 128496, "total_completion_tokens": 202, "total_cached_tokens": 127020, "total_steps": 4}
    }
    """

    private func parseTranscript(_ json: String, projects: [String: String] = [:]) throws -> ParseResult {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devin-\(UUID().uuidString).json")
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        let data = try Data(contentsOf: tmp)
        return DevinUsageParser.parse(data: data, fileURL: tmp, projects: projects)
    }

    @Test
    func parsesStepsWithCacheSubtractionAndNoWarnings() throws {
        let result = try parseTranscript(
            Self.transcript,
            projects: ["test-rose": "/Users/work/observ"]
        )

        #expect(result.events.count == 2)

        let s1 = result.events[0]
        #expect(s1.agent == .devin)
        #expect(s1.parser == .devin)
        #expect(s1.id.contains("#devin#s1"))
        #expect(s1.inputTokens == 976)
        #expect(s1.outputTokens == 202)
        #expect(s1.cacheReadTokens == 127020)
        #expect(s1.cacheCreationTokens == 0)
        #expect(s1.reasoningTokens == nil)
        #expect(s1.actualCostUSD == nil)
        #expect(s1.modelName == "swe-2-max")
        #expect(s1.sessionId == "test-rose")
        #expect(s1.projectName == "observ")
        #expect(s1.projectPath == "/Users/work/observ")
        // RFC3339 with +00:00 offset and microsecond fraction.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: s1.timestamp)
        #expect(comps.year == 2026 && comps.month == 9 && comps.day == 28)
        #expect(comps.hour == 8 && comps.minute == 32 && comps.second == 42)

        let s2 = result.events[1]
        #expect(s2.id.contains("#devin#s2"))
        #expect(s2.inputTokens == 500)
        #expect(s2.outputTokens == 0)
        #expect(s2.modelName == "SWE-2 Max")
        // 08:40:00.000000 − 08:32:42.353333 = 437.646667s
        #expect(abs(s2.timestamp.timeIntervalSince(s1.timestamp) - 437.646667) < 0.001)

        // Metricless s3 and all-zero s4 are skipped; final_metrics sums match.
        #expect(result.warnings.isEmpty)
    }

    @Test
    func separatesClaudeCacheWritesFromFreshInput() throws {
        let result = try parseTranscript("""
        {
          "schema_version": "ATIF-v1.7",
          "session_id": "claude-cache-write",
          "agent": {"model_name": "claude"},
          "steps": [
            {"step_id": "11", "timestamp": "2026-10-01T07:16:48Z", "metrics": {"prompt_tokens": 45633, "cached_tokens": 12018, "completion_tokens": 100, "extra": {"cache_creation_input_tokens": 33611}}}
          ],
          "final_metrics": {"total_prompt_tokens": 45633, "total_cached_tokens": 12018, "total_completion_tokens": 100}
        }
        """)
        #expect(result.events.count == 1)
        let event = result.events[0]
        #expect(event.inputTokens == 4)
        #expect(event.cacheReadTokens == 12018)
        #expect(event.cacheCreationTokens == 33611)
        #expect(event.inputTokens + event.outputTokens + event.cacheTokens == 45733)
        #expect(result.warnings.isEmpty)
    }

    @Test
    func unknownProjectFallsBackToUnknownName() throws {
        let result = try parseTranscript(Self.transcript, projects: [:])
        #expect(result.events[0].projectName == "unknown")
        #expect(result.events[0].projectPath == nil)
    }

    @Test
    func schemaGateRejectsUnsupportedVersions() throws {
        let v2 = Self.transcript.replacingOccurrences(of: "ATIF-v1.7", with: "ATIF-v2.0")
        let result = try parseTranscript(v2)
        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("schema not supported"))
    }

    @Test
    func finalMetricsMismatchProducesWarnings() throws {
        let mismatched = Self.transcript.replacingOccurrences(
            of: "\"total_prompt_tokens\": 128496",
            with: "\"total_prompt_tokens\": 999999"
        )
        let result = try parseTranscript(mismatched)
        #expect(result.events.count == 2)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("prompt 128496 vs 999999"))
    }

    @Test
    func malformedJSONProducesWarningOnly() throws {
        let result = try parseTranscript("{ not json")
        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("malformed"))
    }

    /// A numeric `step_id` is the step's identity. A later parse of the same
    /// path replaces the stored rows with that file and leaves other paths.
    @Test
    func numericStepIDReplacesStoredRowsForTheSamePath() throws {
        let path = "/tmp/devin-rewrite.json"
        let fileURL = URL(fileURLWithPath: path)
        let first = DevinUsageParser.parse(data: Data("""
        {"schema_version":"ATIF-v1.7","session_id":"sess-a","steps":[
          {"step_id":1,"timestamp":"2026-10-01T00:00:00Z","metrics":{"prompt_tokens":10,"completion_tokens":1}},
          {"step_id":2,"timestamp":"2026-10-01T00:01:00Z","metrics":{"prompt_tokens":20,"completion_tokens":2}}
        ]}
        """.utf8), fileURL: fileURL)
        let second = DevinUsageParser.parse(data: Data("""
        {"schema_version":"ATIF-v1.7","session_id":"sess-b","steps":[
          {"step_id":2,"timestamp":"2026-10-01T00:01:00Z","metrics":{"prompt_tokens":20,"completion_tokens":2}},
          {"step_id":3,"timestamp":"2026-10-01T00:02:00Z","metrics":{"prompt_tokens":30,"completion_tokens":3}}
        ]}
        """.utf8), fileURL: fileURL)

        #expect(first.events.map(\.id) == ["\(path)#devin#1", "\(path)#devin#2"])
        #expect(first.events.map(\.inputTokens) == [10, 20])
        #expect(first.events.map(\.sessionId) == ["sess-a", "sess-a"])
        #expect(second.events.map(\.id) == ["\(path)#devin#2", "\(path)#devin#3"])
        #expect(second.events.map(\.inputTokens) == [20, 30])
        #expect(second.events.map(\.sessionId) == ["sess-b", "sess-b"])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devin-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try UsageRepository(databaseURL: directory.appendingPathComponent("tokenbar.sqlite"))
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let other = UsageEvent(
            id: "/tmp/other.json#devin#9",
            agent: .devin,
            projectPath: nil,
            projectName: "unknown",
            sessionId: "other",
            timestamp: now,
            inputTokens: 1,
            outputTokens: 1,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            modelName: nil,
            sourcePath: "/tmp/other.json",
            parser: .devin,
            confidence: 1
        )
        _ = try repository.insertCheckpoint(
            trigger: "first",
            startedAt: now,
            endedAt: now,
            events: first.events + [other],
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )
        _ = try repository.insertCheckpoint(
            trigger: "rewrite",
            startedAt: now,
            endedAt: now,
            events: second.events,
            prompts: [],
            nextWatermarks: [],
            warnings: [],
            error: nil
        )

        let stored = try repository.allEvents()
            .filter { $0.sourcePath == path }
            .sorted { $0.id < $1.id }
        #expect(stored.map(\.id) == ["\(path)#devin#2", "\(path)#devin#3"])
        #expect(stored.map(\.inputTokens) == [20, 30])
        #expect(stored.map(\.outputTokens) == [2, 3])
        #expect(stored.map(\.sessionId) == ["sess-b", "sess-b"])
        #expect(try repository.allEvents().filter { $0.sourcePath == "/tmp/other.json" }.map(\.id) == ["/tmp/other.json#devin#9"])
    }
}
