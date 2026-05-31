import Foundation
import Testing
@testable import TokenBarCore

/// Loads Subagent A's committed fixture
/// `Tests/TokenBarCoreTests/Fixtures/Kiro/kiro-data.sqlite3` and asserts the
/// exact normalized 6-tuples from kiro-验收.md (inputIncludesCached = false).
struct KiroUsageParserTests {
    private func fixtureURL() throws -> URL {
        guard let url = fixtureBundle.url(forResource: "kiro-data", withExtension: "sqlite3", subdirectory: "Kiro")
            ?? fixtureBundle.url(forResource: "kiro-data", withExtension: "sqlite3") else {
            throw KiroFixtureError.missing
        }
        return url
    }

    @Test
    func parsesKiroConversationHistoryAndSkipsZeroTurns() throws {
        let result = try KiroUsageParser.parse(databaseURL: try fixtureURL())

        // history has 3 assistant turns (k1/k2 non-zero, k3 all-zero → skipped).
        #expect(result.events.count == 2)

        let events = result.events
        // k1: 900/150/200/80, total 1330
        let k1 = events[0]
        #expect(k1.agent == .kiro)
        #expect(k1.parser == .kiro)
        #expect(k1.inputTokens == 900)
        #expect(k1.outputTokens == 150)
        #expect(k1.cacheReadTokens == 200)
        #expect(k1.cacheCreationTokens == 80)
        #expect(k1.reasoningTokens == nil)
        #expect(total(k1) == 1330)
        #expect(k1.modelName == "claude-sonnet-4.5")
        #expect(k1.sessionId == "33333333-dddd-eeee-ffff-444444444444")

        // k2: 300/60/0/0, total 360
        let k2 = events[1]
        #expect(k2.inputTokens == 300)
        #expect(k2.outputTokens == 60)
        #expect(k2.cacheReadTokens == 0)
        #expect(k2.cacheCreationTokens == 0)
        #expect(total(k2) == 360)
        #expect(k2.modelName == "claude-sonnet-4.5")

        #expect(result.warnings.isEmpty)
    }

    private func total(_ e: UsageEvent) -> Int {
        e.inputTokens + e.outputTokens + e.cacheReadTokens + e.cacheCreationTokens + (e.reasoningTokens ?? 0)
    }
}

private enum KiroFixtureError: Error { case missing }
