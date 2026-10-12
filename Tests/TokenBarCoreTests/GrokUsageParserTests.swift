import Foundation
import Testing
@testable import TokenBarCore

/// Grok CLI `updates.jsonl` parsing: `turn_completed` rows carry the
/// turn's aggregate ledger. `inputTokens` is the FULL prompt size
/// (uncached + cache reads + cache writes) so fresh input subtracts both
/// cache subsets; `costUsdTicks` is USD × 1e10 and only flows through
/// single-model turns (never summed across model rows).
struct GrokUsageParserTests {
    private static let sessionID = "01a0f582-74e1-7e83-8a16-acd82d9426da"

    /// Stages the committed fixture as
    /// `<tmp>/<encoded-cwd>/<session>/updates.jsonl` + sibling
    /// `summary.json` so project attribution reads the real layout.
    private func stagedFixture(includeSummary: Bool = true) throws -> URL {
        let content = try fixtureContent()
        let encoded = "/Users/work/worktree-copy"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grok-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent(Self.sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("updates.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        if includeSummary {
            try fixtureSummary().write(
                to: tmp.appendingPathComponent("summary.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return file
    }

    private func fixtureContent() throws -> String {
        if let url = fixtureBundle.url(
            forResource: "updates",
            withExtension: "jsonl",
            subdirectory: "Grok"
        ) ?? fixtureBundle.url(forResource: "updates", withExtension: "jsonl") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw GrokFixtureError.missing
    }

    private func fixtureSummary() throws -> String {
        if let url = fixtureBundle.url(
            forResource: "summary",
            withExtension: "json",
            subdirectory: "Grok"
        ) ?? fixtureBundle.url(forResource: "summary", withExtension: "json") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw GrokFixtureError.missing
    }

    private func lines(_ text: String) -> [JSONLLineRecord] {
        text.split(whereSeparator: \.isNewline).enumerated().map { idx, line in
            JSONLLineRecord(text: String(line), lineNumber: idx + 1, startOffset: 0, endOffset: 0)
        }
    }

    private enum GrokFixtureError: Error { case missing }

    @Test
    func parsesTurnCompletedRowsFromStagedFixture() throws {
        let file = try stagedFixture()
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = GrokUsageParser.parse(lines: lines(text), fileURL: file)

        #expect(result.events.count == 2)

        // Turn 1: input 1200 includes cacheRead 400 + cacheCreation 100.
        let e0 = result.events[0]
        #expect(e0.agent == .grok)
        #expect(e0.parser == .grok)
        #expect(e0.id == file.path + "#grok#553c9623-2e6e-407c-a3dc-0dd176b6b65c#grok-4.7-xhigh")
        #expect(e0.inputTokens == 700)
        #expect(e0.outputTokens == 300)
        #expect(e0.cacheReadTokens == 400)
        #expect(e0.cacheCreationTokens == 100)
        #expect(e0.reasoningTokens == 50)
        #expect(e0.actualCostUSD ?? 0 == 1407345000 / 1e10)
        #expect(e0.modelName == "grok-4.7-xhigh")
        #expect(e0.sessionId == Self.sessionID)
        #expect(e0.projectName == "observ-real")
        #expect(e0.projectPath == "/Users/work/observ-real")
        #expect(abs(e0.timestamp.timeIntervalSince1970 - 1788449238) < 0.001)

        // Turn 2: minimal row without cost or cache activity.
        let e1 = result.events[1]
        #expect(e1.id == file.path + "#grok#7b1d0000-aaaa-bbbb-cccc-dddddddddddd#grok-4.6-build")
        #expect(e1.inputTokens == 500)
        #expect(e1.outputTokens == 10)
        #expect(e1.cacheReadTokens == 0)
        #expect(e1.cacheCreationTokens == 0)
        #expect(e1.actualCostUSD == nil)
        #expect(e1.modelName == "grok-4.6-build")

        // One warning: the turn_completed row without usage; the malformed
        // trailing line and non-usage updates are skipped silently.
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("missing usage"))
    }

    @Test
    func fallsBackToUrlDecodedDirectoryWhenSummaryMissing() throws {
        let file = try stagedFixture(includeSummary: false)
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = GrokUsageParser.parse(lines: lines(text), fileURL: file)

        #expect(result.events.count == 2)
        #expect(result.events[0].projectPath == "/Users/work/worktree-copy")
        #expect(result.events[0].projectName == "worktree-copy")
    }

    @Test
    func multiModelTurnEmitsPerModelRowsWithoutSummedCost() {
        let record = """
        {"timestamp":1788449900,"method":"_x.ai/session/update","params":{"sessionId":"sess-multi","update":{"sessionUpdate":"turn_completed","prompt_id":"multi-1","stop_reason":"end_turn","usage":{"inputTokens":1000,"outputTokens":50,"totalTokens":1050,"cachedReadTokens":300,"cacheCreationTokens":0,"reasoningTokens":0,"modelCalls":3,"costUsdTicks":500000000,"modelUsage":{"grok-a":{"inputTokens":700,"outputTokens":30,"cachedReadTokens":300,"modelCalls":2},"grok-b":{"inputTokens":300,"outputTokens":20,"cachedReadTokens":0,"modelCalls":1}}}}}}
        """
        let fileURL = URL(fileURLWithPath: "/tmp/grok-multi/updates.jsonl")
        let result = GrokUsageParser.parse(lines: lines(record), fileURL: fileURL)

        #expect(result.events.count == 2)
        let a = result.events[0]
        let b = result.events[1]
        #expect(a.modelName == "grok-a")
        #expect(a.inputTokens == 400)
        #expect(a.cacheReadTokens == 300)
        #expect(a.outputTokens == 30)
        // Multi-model rows carry no per-row cost: never sum the turn-level
        // figure across models (double counting).
        #expect(a.actualCostUSD == nil)
        #expect(b.modelName == "grok-b")
        #expect(b.inputTokens == 300)
        #expect(b.outputTokens == 20)
        #expect(b.cacheReadTokens == 0)
        #expect(b.actualCostUSD == nil)
        #expect(a.id != b.id)
    }

    @Test
    func singleModelRowWithoutModelUsageFallsBackToTopLevelUsage() {
        let record = """
        {"timestamp":1788449950,"params":{"sessionId":"sess-plain","update":{"sessionUpdate":"turn_completed","prompt_id":"plain-1","usage":{"inputTokens":800,"outputTokens":40,"cachedReadTokens":200,"cacheCreationTokens":0,"reasoningTokens":0,"modelCalls":1,"primaryModelId":"grok-4.7-high","costUsdTicks":250000000}}}}
        """
        let fileURL = URL(fileURLWithPath: "/tmp/grok-plain/updates.jsonl")
        let result = GrokUsageParser.parse(lines: lines(record), fileURL: fileURL)

        #expect(result.events.count == 1)
        let e = result.events[0]
        #expect(e.inputTokens == 600)
        #expect(e.outputTokens == 40)
        #expect(e.cacheReadTokens == 200)
        #expect(e.modelName == "grok-4.7-high")
        #expect(e.actualCostUSD ?? 0 == 250000000 / 1e10)
        #expect(e.id == fileURL.path + "#grok#plain-1")
    }
}
