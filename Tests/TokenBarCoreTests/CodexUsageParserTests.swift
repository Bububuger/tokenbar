import Foundation
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
        #expect(result.events[0].inputTokens == 27_505)
        #expect(result.events[0].cacheTokens == 3_456)
        #expect(result.events[0].outputTokens == 87)
        #expect(result.events[0].reasoningTokens == 54)
        #expect(result.events[1].inputTokens == 27_545)
        #expect(result.events[1].cacheTokens == 27_008)
        #expect(result.events[1].outputTokens == 48)
        #expect(result.events[1].reasoningTokens == 9)
    }

    @Test
    func parserFallsBackToTotalUsageWhenLastUsageIsMissing() throws {
        let result = try CodexUsageParser.parse(fileURL: fixtureURL(named: "session-fallback"))

        #expect(result.events.count == 1)
        #expect(result.events[0].projectName == "knowledge")
        #expect(result.events[0].inputTokens == 11_912)
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
        #expect(result.events[1].inputTokens == 200)
        // Total input must equal sum of distinct payloads, not the doubled raw.
        let totalInput = result.events.reduce(0) { $0 + $1.inputTokens }
        #expect(totalInput == 300)
    }

    private func fixtureURL(named name: String) throws -> URL {
        guard let url = fixtureBundle.url(forResource: name, withExtension: "jsonl") else {
            throw FixtureError.missing(name)
        }
        return url
    }
}

private enum FixtureError: Error {
    case missing(String)
}
