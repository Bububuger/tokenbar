import Foundation
import GRDB
import Testing
@testable import TokenBarCore

struct SavedPromptStoreTests {
    @Test
    func migrationCreatesSavedPromptsTable() throws {
        let dbURL = temporaryDatabaseURL()
        _ = try UsageRepository(databaseURL: dbURL)

        let queue = try DatabaseQueue(path: dbURL.path)
        let tables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("saved_prompts"))
    }

    @Test
    func upsertAndReadRoundTrip() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let prompt = SavedPrompt(
            id: "id-1",
            slug: "commit-msg",
            title: "Commit message generator",
            body: "Write a conventional commit for:\n$ARGUMENTS",
            sourcePromptId: "prompt-abc",
            createdAt: created,
            updatedAt: created
        )

        try repository.upsertSavedPrompt(prompt)

        let fetched = try repository.savedPrompt(slug: "commit-msg")
        #expect(fetched?.id == "id-1")
        #expect(fetched?.slug == "commit-msg")
        #expect(fetched?.title == "Commit message generator")
        #expect(fetched?.body == "Write a conventional commit for:\n$ARGUMENTS")
        #expect(fetched?.sourcePromptId == "prompt-abc")
        #expect(fetched?.createdAt == created)
        #expect(fetched?.updatedAt == created)
    }

    @Test
    func upsertBySameIdUpdatesFieldsWithoutDuplicating() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_100_000)
        let original = SavedPrompt(
            id: "id-1",
            slug: "first-slug",
            title: "v1",
            body: "old body",
            sourcePromptId: nil,
            createdAt: created,
            updatedAt: created
        )
        try repository.upsertSavedPrompt(original)

        let revised = SavedPrompt(
            id: "id-1",
            slug: "second-slug",
            title: "v2",
            body: "new body",
            sourcePromptId: "prompt-xyz",
            createdAt: created,
            updatedAt: updated
        )
        try repository.upsertSavedPrompt(revised)

        let all = try repository.allSavedPrompts()
        #expect(all.count == 1)
        #expect(all.first?.slug == "second-slug")
        #expect(all.first?.title == "v2")
        #expect(all.first?.body == "new body")
        #expect(all.first?.sourcePromptId == "prompt-xyz")
        #expect(all.first?.updatedAt == updated)
        #expect(try repository.savedPrompt(slug: "first-slug") == nil)
    }

    @Test
    func slugUniqueConstraintRejectsCollisionAcrossIds() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let now = Date()
        let first = SavedPrompt(
            id: "id-1",
            slug: "shared",
            title: "one",
            body: "x",
            sourcePromptId: nil,
            createdAt: now,
            updatedAt: now
        )
        let second = SavedPrompt(
            id: "id-2",
            slug: "shared",
            title: "two",
            body: "y",
            sourcePromptId: nil,
            createdAt: now,
            updatedAt: now
        )

        try repository.upsertSavedPrompt(first)
        #expect(throws: (any Error).self) {
            try repository.upsertSavedPrompt(second)
        }
    }

    @Test
    func deleteRemovesRow() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let now = Date()
        let prompt = SavedPrompt(
            id: "id-1",
            slug: "to-delete",
            title: "t",
            body: "b",
            sourcePromptId: nil,
            createdAt: now,
            updatedAt: now
        )
        try repository.upsertSavedPrompt(prompt)

        try repository.deleteSavedPrompt(id: "id-1")
        #expect(try repository.allSavedPrompts().isEmpty)
        #expect(try repository.savedPrompt(slug: "to-delete") == nil)
    }

    @Test
    func allSavedPromptsOrderedByUpdatedAtDescending() throws {
        let repository = try UsageRepository(databaseURL: temporaryDatabaseURL())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = SavedPrompt(
            id: "older",
            slug: "older",
            title: "older",
            body: "b",
            sourcePromptId: nil,
            createdAt: base,
            updatedAt: base
        )
        let newer = SavedPrompt(
            id: "newer",
            slug: "newer",
            title: "newer",
            body: "b",
            sourcePromptId: nil,
            createdAt: base,
            updatedAt: base.addingTimeInterval(60)
        )

        try repository.upsertSavedPrompt(older)
        try repository.upsertSavedPrompt(newer)

        let all = try repository.allSavedPrompts()
        #expect(all.map(\.slug) == ["newer", "older"])
    }

    private func temporaryDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-saved-prompt-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tokenbar.sqlite")
    }
}
