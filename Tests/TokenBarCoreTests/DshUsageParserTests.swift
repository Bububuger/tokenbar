import Foundation
import Testing
@testable import TokenBarCore

/// Parses the committed DSH fixtures under Fixtures/dsh and asserts the
/// exact usage tuples, model attribution, prompt filtering, and id
/// stability documented in docs/work-items/2026-10-03-dsh-datasource/.
struct DshUsageParserTests {
    private static let sessionID = "session-abc12345-0000-0000-0000-000000000000"
    private static let legacySessionID = "session-old12345-0000-0000-0000-000000000000"

    private func stagedFixture(_ resource: String, ext: String, session: String) throws -> URL {
        guard let url = fixtureBundle.url(
            forResource: resource,
            withExtension: ext,
            subdirectory: "dsh"
        ) ?? fixtureBundle.url(forResource: resource, withExtension: ext) else {
            throw DshFixtureError.missing
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("dsh-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent(resource + "." + ext)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func lines(_ text: String) -> [JSONLLineRecord] {
        text.split(whereSeparator: { $0 == "\n" }).enumerated().map { idx, line in
            JSONLLineRecord(text: String(line), lineNumber: idx + 1, startOffset: 0, endOffset: 0)
        }
    }

    @Test
    func parsesV4SessionWithModelSwitchAndPromptFiltering() throws {
        let file = try stagedFixture("dsh-v4", ext: "jsonl", session: Self.sessionID)
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = DshUsageParser.parse(lines: lines(text), fileURL: file)

        // assistant/attempt (all-zero usage mirror) must not count.
        #expect(result.events.count == 2)

        let first = result.events[0]
        #expect(first.agent == .dsh)
        #expect(first.parser == .dsh)
        #expect(first.inputTokens == 12588)
        #expect(first.outputTokens == 321)
        #expect(first.cacheReadTokens == 0)
        #expect(first.cacheCreationTokens == 0)
        #expect(first.modelName == "gpt-6-astra")
        #expect(first.sessionId == Self.sessionID)
        #expect(first.projectPath == "/Users/travis/proj/observ")
        #expect(first.projectName == "observ")
        // Ids are seq-keyed so a full re-read never double-counts.
        #expect(first.id.hasSuffix("#dsh#" + Self.sessionID + "#4"))

        let second = result.events[1]
        #expect(second.inputTokens == 6677)
        #expect(second.outputTokens == 858)
        #expect(second.cacheReadTokens == 22016)
        #expect(second.cacheCreationTokens == 0)
        // Mid-session model switch is attributed per message.
        #expect(second.modelName == "GLM-5.3")
        #expect(second.id.hasSuffix("#dsh#" + Self.sessionID + "#6"))

        // One human prompt; the skill-catalog injection is filtered.
        #expect(result.prompts.count == 1)
        #expect(result.prompts[0].content == "帮我看看这个仓库")
        #expect(result.prompts[0].sessionId == Self.sessionID)
        #expect(result.prompts[0].projectName == "observ")

        #expect(result.warnings.isEmpty)
    }

    @Test
    func parsesLegacyV0SessionWithReasoningTokens() throws {
        let file = try stagedFixture("dsh-legacy", ext: "jsonl", session: Self.legacySessionID)
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = DshUsageParser.parse(lines: lines(text), fileURL: file)

        #expect(result.events.count == 1)
        let event = result.events[0]
        #expect(event.inputTokens == 4767)
        #expect(event.outputTokens == 169)
        #expect(event.cacheReadTokens == 7296)
        #expect(event.cacheCreationTokens == 0)
        // Legacy v0 carries reasoningTokens; v4 does not.
        #expect(event.reasoningTokens == 135)
        #expect(event.modelName == "deepseek-v4-flash")
        #expect(event.projectName == "api")

        #expect(result.prompts.count == 1)
        #expect(result.prompts[0].content == "旧格式问题")
    }

    @Test
    func skipsDegenerateUsageRows() {
        let records = lines(
            "{\"type\":\"assistant/message\",\"seq\":9,\"time\":1790000000000,\"data\":{\"usage\":{\"inputTokens\":0,\"outputTokens\":0,\"totalTokens\":0}}}"
        )
        let result = DshUsageParser.parse(
            lines: records,
            fileURL: URL(fileURLWithPath: "/tmp/dsh/" + Self.sessionID + "/session.v4.jsonl.zstd")
        )
        #expect(result.events.isEmpty)
    }

    @Test
    func reparseIsIdempotent() throws {
        let file = try stagedFixture("dsh-v4", ext: "jsonl", session: Self.sessionID)
        let text = try String(contentsOf: file, encoding: .utf8)
        let first = DshUsageParser.parse(lines: lines(text), fileURL: file)
        let second = DshUsageParser.parse(lines: lines(text), fileURL: file)
        #expect(first.events == second.events)
        #expect(first.prompts == second.prompts)
    }
}

enum DshFixtureError: Error {
    case missing
}
