import Foundation
import Testing
@testable import TokenBarCore

/// Loads Subagent A's committed fixture
/// `Tests/TokenBarCoreTests/Fixtures/Kimi/<uuid>/wire.jsonl` and asserts the
/// exact normalized 6-tuples from kimi-验收.md (inputIncludesCached = false).
struct KimiUsageParserTests {
    private static let sessionUUID = "0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d"

    /// Re-stages the fixture under a deterministic `<uuid>/wire.jsonl` path so
    /// sessionId (= parent dir UUID) is stable regardless of how the test
    /// bundle lays out resources.
    private func stagedFixture() throws -> URL {
        let content = try fixtureContent()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kimi-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(Self.sessionUUID, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("wire.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func fixtureContent() throws -> String {
        if let url = fixtureBundle.url(
            forResource: "wire",
            withExtension: "jsonl",
            subdirectory: "Kimi/\(Self.sessionUUID)"
        ) ?? fixtureBundle.url(forResource: "wire", withExtension: "jsonl") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw KimiFixtureError.missing
    }

    private func lines(_ text: String) -> [JSONLLineRecord] {
        text.split(whereSeparator: \.isNewline).enumerated().map { idx, line in
            JSONLLineRecord(text: String(line), lineNumber: idx + 1, startOffset: 0, endOffset: 0)
        }
    }

    @Test
    func parsesKimiFlatUsageRows() throws {
        let file = try stagedFixture()
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = KimiUsageParser.parse(lines: lines(text), fileURL: file)

        #expect(result.events.count == 2)

        // line 1: 1200/300/400/100, total 2000
        let e0 = result.events[0]
        #expect(e0.agent == .kimi)
        #expect(e0.parser == .kimi)
        #expect(e0.inputTokens == 1200)
        #expect(e0.outputTokens == 300)
        #expect(e0.cacheReadTokens == 400)
        #expect(e0.cacheCreationTokens == 100)
        #expect(e0.reasoningTokens == nil)
        #expect(total(e0) == 2000)
        #expect(e0.sessionId == Self.sessionUUID)
        #expect(e0.projectName == "kimi")
        #expect(e0.modelName == "kimi-k2-0711-preview")

        // line 2: 50/10/0/0, total 60
        let e1 = result.events[1]
        #expect(e1.inputTokens == 50)
        #expect(e1.outputTokens == 10)
        #expect(e1.cacheReadTokens == 0)
        #expect(e1.cacheCreationTokens == 0)
        #expect(total(e1) == 60)

        #expect(result.warnings.isEmpty)
    }

    @Test
    func skipsZeroAndEmptyLines() {
        let records = lines(#"{"role":"assistant","input_other":0,"output":0,"input_cache_read":0,"input_cache_creation":0}"#)
        let result = KimiUsageParser.parse(
            lines: records,
            fileURL: URL(fileURLWithPath: "/tmp/\(Self.sessionUUID)/wire.jsonl")
        )
        #expect(result.events.isEmpty)
    }

    private func total(_ e: UsageEvent) -> Int {
        e.inputTokens + e.outputTokens + e.cacheReadTokens + e.cacheCreationTokens + (e.reasoningTokens ?? 0)
    }
}

private enum KimiFixtureError: Error { case missing }
