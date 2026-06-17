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

    private enum FixtureError: Error {
        case missing(String)
    }
}
