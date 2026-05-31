import Foundation
import Testing
@testable import TokenBarCore

/// Loads Subagent A's committed fixture
/// `Tests/TokenBarCoreTests/Fixtures/Qoder/qoder-local.db` and asserts the exact
/// normalized 6-tuples from CONTRACT.md / qoder-验收.md.
struct QoderUsageParserTests {
    private func fixtureURL() throws -> URL {
        guard let url = fixtureBundle.url(forResource: "qoder-local", withExtension: "db", subdirectory: "Qoder")
            ?? fixtureBundle.url(forResource: "qoder-local", withExtension: "db") else {
            throw QoderFixtureError.missing
        }
        return url
    }

    @Test
    func parsesQoderRowsWithInputIncludesCachedClamp() throws {
        let result = try QoderUsageParser.parse(databaseURL: try fixtureURL())

        // m1/m2/m3 produce events; m4 (empty token_info) is skipped → 3 events.
        #expect(result.events.count == 3)

        let byModelAndInput = result.events.sorted { $0.timestamp < $1.timestamp }

        // m1: prompt 21512, completion 87, cached 15104, inputIncludesCached=true
        // → input 6408, output 87, cacheRead 15104, cacheCreation 0, total 21599
        let m1 = byModelAndInput[0]
        #expect(m1.agent == .qoder)
        #expect(m1.parser == .qoder)
        #expect(m1.inputTokens == 6408)
        #expect(m1.outputTokens == 87)
        #expect(m1.cacheReadTokens == 15104)
        #expect(m1.cacheCreationTokens == 0)
        #expect(m1.reasoningTokens == nil)
        #expect(total(m1) == 21599)
        #expect(m1.modelName == "claude-sonnet-4.5")
        #expect(m1.projectName == "demo-app")

        // m2: prompt 1000, completion 200, cached 0 → 1000/200/0/0, total 1200
        let m2 = byModelAndInput[1]
        #expect(m2.inputTokens == 1000)
        #expect(m2.outputTokens == 200)
        #expect(m2.cacheReadTokens == 0)
        #expect(m2.cacheCreationTokens == 0)
        #expect(total(m2) == 1200)
        #expect(m2.modelName == "gpt-5")

        // m3: prompt 500, completion 50, cached 800 → cached clamped to 500,
        // input 0, output 50, cacheRead 500, total 550
        let m3 = byModelAndInput[2]
        #expect(m3.inputTokens == 0)
        #expect(m3.outputTokens == 50)
        #expect(m3.cacheReadTokens == 500)
        #expect(m3.cacheCreationTokens == 0)
        #expect(total(m3) == 550)

        #expect(result.warnings.isEmpty)
    }

    private func total(_ e: UsageEvent) -> Int {
        e.inputTokens + e.outputTokens + e.cacheReadTokens + e.cacheCreationTokens + (e.reasoningTokens ?? 0)
    }
}

private enum QoderFixtureError: Error { case missing }
