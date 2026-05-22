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
            .appendingPathComponent("-Users-travis-Documents-TeamFile-claude-workspace-observ-cli", isDirectory: true)
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

        #expect(result.events.map(\.projectName) == ["observ-cli"])
        #expect(result.events.map(\.projectPath) == [nil])
        #expect(result.prompts.map(\.projectName) == ["observ-cli"])
    }

    @Test
    func parserAttributesGeneratedAgentWorktreeCWDToParentProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root
            .appendingPathComponent("-Users-travis-Documents-TeamFile-claude-workspace-observ-cli", isDirectory: true)
            .appendingPathComponent("session-1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"type":"assistant","timestamp":"2026-05-18T10:11:12.000Z","cwd":"/Users/travis/Documents/TeamFile/claude-workspace/observ-cli/.claude/worktrees/agent-a123","sessionId":"s1","message":{"model":"claude-model","usage":{"input_tokens":12,"output_tokens":34,"cache_creation_input_tokens":0,"cache_read_input_tokens":56}}}
        """#.write(to: file, atomically: true, encoding: .utf8)

        let slug = ClaudeDataSource.projectSlug(for: file, rootDirectory: root.path)
        let result = try ClaudeUsageParser.parse(fileURL: file, fallbackProjectSlug: slug)

        #expect(result.events.map(\.projectName) == ["observ-cli"])
        #expect(result.events.map(\.projectPath) == ["/Users/travis/Documents/TeamFile/claude-workspace/observ-cli"])
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
