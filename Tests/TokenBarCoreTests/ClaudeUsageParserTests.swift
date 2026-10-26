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

    @Test
    func parserAttributesSubagentFilesToParentProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root
            .appendingPathComponent("-Users-dev-Documents-workspace-projects-my-cli-tool", isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-a123.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try [
            #"{"type":"user","timestamp":"2026-05-18T10:11:11.000Z","cwd":"/tmp/agent-a123","sessionId":"s1","message":{"role":"user","content":"inspect source attribution"}}"#,
            #"{"type":"assistant","timestamp":"2026-05-18T10:11:12.000Z","cwd":"/tmp/agent-a123","sessionId":"s1","message":{"model":"claude-model","usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":0,"cache_read_input_tokens":56}}}"#,
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let slug = ClaudeDataSource.projectSlug(for: file, rootDirectory: root.path)
        let result = try ClaudeUsageParser.parse(fileURL: file, fallbackProjectSlug: slug)

        #expect(result.events.map(\.projectName) == ["my-cli-tool"])
        #expect(result.events.map(\.projectPath) == [nil])
        #expect(result.prompts.map(\.projectName) == ["my-cli-tool"])
    }

    @Test
    func parserAttributesGeneratedAgentWorktreeCWDToParentProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root
            .appendingPathComponent("-Users-dev-Documents-workspace-projects-my-cli-tool", isDirectory: true)
            .appendingPathComponent("session-1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"type":"assistant","timestamp":"2026-05-18T10:11:12.000Z","cwd":"/Users/dev/Documents/workspace/projects/my-cli-tool/.claude/worktrees/agent-a123","sessionId":"s1","message":{"model":"claude-model","usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":0,"cache_read_input_tokens":56}}}
        """#.write(to: file, atomically: true, encoding: .utf8)

        let slug = ClaudeDataSource.projectSlug(for: file, rootDirectory: root.path)
        let result = try ClaudeUsageParser.parse(fileURL: file, fallbackProjectSlug: slug)

        #expect(result.events.map(\.projectName) == ["my-cli-tool"])
        #expect(result.events.map(\.projectPath) == ["/Users/dev/Documents/workspace/projects/my-cli-tool"])
    }

    @Test
    func generationTimingPairsAssistantWithItsUserParentUuid() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try [
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-18T10:00:00.000Z","cwd":"/tmp/p","sessionId":"s1","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-05-18T10:00:02.500Z","cwd":"/tmp/p","sessionId":"s1","message":{"role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let result = try ClaudeUsageParser.parse(fileURL: file, fallbackProjectSlug: "p")
        #expect(result.events.count == 1)
        let event = result.events[0]
        #expect(event.generationStartMs == ms("2026-05-18T10:00:00.000Z"))
        #expect(event.generationEndMs == ms("2026-05-18T10:00:02.500Z"))
        #expect(event.generationDurationMs == 2_500)
    }

    @Test
    func generationTimingIsNilForMissingOrReversedParent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try [
            // Parent record timestamped AFTER the child: not a valid window.
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-18T10:00:10.000Z","cwd":"/tmp/p","sessionId":"s1","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-05-18T10:00:02.500Z","cwd":"/tmp/p","sessionId":"s1","message":{"role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            // parentUuid points at a record that never appears in this file.
            #"{"type":"assistant","uuid":"a2","parentUuid":"absent","timestamp":"2026-05-18T10:00:03.000Z","cwd":"/tmp/p","sessionId":"s1","message":{"role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
            // No parentUuid at all.
            #"{"type":"assistant","uuid":"a3","timestamp":"2026-05-18T10:00:04.000Z","cwd":"/tmp/p","sessionId":"s1","message":{"role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let result = try ClaudeUsageParser.parse(fileURL: file, fallbackProjectSlug: "p")
        #expect(result.events.count == 3)
        #expect(result.events.allSatisfy { $0.generationDurationMs == nil })
    }

    private func ms(_ iso: String) -> Int64 {
        ClaudeUsageParser.parseTimestamp(iso)!.tokenBarMillisecondsSince1970
    }

    private func fixtureURL(named name: String) throws -> URL {
        guard let url = fixtureBundle.url(forResource: name, withExtension: "jsonl") else {
            throw FixtureError.missing(name)
        }
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: root,
            create: true
        )
    }
}

private enum FixtureError: Error {
    case missing(String)
}
