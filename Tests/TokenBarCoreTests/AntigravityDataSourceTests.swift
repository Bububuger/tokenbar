import Foundation
import Testing
@testable import TokenBarCore

struct AntigravityDataSourceTests {
    /// Transcripts live at `brain/<id>/.system_generated/logs/transcript*.jsonl`;
    /// hidden path segments must not be skipped.
    @Test
    func discoversJsonlUnderHiddenSystemGeneratedDirectory() throws {
        let root = try temporaryDirectory()
        let hiddenDir = root.appendingPathComponent(
            "brain/9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6/.system_generated/logs",
            isDirectory: true
        )
        let plainDir = root.appendingPathComponent(
            "brain/1a2b3c4d/.gemini",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
        let transcript = hiddenDir.appendingPathComponent("transcript-1.jsonl")
        let session = plainDir.appendingPathComponent("session.jsonl")
        try Data("{}".utf8).write(to: transcript)
        try Data("{}".utf8).write(to: session)

        let files = try AntigravityDataSource.discoverSessionFiles(roots: [root.path])
        #expect(files.map(\.standardizedFileURL) == [transcript, session].map(\.standardizedFileURL).sorted { $0.path < $1.path })
    }

    @Test
    func deduplicatesRootsThatResolveToSameDirectory() throws {
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
