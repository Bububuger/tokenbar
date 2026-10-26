import Foundation
import Testing
@testable import TokenBarCore

struct GeminiUsageParserTests {
    private func loadFixture(_ name: String, ext: String) throws -> (Data, URL) {
        guard let url = fixtureBundle.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "gemini"
        ) ?? fixtureBundle.url(forResource: name, withExtension: ext) else {
            throw FixtureError.missing(name)
        }
        return (try Data(contentsOf: url), url)
    }

    private func stubResolver(_ slug: String) -> (projectName: String, projectPath: String?) {
        (projectName: "test-project", projectPath: "/tmp/test")
    }

    @Test
    func parsesLegacyJSONFormat() throws {
        let (data, url) = try loadFixture("session-single-model", ext: "json")
        let result = GeminiUsageParser.parse(data: data, fileURL: url, projectResolver: stubResolver)

        #expect(result.events.count == 1)
        let e = result.events[0]
        #expect(e.agent == .geminiCLI)
        #expect(e.inputTokens == 120)
        #expect(e.outputTokens == 13) // output(10) + tool(3)
        #expect(e.cacheReadTokens == 5)
        #expect(e.reasoningTokens == 2)
        #expect(e.modelName == "gemini-3-flash-preview")
        #expect(e.sessionId == "session-single")
    }

    @Test
    func parsesJSONLFormat() throws {
        let (data, url) = try loadFixture("session-jsonl", ext: "jsonl")
        let result = GeminiUsageParser.parse(data: data, fileURL: url, projectResolver: stubResolver)

        #expect(result.events.count == 3)

        let e0 = result.events[0]
        #expect(e0.inputTokens == 100)
        #expect(e0.outputTokens == 20)
        #expect(e0.cacheReadTokens == 0)
        #expect(e0.reasoningTokens == 15)
        #expect(e0.modelName == "gemini-3-flash-preview")

        let e1 = result.events[1]
        #expect(e1.inputTokens == 500)
        #expect(e1.outputTokens == 200)
        #expect(e1.cacheReadTokens == 50)
        #expect(e1.reasoningTokens == 0) // thoughts missing → defaults to 0
        #expect(e1.modelName == "gemini-2.5-pro")

        let e2 = result.events[2]
        #expect(e2.inputTokens == 600)
        #expect(e2.outputTokens == 125) // output(100) + tool(25)
        #expect(e2.cacheReadTokens == 30)
        #expect(e2.reasoningTokens == 50)
    }

    @Test
    func jsonlExtractsSessionId() throws {
        let (data, url) = try loadFixture("session-jsonl", ext: "jsonl")
        let result = GeminiUsageParser.parse(data: data, fileURL: url, projectResolver: stubResolver)

        for event in result.events {
            #expect(event.sessionId == "sess-jsonl-1")
        }
    }

    @Test
    func jsonlSkipsUserAndMetadataLines() throws {
        let (data, url) = try loadFixture("session-jsonl", ext: "jsonl")
        let result = GeminiUsageParser.parse(data: data, fileURL: url, projectResolver: stubResolver)

        // 10 lines total: 1 header + 3 gemini + 2 user + 4 $set → only 3 events
        #expect(result.events.count == 3)
        #expect(result.warnings.isEmpty)
    }

    @Test
    func generationTimingPairsUserWithNextGeminiResponseInJSON() throws {
        let json = """
        {"sessionId":"s","messages":[
          {"id":"u1","timestamp":"2026-06-16T06:28:01.000Z","type":"user","content":[{"text":"hi"}]},
          {"id":"g1","timestamp":"2026-06-16T06:28:05.000Z","type":"gemini","tokens":{"input":10,"output":5,"total":15},"model":"m"},
          {"id":"g2","timestamp":"2026-06-16T06:28:09.000Z","type":"gemini","tokens":{"input":20,"output":6,"total":26},"model":"m"}
        ]}
        """
        let url = URL(fileURLWithPath: "/tmp/test/chats/session-timing.json")
        let result = GeminiUsageParser.parse(data: Data(json.utf8), fileURL: url, projectResolver: stubResolver)

        #expect(result.events.count == 2)
        #expect(result.events[0].generationStartMs == ms("2026-06-16T06:28:01.000Z"))
        #expect(result.events[0].generationEndMs == ms("2026-06-16T06:28:05.000Z"))
        // Second response consumed no fresh user trigger.
        #expect(result.events[1].generationDurationMs == nil)
    }

    @Test
    func generationTimingPairsUserWithNextGeminiResponseInJSONL() throws {
        let jsonl = """
        {"sessionId":"s1","projectHash":"h","startTime":"2026-06-16T06:28:00.000Z","lastUpdated":"2026-06-16T06:30:00.000Z","kind":"main"}
        {"id":"u1","timestamp":"2026-06-16T06:29:00.000Z","type":"user","content":[{"text":"explain"}]}
        {"id":"g1","timestamp":"2026-06-16T06:29:10.000Z","type":"gemini","tokens":{"input":500,"output":200,"total":700},"model":"m"}
        {"id":"u2","timestamp":"2026-06-16T06:29:30.000Z","type":"user","content":[{"text":"more"}]}
        {"id":"g2","timestamp":"2026-06-16T06:29:31.500Z","type":"gemini","tokens":{"input":600,"output":100,"total":700},"model":"m"}
        """
        let url = URL(fileURLWithPath: "/tmp/test/chats/session-timing.jsonl")
        let result = GeminiUsageParser.parse(data: Data(jsonl.utf8), fileURL: url, projectResolver: stubResolver)

        #expect(result.events.count == 2)
        #expect(result.events[0].generationDurationMs == 10_000)
        #expect(result.events[1].generationStartMs == ms("2026-06-16T06:29:30.000Z"))
        #expect(result.events[1].generationDurationMs == 1_500)
    }

    @Test
    func generationTimingIsNeverDerivedFromAdjacentEvents() throws {
        // Consecutive gemini records with no user dispatch: no timing may be
        // estimated from the gap between adjacent response events.
        let jsonl = """
        {"id":"u1","timestamp":"2026-06-16T06:28:00.000Z","type":"user","content":[{"text":"hi"}]}
        {"id":"g1","timestamp":"2026-06-16T06:28:05.000Z","type":"gemini","tokens":{"input":10,"output":5,"total":15},"model":"m"}
        {"id":"g2","timestamp":"2026-06-16T06:29:00.000Z","type":"gemini","tokens":{"input":20,"output":6,"total":26},"model":"m"}
        {"id":"g3","timestamp":"2026-06-16T06:30:00.000Z","type":"gemini","tokens":{"input":30,"output":7,"total":37},"model":"m"}
        """
        let url = URL(fileURLWithPath: "/tmp/test/chats/session-timing.jsonl")
        let result = GeminiUsageParser.parse(data: Data(jsonl.utf8), fileURL: url, projectResolver: stubResolver)

        #expect(result.events.count == 3)
        #expect(result.events[0].generationDurationMs == 5_000)
        #expect(result.events[1].generationStartMs == nil)
        #expect(result.events[2].generationStartMs == nil)
    }

    @Test
    func optionalThoughtsAndToolFields() throws {
        // Token record with only input/output/cached/total (no thoughts or tool)
        let jsonl = """
        {"sessionId":"s1","projectHash":"h","startTime":"2026-01-01T00:00:00Z","lastUpdated":"2026-01-01T00:01:00Z","kind":"main"}
        {"id":"g1","timestamp":"2026-01-01T00:00:30Z","type":"gemini","content":"hi","tokens":{"input":10,"output":5,"cached":2,"total":17},"model":"gemini-flash"}
        """
        let data = Data(jsonl.utf8)
        let url = URL(fileURLWithPath: "/tmp/test/chats/session-test.jsonl")
        let result = GeminiUsageParser.parse(data: data, fileURL: url, projectResolver: stubResolver)

        #expect(result.events.count == 1)
        #expect(result.events[0].reasoningTokens == 0)
        #expect(result.events[0].outputTokens == 5)
        #expect(result.warnings.isEmpty)
    }

    private func ms(_ iso: String) -> Int64 {
        GeminiUsageParser.parseTimestamp(iso)!.tokenBarMillisecondsSince1970
    }

    private enum FixtureError: Error {
        case missing(String)
    }
}
