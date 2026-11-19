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

    /// Real agy/antigravity-cli lines carry `created_at` instead of
    /// `timestamp`; both spellings must produce a real event date.
    /// A valid `timestamp` always wins over `created_at` regardless of type.
    @Test
    func parsesCreatedAtAsTimestampFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-ts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.jsonl")
        let text = """
        {"id":"iso-frac","created_at":"2027-01-15T08:56:07.890Z","input_tokens":10,"output_tokens":5}
        {"id":"iso-plain","created_at":"2027-01-15T08:56:07Z","input_tokens":10,"output_tokens":5}
        {"id":"epoch-ms","created_at":1800000000000,"input_tokens":10,"output_tokens":5}
        {"id":"both-num-ts-iso-ca","timestamp":1700000000000,"created_at":"2027-01-15T08:56:07.890Z","input_tokens":10,"output_tokens":5}
        {"id":"both-iso-ts-num-ca","timestamp":"2023-11-14T22:13:20Z","created_at":1800000000000,"input_tokens":10,"output_tokens":5}
        {"id":"invalid-ts-valid-ca","timestamp":"not-a-date","created_at":1800000000000,"input_tokens":10,"output_tokens":5}
        {"id":"none","input_tokens":10,"output_tokens":5}
        """
        try text.write(to: file, atomically: true, encoding: .utf8)

        let result = AntigravityUsageParser.parse(lines: lines(text), fileURL: file)
        #expect(result.events.count == 7)
        let byId = Dictionary(uniqueKeysWithValues: result.events.map { ($0.id, $0) })

        let isoFrac = try #require(ISO8601Fast.parseUTC("2027-01-15T08:56:07.890Z"))
        let isoPlain = try #require(ISO8601Fast.parseUTC("2027-01-15T08:56:07Z"))
        let epochMs = Date(timeIntervalSince1970: 1_800_000_000)
        let tsEpoch = Date(timeIntervalSince1970: 1_700_000_000)
        let tsIso = try #require(ISO8601Fast.parseUTC("2023-11-14T22:13:20Z"))

        #expect(byId["\(file.path)#antigravity#iso-frac"]?.timestamp == isoFrac)
        #expect(byId["\(file.path)#antigravity#iso-plain"]?.timestamp == isoPlain)
        #expect(byId["\(file.path)#antigravity#epoch-ms"]?.timestamp == epochMs)
        // Numeric timestamp beats ISO created_at.
        #expect(byId["\(file.path)#antigravity#both-num-ts-iso-ca"]?.timestamp == tsEpoch)
        // ISO timestamp beats numeric created_at (must not prefer any-number-first).
        #expect(byId["\(file.path)#antigravity#both-iso-ts-num-ca"]?.timestamp == tsIso)
        // Unparseable timestamp falls back to created_at.
        #expect(byId["\(file.path)#antigravity#invalid-ts-valid-ca"]?.timestamp == epochMs)
        #expect(byId["\(file.path)#antigravity#none"]?.timestamp == .distantPast)
        #expect(tsIso == tsEpoch)
    }

    private func total(_ e: UsageEvent) -> Int {
        e.inputTokens + e.outputTokens + e.cacheReadTokens + e.cacheCreationTokens + (e.reasoningTokens ?? 0)
    }
}

private enum AntigravityFixtureError: Error { case missing }
