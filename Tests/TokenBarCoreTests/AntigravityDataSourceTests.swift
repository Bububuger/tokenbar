import Foundation
import Testing
@testable import TokenBarCore

struct AntigravityDataSourceTests {
    /// Session boundary: find `brain/<id>/.system_generated/logs/transcript*.jsonl`
    /// and normal non-hidden sessions; ignore other hidden noise even when it
    /// carries token fields. Discovery → parse must emit events only for the
    /// allowed paths.
    @Test
    func discoversSessionsParsesTokensAndIgnoresHiddenNoise() throws {
        DiscoveryCache.reset()
        let root = try temporaryDirectory()

        let hiddenLogs = root.appendingPathComponent(
            "brain/9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6/.system_generated/logs",
            isDirectory: true
        )
        let plainDir = root.appendingPathComponent(
            "brain/1a2b3c4d-plain/sessions",
            isDirectory: true
        )
        let cacheDir = root.appendingPathComponent(".cache", isDirectory: true)
        let backupDir = root.appendingPathComponent(".backup", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let transcript = hiddenLogs.appendingPathComponent("transcript-1.jsonl")
        let session = plainDir.appendingPathComponent("session.jsonl")
        let cacheNoise = cacheDir.appendingPathComponent("x.jsonl")
        let backupNoise = backupDir.appendingPathComponent("transcript.jsonl")

        let transcriptBody = """
        {"id":"hidden-ok","timestamp":1700000000000,"input_tokens":11,"output_tokens":2}
        {"id":"no-usage","timestamp":1700000001000,"model":"gemini-2.5-pro"}
        """
        let sessionBody = """
        {"id":"plain-ok","timestamp":1700000002000,"input_tokens":7,"output_tokens":3}
        {"id":"plain-zero","timestamp":1700000003000,"input_tokens":0,"output_tokens":0}
        """
        let noiseBody = """
        {"id":"noise","timestamp":1700000004000,"input_tokens":99,"output_tokens":99}
        """
        try transcriptBody.write(to: transcript, atomically: true, encoding: .utf8)
        try sessionBody.write(to: session, atomically: true, encoding: .utf8)
        try noiseBody.write(to: cacheNoise, atomically: true, encoding: .utf8)
        try noiseBody.write(to: backupNoise, atomically: true, encoding: .utf8)

        let files = try AntigravityDataSource.discoverSessionFiles(roots: [root.path])
        let discovered = Set(files.map(\.standardizedFileURL.path))
        #expect(discovered == Set([transcript, session].map(\.standardizedFileURL.path)))
        #expect(!discovered.contains(cacheNoise.standardizedFileURL.path))
        #expect(!discovered.contains(backupNoise.standardizedFileURL.path))

        var events: [UsageEvent] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let records = text.split(whereSeparator: \.isNewline).enumerated().map { idx, line in
                JSONLLineRecord(text: String(line), lineNumber: idx + 1, startOffset: 0, endOffset: 0)
            }
            events.append(contentsOf: AntigravityUsageParser.parse(lines: records, fileURL: file).events)
        }

        let ids = Set(events.map(\.id))
        let expectedIDs: Set<String> = [
            "\(transcript.path)#antigravity#hidden-ok",
            "\(session.path)#antigravity#plain-ok",
        ]
        #expect(ids == expectedIDs)
        let tokenTotal = events.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        #expect(tokenTotal == 23)
        let hasNoise = ids.contains(where: { $0.contains("noise") })
        #expect(!hasNoise)
    }

    @Test
    func deduplicatesRootsThatResolveToSameDirectory() throws {
        DiscoveryCache.reset()
        let base = try temporaryDirectory()
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("session.jsonl")
        try Data("{}".utf8).write(to: file)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let files = try AntigravityDataSource.discoverSessionFiles(roots: [real.path, link.path])
        #expect(files.map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    /// Reversed alias order still yields one file; spelling follows the first root.
    @Test
    func deduplicatesReversedSymlinkRootOrder() throws {
        DiscoveryCache.reset()
        let base = try temporaryDirectory()
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("session.jsonl")
        try Data("{}".utf8).write(to: file)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let files = try AntigravityDataSource.discoverSessionFiles(roots: [link.path, real.path])
        let resolvedDiscovered = files.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        #expect(resolvedDiscovered == [file.standardizedFileURL])
    }

    /// Overlapping but unequal roots must not return the same file twice.
    @Test
    func deduplicatesOverlappingNestedRoots() throws {
        DiscoveryCache.reset()
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("brain/session-a", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("session.jsonl")
        try Data("{}".utf8).write(to: file)

        let files = try AntigravityDataSource.discoverSessionFiles(roots: [root.path, nested.path])
        let resolvedDiscovered = files.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        #expect(resolvedDiscovered == [file.standardizedFileURL])
    }

    @Test
    func defaultRootsIncludeAntigravityCLITree() {
        #expect(AntigravityDataSource.defaultRoots.contains("~/.gemini/antigravity-cli"))
        #expect(AntigravityDataSource.defaultRoots.contains("~/.gemini/antigravity"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-ds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
