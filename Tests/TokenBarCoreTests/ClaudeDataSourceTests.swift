import Foundation
import Testing
@testable import TokenBarCore

struct ClaudeDataSourceTests {
    @Test
    func discoveryFindsRootJsonlFilesWithinDateWindow() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let referenceDate = Date(timeIntervalSince1970: 1_777_000_000)
        let recent = try writeProjectFile(root: root, slug: "-Users-javis-Documents-workspace-openclaw", name: "recent.jsonl", modifiedAt: referenceDate)
        _ = try writeProjectFile(root: root, slug: "-Users-javis-Documents-workspace-openclaw", name: "stale.jsonl", modifiedAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 45))
        _ = try writeSubagentFile(root: root, slug: "-Users-javis-Documents-workspace-openclaw", name: "agent-a.jsonl", modifiedAt: referenceDate)

        let urls = try ClaudeDataSource.discoverSessionFiles(
            rootDirectory: root.path,
            referenceDate: referenceDate,
            daysBack: 30
        )

        #expect(urls.map { $0.standardizedFileURL } == [recent.standardizedFileURL])
    }

    @Test
    func readableProjectNameFallsBackFromSlug() {
        let projectName = ClaudeDataSource.readableProjectName(fromSlug: "-Users-javis-Documents-workspace-projects-tokenbar")
        #expect(projectName == "tokenbar")
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

    private func writeProjectFile(root: URL, slug: String, name: String, modifiedAt: Date) throws -> URL {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }

    private func writeSubagentFile(root: URL, slug: String, name: String, modifiedAt: Date) throws -> URL {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }
}
