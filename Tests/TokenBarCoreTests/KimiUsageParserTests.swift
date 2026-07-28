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

    @Test
    func parsesCurrentMainAndSubagentUsageWithSessionState() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root
            .appendingPathComponent("sessions/work-key/session_1234", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try #"{"workDir":"/work/projects/moon"}"#
            .write(to: session.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

        let mainFile = try writeWire(
            under: session,
            agentID: "main",
            content: """
            {"type":"context.append_loop_event","usageScope":"turn","time":1785200000000,"usage":{"inputOther":999,"output":999,"inputCacheRead":999,"inputCacheCreation":999},"event":{"usage":{"inputOther":999,"output":999,"inputCacheRead":999,"inputCacheCreation":999}}}
            {"type":"usage.record","usageScope":"session","time":1785200000500,"model":"kimi-for-coding","usage":{"inputOther":8,"output":9,"inputCacheRead":10,"inputCacheCreation":11}}
            {"type":"usage.record","usageScope":"turn","time":1785200001000,"model":"kimi-k2.5","usage":{"inputOther":11,"output":22,"inputCacheRead":33,"inputCacheCreation":44}}
            {"type":"usage.record","time":1785200001500,"model":"kimi-for-coding","usage":{"inputOther":1,"output":2,"inputCacheRead":3,"inputCacheCreation":4}}
            {"type":"usage.record","usageScope":"request","time":1785200001750,"model":"ignored","usage":{"inputOther":777,"output":777,"inputCacheRead":777,"inputCacheCreation":777}}
            """
        )
        let subagentFile = try writeWire(
            under: session,
            agentID: "researcher",
            content: """
            {"type":"usage.record","usageScope":"turn","time":1785200002000,"model":"kimi-k2.5","usage":{"inputOther":5,"output":6,"inputCacheRead":7,"inputCacheCreation":8}}
            """
        )

        let discovered = try KimiDataSource.discoverSessionFiles(rootDirectory: root.path)
        #expect(discovered.map(standardizedPath) == [mainFile, subagentFile].map(standardizedPath).sorted())

        let main = KimiUsageParser.parse(
            lines: lines(try String(contentsOf: mainFile, encoding: .utf8)),
            fileURL: mainFile
        )
        #expect(main.events.count == 3)
        let compaction = main.events[0]
        #expect(compaction.inputTokens == 8)
        #expect(compaction.outputTokens == 9)
        #expect(compaction.cacheReadTokens == 10)
        #expect(compaction.cacheCreationTokens == 11)
        #expect(compaction.modelName == "kimi-for-coding")
        #expect(compaction.id == "\(mainFile.path)#kimi#line-2")

        let event = main.events[1]
        #expect(event.inputTokens == 11)
        #expect(event.outputTokens == 22)
        #expect(event.cacheReadTokens == 33)
        #expect(event.cacheCreationTokens == 44)
        #expect(total(event) == 110)
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_785_200_001))
        #expect(event.modelName == "kimi-k2.5")
        #expect(event.sessionId == "session_1234")
        #expect(event.projectPath == "/work/projects/moon")
        #expect(event.projectName == "moon")
        #expect(event.id == "\(mainFile.path)#kimi#line-3")

        let missingScope = main.events[2]
        #expect(missingScope.inputTokens == 1)
        #expect(missingScope.outputTokens == 2)
        #expect(missingScope.cacheReadTokens == 3)
        #expect(missingScope.cacheCreationTokens == 4)
        #expect(missingScope.id == "\(mainFile.path)#kimi#line-4")

        let repeated = KimiUsageParser.parse(
            lines: lines(try String(contentsOf: mainFile, encoding: .utf8)),
            fileURL: mainFile
        )
        let subagent = KimiUsageParser.parse(
            lines: lines(try String(contentsOf: subagentFile, encoding: .utf8)),
            fileURL: subagentFile
        )
        #expect(repeated.events.map(\.id) == main.events.map(\.id))
        #expect(subagent.events.first?.id != event.id)
        #expect(subagent.events.first?.sessionId == "session_1234")
        #expect(subagent.events.first?.projectPath == "/work/projects/moon")
    }

    @Test
    func legacyRowsRemainSupportedWithCwdFallback() {
        let file = URL(fileURLWithPath: "/tmp/legacy-session/wire.jsonl")
        let result = KimiUsageParser.parse(
            lines: lines("""
            {"id":"legacy-id","role":"assistant","timestamp":"2026-05-31T09:00:01.000Z","cwd":"/legacy/project","model":"legacy-model","input_other":9,"output":8,"input_cache_read":7,"input_cache_creation":6}
            {"message_id":"legacy-message-id","role":"assistant","timestamp":"2026-05-31T09:00:02.000Z","cwd":"/legacy/project","model":"legacy-model","input_other":1,"output":1,"input_cache_read":0,"input_cache_creation":0}
            """),
            fileURL: file
        )

        #expect(result.events.count == 2)
        #expect(result.events.first?.inputTokens == 9)
        #expect(result.events.first?.outputTokens == 8)
        #expect(result.events.first?.cacheReadTokens == 7)
        #expect(result.events.first?.cacheCreationTokens == 6)
        #expect(result.events.first?.sessionId == "legacy-session")
        #expect(result.events.first?.projectPath == "/legacy/project")
        #expect(result.events.first?.projectName == "project")
        #expect(result.events.first?.id == "\(file.path)#kimi#legacy-id")
        #expect(result.events.last?.id == "\(file.path)#kimi#legacy-message-id")
    }

    @Test
    func currentUsageFallsBackToStateCustomCwd() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root
            .appendingPathComponent("sessions/work-key/session_custom", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try #"{"custom":{"cwd":"/repo/foo"}}"#
            .write(to: session.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        let file = try writeWire(
            under: session,
            agentID: "main",
            content: """
            {"type":"usage.record","usageScope":"turn","time":1785200001000,"model":"kimi-k2.5","usage":{"inputOther":1,"output":2,"inputCacheRead":3,"inputCacheCreation":4}}
            """
        )

        let result = KimiUsageParser.parse(
            lines: lines(try String(contentsOf: file, encoding: .utf8)),
            fileURL: file
        )

        #expect(result.events.count == 1)
        #expect(result.events.first?.projectPath == "/repo/foo")
        #expect(result.events.first?.projectName == "foo")
    }

    @Test
    func resolvesDefaultRootsFromEnvironmentAndRetainsLegacyRoot() {
        let roots = KimiDataSource.resolvedRootDirectories(
            environment: ["KIMI_CODE_HOME": "/custom/kimi-code"],
            homeDirectory: "/test/home"
        )
        #expect(roots == ["/custom/kimi-code", "/test/home/.kimi"])

        let fallback = KimiDataSource.resolvedRootDirectories(
            environment: [:],
            homeDirectory: "/test/home"
        )
        #expect(fallback == ["/test/home/.kimi-code", "/test/home/.kimi"])

        let deduplicated = KimiDataSource.resolvedRootDirectories(
            environment: ["KIMI_CODE_HOME": "/test/home/.kimi"],
            homeDirectory: "/test/home"
        )
        #expect(deduplicated == ["/test/home/.kimi"])
    }

    @Test
    func customRootDiscoveryIsIsolatedFromDefaults() throws {
        let sandbox = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let custom = sandbox.appendingPathComponent("custom", isDirectory: true)
        let environmentRoot = sandbox.appendingPathComponent("env", isDirectory: true)

        let defaultNew = try writeLegacyWire(root: home.appendingPathComponent(".kimi-code"), sessionID: "default-new")
        let legacy = try writeLegacyWire(root: home.appendingPathComponent(".kimi"), sessionID: "legacy")
        let environment = try writeLegacyWire(root: environmentRoot, sessionID: "environment")
        let customFile = try writeLegacyWire(root: custom, sessionID: "custom")

        let defaults = try KimiDataSource.discoverSessionFiles(
            environment: ["KIMI_CODE_HOME": environmentRoot.path],
            homeDirectory: home.path
        )
        #expect(defaults.map(standardizedPath) == [environment, legacy].map(standardizedPath).sorted())
        #expect(!defaults.map(standardizedPath).contains(standardizedPath(defaultNew)))

        let isolated = try KimiDataSource.discoverSessionFiles(
            rootDirectory: custom.path,
            environment: ["KIMI_CODE_HOME": environmentRoot.path],
            homeDirectory: home.path
        )
        #expect(isolated.map(standardizedPath) == [standardizedPath(customFile)])
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/KimiTests", isDirectory: true)
            .appendingPathComponent("kimi-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func writeWire(under session: URL, agentID: String, content: String) throws -> URL {
        let directory = session
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("wire.jsonl")
        try (content + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func writeLegacyWire(root: URL, sessionID: String) throws -> URL {
        let directory = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("wire.jsonl")
        try #"{"input_other":1,"output":1,"input_cache_read":0,"input_cache_creation":0}"#
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func total(_ e: UsageEvent) -> Int {
        e.inputTokens + e.outputTokens + e.cacheReadTokens + e.cacheCreationTokens + (e.reasoningTokens ?? 0)
    }
}

private enum KimiFixtureError: Error { case missing }
