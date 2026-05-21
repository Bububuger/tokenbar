import Foundation
import Testing
@testable import TokenBarCore

struct ClaudeUsageParserTests {
    @Test
    func claudeFixturesAreLoadable() throws {
        #expect(try fixtureURL(named: "claude-session-valid").isFileURL)
        #expect(try fixtureURL(named: "claude-session-malformed").isFileURL)
    }

    @Test
    func parserEmitsUsageEventsFromClaudeAssistantMessages() throws {
        let result = try ClaudeUsageParser.parse(
            fileURL: fixtureURL(named: "claude-session-valid"),
            fallbackProjectSlug: "-Users-javis-Documents-workspace-openclaw"
        )

        #expect(result.events.count == 2)
        #expect(result.warnings.isEmpty)
        #expect(result.events[0].agent == .claudeCode)
        #expect(result.events[0].projectName == "openclaw")
        #expect(result.events[0].inputTokens == 10)
        #expect(result.events[0].outputTokens == 8)
        #expect(result.events[0].cacheTokens == 27_658)
        #expect(result.events[1].cacheTokens == 30_000)
        #expect(result.events[0].modelName == "claude-sonnet-4-5-20250929")
        #expect(result.events[1].modelName == "claude-sonnet-4-5-20250929")
    }

    @Test
    func parserReportsWarningsForMalformedAndIncompleteRecords() throws {
        let result = try ClaudeUsageParser.parse(
            fileURL: fixtureURL(named: "claude-session-malformed"),
            fallbackProjectSlug: "-Users-javis-Documents-workspace-openclaw"
        )

        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 2)
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
