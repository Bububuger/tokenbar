import Foundation
import Testing
@testable import TokenBarCore

/// Loads Subagent A's committed fixture
/// `Tests/TokenBarCoreTests/Fixtures/Antigravity/<uuid>/session.jsonl` and
/// asserts the exact normalized 6-tuples from antigravity-验收.md
/// (inputIncludesCached = false; the all-zero row is skipped).
struct AntigravityUsageParserTests {
    private static let sessionUUID = "9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6"

    private func stagedFixture() throws -> URL {
        let content = try fixtureContent()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("antigravity-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(Self.sessionUUID, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("session.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func fixtureContent() throws -> String {
        if let url = fixtureBundle.url(
            forResource: "session",
            withExtension: "jsonl",
            subdirectory: "Antigravity/\(Self.sessionUUID)"
        ) ?? fixtureBundle.url(forResource: "session", withExtension: "jsonl") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw AntigravityFixtureError.missing
    }

    private func lines(_ text: String) -> [JSONLLineRecord] {
        text.split(whereSeparator: \.isNewline).enumerated().map { idx, line in
            JSONLLineRecord(text: String(line), lineNumber: idx + 1, startOffset: 0, endOffset: 0)
        }
    }

    @Test
    func parsesAntigravityRowAndSkipsZeroRow() throws {
        let file = try stagedFixture()
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = AntigravityUsageParser.parse(lines: lines(text), fileURL: file)

        // line 1 non-zero, line 2 all-zero → skipped → 1 event.
        #expect(result.events.count == 1)

        // line 1: 800/120/60/40, total 1020
        let e0 = result.events[0]
        #expect(e0.agent == .antigravity)
        #expect(e0.parser == .antigravity)
        #expect(e0.inputTokens == 800)
        #expect(e0.outputTokens == 120)
        #expect(e0.cacheReadTokens == 60)
        #expect(e0.cacheCreationTokens == 40)
        #expect(e0.reasoningTokens == nil)
        #expect(total(e0) == 1020)
        #expect(e0.sessionId == Self.sessionUUID)
        #expect(e0.modelName == "gemini-2.5-pro")

        #expect(result.warnings.isEmpty)
    }

    private func total(_ e: UsageEvent) -> Int {
        e.inputTokens + e.outputTokens + e.cacheReadTokens + e.cacheCreationTokens + (e.reasoningTokens ?? 0)
    }
}

private enum AntigravityFixtureError: Error { case missing }
