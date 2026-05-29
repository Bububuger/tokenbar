import Foundation
import Testing
@testable import TokenBarCore

struct SavedPromptCommandSyncTests {
    @Test
    func applyWritesFileWithFrontmatter() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        let prompt = makePrompt(slug: "commit-msg", title: "Commit message generator", body: "Write a conventional commit for:\n$ARGUMENTS")

        try sync.apply(prompt, previousSlug: nil)

        let file = root.appendingPathComponent("commit-msg.md")
        let contents = try String(contentsOf: file, encoding: .utf8)
        let expected = """
        ---
        description: Commit message generator
        ---
        Write a conventional commit for:
        $ARGUMENTS
        """
        #expect(contents == expected)
    }

    @Test
    func applyCreatesCommandsDirectoryWhenMissing() throws {
        let root = temporaryCommandsRoot()
        try? FileManager.default.removeItem(at: root)
        let sync = SavedPromptCommandSync(commandsRoot: root)
        let prompt = makePrompt(slug: "x", title: "t", body: "b")

        try sync.apply(prompt, previousSlug: nil)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test
    func removeDeletesFile() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        try sync.apply(makePrompt(slug: "to-remove", title: "t", body: "b"), previousSlug: nil)

        try sync.remove(slug: "to-remove")

        let file = root.appendingPathComponent("to-remove.md")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func removeIsNonErrorWhenFileMissing() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)

        try sync.remove(slug: "never-existed")
    }

    @Test
    func removeAllDeletesTokenBarMarkdownCommandsOnly() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        try sync.apply(makePrompt(slug: "one", title: "One", body: "1"), previousSlug: nil)
        try sync.apply(makePrompt(slug: "two", title: "Two", body: "2"), previousSlug: nil)
        let preserved = root.appendingPathComponent("notes.txt")
        try "keep".write(to: preserved, atomically: true, encoding: .utf8)

        try sync.removeAll()

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("one.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("two.md").path))
        #expect(FileManager.default.fileExists(atPath: preserved.path))
    }

    /// Locks the invariant that deleting a saved prompt removes BOTH the DB
    /// row and the on-disk `~/.claude/commands/tbar/<slug>.md` file. Runs
    /// the two-step deletion in the same shape `TokenBarRuntimeModel.deleteSavedPrompt`
    /// uses today, so if a future refactor removes either step the test fails.
    @Test
    func deleteSyncsBothDBAndFile() async throws {
        let dbURL = temporaryDatabaseURL()
        let commandsRoot = temporaryCommandsRoot()
        let store = try UsageStore(databaseURL: dbURL)
        let sync = SavedPromptCommandSync(commandsRoot: commandsRoot)
        let prompt = makePrompt(slug: "to-delete", title: "t", body: "b")

        try await store.upsertSavedPrompt(prompt)
        try sync.apply(prompt, previousSlug: nil)

        let onDisk = commandsRoot.appendingPathComponent("to-delete.md")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
        #expect(try await store.allSavedPrompts().count == 1)

        // Mirror the runtime model's two-step deletion. If either step is
        // dropped, one of the post-conditions below will fail.
        try await store.deleteSavedPrompt(id: prompt.id)
        try sync.remove(slug: prompt.slug)

        #expect(try await store.allSavedPrompts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: onDisk.path))
    }

    @Test
    func slugRenameRemovesPreviousFileAndWritesNew() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        let original = makePrompt(slug: "old-slug", title: "t", body: "v1")
        try sync.apply(original, previousSlug: nil)

        let renamed = SavedPrompt(
            id: original.id,
            slug: "new-slug",
            title: original.title,
            body: "v2",
            sourcePromptId: nil,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        try sync.apply(renamed, previousSlug: "old-slug")

        let oldFile = root.appendingPathComponent("old-slug.md")
        let newFile = root.appendingPathComponent("new-slug.md")
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: newFile.path))
        let newContents = try String(contentsOf: newFile, encoding: .utf8)
        #expect(newContents.contains("v2"))
    }

    @Test
    func applyOverwritesExistingFileWhenSlugUnchanged() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        let p1 = makePrompt(slug: "stable", title: "t", body: "original")
        try sync.apply(p1, previousSlug: nil)

        let p2 = SavedPrompt(
            id: p1.id,
            slug: "stable",
            title: "t",
            body: "updated",
            sourcePromptId: nil,
            createdAt: p1.createdAt,
            updatedAt: p1.updatedAt
        )
        try sync.apply(p2, previousSlug: "stable")

        let file = root.appendingPathComponent("stable.md")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("updated"))
        #expect(!contents.contains("original"))
    }

    @Test
    func argumentHintWrittenToFrontmatterWhenPresent() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        var p = makePrompt(slug: "with-hint", title: "Commit msg", body: "Body")
        p.argumentHint = "<file or diff>"
        try sync.apply(p, previousSlug: nil)
        let contents = try String(contentsOf: root.appendingPathComponent("with-hint.md"), encoding: .utf8)
        #expect(contents.contains("argument-hint: <file or diff>"))
    }

    @Test
    func argumentHintOmittedWhenNil() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        let p = makePrompt(slug: "no-hint", title: "x", body: "y")
        try sync.apply(p, previousSlug: nil)
        let contents = try String(contentsOf: root.appendingPathComponent("no-hint.md"), encoding: .utf8)
        #expect(contents.contains("argument-hint") == false)
    }

    @Test
    func allowedToolsWrittenAsBracketList() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        var p = makePrompt(slug: "with-tools", title: "x", body: "y")
        p.allowedTools = ["Read", "Bash", "Grep"]
        try sync.apply(p, previousSlug: nil)
        let contents = try String(contentsOf: root.appendingPathComponent("with-tools.md"), encoding: .utf8)
        #expect(contents.contains("allowed-tools: [Read, Bash, Grep]"))
    }

    @Test
    func allowedToolsOmittedWhenEmpty() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        let p = makePrompt(slug: "no-tools", title: "x", body: "y")
        try sync.apply(p, previousSlug: nil)
        let contents = try String(contentsOf: root.appendingPathComponent("no-tools.md"), encoding: .utf8)
        #expect(contents.contains("allowed-tools") == false)
    }

    @Test
    func frontmatterKeyOrderingIsStable() throws {
        let root = temporaryCommandsRoot()
        let sync = SavedPromptCommandSync(commandsRoot: root)
        var p = makePrompt(slug: "all-fields", title: "Title", body: "Body")
        p.argumentHint = "<x>"
        p.allowedTools = ["Read"]
        try sync.apply(p, previousSlug: nil)
        let contents = try String(contentsOf: root.appendingPathComponent("all-fields.md"), encoding: .utf8)
        let expected = """
        ---
        description: Title
        argument-hint: <x>
        allowed-tools: [Read]
        ---
        Body
        """
        #expect(contents == expected)
    }

    private func makePrompt(slug: String, title: String, body: String) -> SavedPrompt {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return SavedPrompt(
            id: UUID().uuidString,
            slug: slug,
            title: title,
            body: body,
            sourcePromptId: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    private func temporaryCommandsRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-sync-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-sync-tests-\(UUID().uuidString).sqlite")
    }

    // MARK: - tb → tbar directory migration

    @Test
    func legacyTbDirectoryMovesToTbarWhenTargetAbsent() throws {
        let (legacy, target) = makeLegacyTargetPair()
        try seedLegacy(legacy: legacy, files: ["foo.md": "body"])

        SavedPromptCommandSync.migrateLegacyDirectoryIfNeeded(legacy: legacy, target: target)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let moved = target.appendingPathComponent("foo.md")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        let contents = try String(contentsOf: moved, encoding: .utf8)
        #expect(contents == "body")
    }

    @Test
    func legacyMigrationIsNoOpWhenTargetAlreadyExists() throws {
        let (legacy, target) = makeLegacyTargetPair()
        try seedLegacy(legacy: legacy, files: ["legacy.md": "old"])
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let preserved = target.appendingPathComponent("new.md")
        try "new".write(to: preserved, atomically: true, encoding: .utf8)

        SavedPromptCommandSync.migrateLegacyDirectoryIfNeeded(legacy: legacy, target: target)

        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: preserved.path))
        // tbar/legacy.md should NOT have been merged in
        let mergedAttempt = target.appendingPathComponent("legacy.md")
        #expect(!FileManager.default.fileExists(atPath: mergedAttempt.path))
    }

    @Test
    func legacyMigrationIsNoOpWhenLegacyMissing() throws {
        let (legacy, target) = makeLegacyTargetPair()
        // Neither directory exists.
        SavedPromptCommandSync.migrateLegacyDirectoryIfNeeded(legacy: legacy, target: target)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    private func makeLegacyTargetPair() -> (legacy: URL, target: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-migration-\(UUID().uuidString)", isDirectory: true)
        return (
            parent.appendingPathComponent("tb", isDirectory: true),
            parent.appendingPathComponent("tbar", isDirectory: true)
        )
    }

    private func seedLegacy(legacy: URL, files: [String: String]) throws {
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: legacy.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }
}
