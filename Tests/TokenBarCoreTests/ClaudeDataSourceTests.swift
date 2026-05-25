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
        let subagent = try writeSubagentFile(root: root, slug: "-Users-javis-Documents-workspace-openclaw", name: "agent-a.jsonl", modifiedAt: referenceDate)

        let urls = try ClaudeDataSource.discoverSessionFiles(
            rootDirectory: root.path,
            referenceDate: referenceDate,
            daysBack: 30
        )

        #expect(urls.map { $0.standardizedFileURL } == [recent, subagent].map(\.standardizedFileURL).sorted { $0.path < $1.path })
    }

    @Test
    func discoveryFindsAllRootJsonlFilesWhenWindowIsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let referenceDate = Date(timeIntervalSince1970: 1_777_000_000)
        let recent = try writeProjectFile(root: root, slug: "-Users-javis-Documents-workspace-openclaw", name: "recent.jsonl", modifiedAt: referenceDate)
        let historical = try writeProjectFile(root: root, slug: "-Users-javis-Documents-workspace-openclaw", name: "historical.jsonl", modifiedAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 120))
        let subagent = try writeSubagentFile(root: root, slug: "-Users-javis-Documents-workspace-openclaw", name: "agent-a.jsonl", modifiedAt: referenceDate)

        let urls = try ClaudeDataSource.discoverSessionFiles(
            rootDirectory: root.path,
            referenceDate: referenceDate,
            daysBack: nil
        )

        let actual = urls.map(\.standardizedFileURL)
        let expected = [historical, recent, subagent]
            .map(\.standardizedFileURL)
            .sorted(by: { $0.path < $1.path })

        #expect(actual == expected)
    }

    @Test
    func readableProjectNameFallsBackFromSlug() {
        let projectName = ClaudeDataSource.readableProjectName(fromSlug: "-Users-javis-Documents-workspace-projects-tokenbar")
        #expect(projectName == "tokenbar")
    }

    @Test
    func readableProjectNamePreservesHyphenatedWorkspaceSlugs() {
        #expect(ClaudeDataSource.readableProjectName(fromSlug: "-Users-dev-Documents-workspace-projects-my-cli-tool") == "my-cli-tool")
        #expect(ClaudeDataSource.readableProjectName(fromSlug: "-Users-dev-Documents-workspace-projects-my-app--claude-worktrees-fix-data-source-config") == "fix-data-source-config")
    }

    @Test
    func projectSlugForSubagentFileUsesParentProjectDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = try writeSubagentFile(
            root: root,
            slug: "-Users-javis-Documents-workspace-projects-tokenbar",
            name: "agent-a.jsonl",
            modifiedAt: Date()
        )

        let slug = ClaudeDataSource.projectSlug(for: file, rootDirectory: root.path)
        #expect(slug == "-Users-javis-Documents-workspace-projects-tokenbar")
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
            .appendingPathComponent("session-a", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
        return file
    }
}
