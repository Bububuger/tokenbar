import Foundation
import GRDB
import Testing
@testable import TokenBarCore

struct OpenCodeUsageParserTests {
    @Test
    func parserEmitsAssistantEventsWithTokenMapping() throws {
        let fixture = try OpenCodeFixture.make { db in
            try OpenCodeFixture.insertProject(db,
                id: "p1",
                worktree: "/Users/dev/code/sample",
                name: "sample")
            try OpenCodeFixture.insertSession(db, id: "s1", projectID: "p1", timeCreated: 1_772_546_000_000)
            try OpenCodeFixture.insertMessage(db,
                id: "m1",
                sessionID: "s1",
                timeCreated: 1_772_546_693_171,
                payload: .assistant(modelID: "big-pickle", providerID: "opencode",
                                    input: 78, output: 29, reasoning: 0, cacheRead: 510, cacheWrite: 21_478))
        }

        let result = try OpenCodeUsageParser.parse(databaseURL: fixture.url)

        #expect(result.events.count == 1)
        let event = try #require(result.events.first)
        #expect(event.agent == .openCode)
        #expect(event.inputTokens == 78)
        #expect(event.outputTokens == 29)
        #expect(event.cacheTokens == 510 + 21_478)
        #expect(event.reasoningTokens == 0)
        #expect(event.modelName == "big-pickle")
        #expect(event.sessionId == "s1")
        #expect(event.projectName == "sample")
        #expect(event.projectPath == "/Users/dev/code/sample")
        #expect(event.parser == .openCode)
        #expect(event.sourcePath == fixture.url.path)
        #expect(result.warnings.isEmpty)
        #expect(result.nextWatermarks.count == 1)
        #expect(result.nextWatermarks[0].lastEventId == "m1")
    }

    @Test
    func parserSkipsUserRowsAndOperationalWarningsForMissingTokens() throws {
        let fixture = try OpenCodeFixture.make { db in
            try OpenCodeFixture.insertProject(db, id: "p1", worktree: "/Users/dev/x", name: nil)
            try OpenCodeFixture.insertSession(db, id: "s1", projectID: "p1", timeCreated: 1_000)
            try OpenCodeFixture.insertMessage(db,
                id: "u1", sessionID: "s1", timeCreated: 1_100, payload: .user)
            try OpenCodeFixture.insertMessage(db,
                id: "a-null", sessionID: "s1", timeCreated: 1_200,
                payload: .assistantNoTokens(providerID: "openrouter"))
            try OpenCodeFixture.insertMessage(db,
                id: "a-zero", sessionID: "s1", timeCreated: 1_300,
                payload: .assistant(modelID: "auto", providerID: "auto",
                                    input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0))
        }

        let result = try OpenCodeUsageParser.parse(databaseURL: fixture.url)

        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 2)
        #expect(result.warnings.allSatisfy { $0.isUserActionable == false })
        #expect(result.warnings.contains { $0.message.contains("missing usage") })
        #expect(result.warnings.contains { $0.message.contains("zero-sum") })
    }

    @Test
    func parserFallsBackToWorktreeBasenameWhenProjectNameIsNull() throws {
        let fixture = try OpenCodeFixture.make { db in
            try OpenCodeFixture.insertProject(db, id: "p1", worktree: "/Users/dev/code/named-by-path", name: nil)
            try OpenCodeFixture.insertSession(db, id: "s1", projectID: "p1", timeCreated: 1_000)
            try OpenCodeFixture.insertMessage(db,
                id: "m1", sessionID: "s1", timeCreated: 2_000,
                payload: .assistant(modelID: "big-pickle", providerID: "opencode",
                                    input: 10, output: 5, reasoning: nil, cacheRead: 0, cacheWrite: 0))
        }

        let result = try OpenCodeUsageParser.parse(databaseURL: fixture.url)
        #expect(result.events.first?.projectName == "named-by-path")
        #expect(result.events.first?.reasoningTokens == nil)
    }

    @Test
    func watermarkDedupesOnRereadAndPicksUpNewMessages() throws {
        let fixture = try OpenCodeFixture.make { db in
            try OpenCodeFixture.insertProject(db, id: "p1", worktree: "/Users/dev/code/x", name: "x")
            try OpenCodeFixture.insertSession(db, id: "s1", projectID: "p1", timeCreated: 1_000)
            try OpenCodeFixture.insertMessage(db,
                id: "m1", sessionID: "s1", timeCreated: 2_000,
                payload: .assistant(modelID: "big-pickle", providerID: "opencode",
                                    input: 10, output: 5, reasoning: nil, cacheRead: 0, cacheWrite: 0))
        }

        let first = try OpenCodeUsageParser.parse(databaseURL: fixture.url)
        #expect(first.events.count == 1)
        let watermark = try #require(first.nextWatermarks.first)

        let second = try OpenCodeUsageParser.parse(databaseURL: fixture.url, watermark: watermark)
        #expect(second.events.isEmpty)
        #expect(second.warnings.isEmpty)

        try OpenCodeFixture.appendMessage(
            fixture.url,
            id: "m2",
            sessionID: "s1",
            timeCreated: 3_000,
            payload: .assistant(modelID: "big-pickle", providerID: "opencode",
                                input: 7, output: 3, reasoning: nil, cacheRead: 0, cacheWrite: 0)
        )

        let third = try OpenCodeUsageParser.parse(databaseURL: fixture.url, watermark: watermark)
        #expect(third.events.count == 1)
        #expect(third.events.first?.id.hasSuffix("#m2") == true)
    }

    @Test
    func malformedDataProducesUserActionableWarning() throws {
        let fixture = try OpenCodeFixture.make { db in
            try OpenCodeFixture.insertProject(db, id: "p1", worktree: "/Users/dev/x", name: "x")
            try OpenCodeFixture.insertSession(db, id: "s1", projectID: "p1", timeCreated: 1_000)
            try db.execute(sql: """
                INSERT INTO message(id, session_id, time_created, time_updated, data)
                VALUES('bad', 's1', 2_000, 2_000, '{not json');
                """)
        }

        let result = try OpenCodeUsageParser.parse(databaseURL: fixture.url)
        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].isUserActionable == true)
        #expect(result.warnings[0].message.contains("malformed message.data"))
    }
}

// MARK: - Fixture helpers

private enum OpenCodeFixture {
    struct Handle {
        let url: URL
    }

    enum Payload {
        case user
        case assistant(modelID: String, providerID: String,
                       input: Int, output: Int, reasoning: Int?,
                       cacheRead: Int, cacheWrite: Int)
        case assistantNoTokens(providerID: String)
    }

    static func make(_ populate: (Database) throws -> Void) throws -> Handle {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-test-\(UUID().uuidString).db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE project(
                    id TEXT PRIMARY KEY,
                    worktree TEXT NOT NULL,
                    vcs TEXT,
                    name TEXT,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL,
                    sandboxes TEXT NOT NULL DEFAULT '{}'
                );
                CREATE TABLE session(
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    directory TEXT NOT NULL DEFAULT '',
                    title TEXT NOT NULL DEFAULT '',
                    version TEXT NOT NULL DEFAULT '',
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL
                );
                CREATE TABLE message(
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    time_created INTEGER NOT NULL,
                    time_updated INTEGER NOT NULL,
                    data TEXT NOT NULL
                );
                """)
            try populate(db)
        }
        return Handle(url: url)
    }

    static func insertProject(_ db: Database, id: String, worktree: String, name: String?) throws {
        try db.execute(
            sql: "INSERT INTO project(id, worktree, name, time_created, time_updated) VALUES(?, ?, ?, ?, ?)",
            arguments: [id, worktree, name, 0, 0]
        )
    }

    static func insertSession(_ db: Database, id: String, projectID: String, timeCreated: Int64) throws {
        try db.execute(
            sql: "INSERT INTO session(id, project_id, directory, title, version, time_created, time_updated) VALUES(?, ?, '', '', '', ?, ?)",
            arguments: [id, projectID, timeCreated, timeCreated]
        )
    }

    static func insertMessage(
        _ db: Database,
        id: String,
        sessionID: String,
        timeCreated: Int64,
        payload: Payload
    ) throws {
        let data = encode(payload)
        try db.execute(
            sql: "INSERT INTO message(id, session_id, time_created, time_updated, data) VALUES(?, ?, ?, ?, ?)",
            arguments: [id, sessionID, timeCreated, timeCreated, data]
        )
    }

    static func appendMessage(
        _ databaseURL: URL,
        id: String,
        sessionID: String,
        timeCreated: Int64,
        payload: Payload
    ) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try insertMessage(db, id: id, sessionID: sessionID, timeCreated: timeCreated, payload: payload)
        }
    }

    private static func encode(_ payload: Payload) -> String {
        switch payload {
        case .user:
            return #"{"role":"user","time":{"created":0,"completed":0}}"#
        case let .assistant(modelID, providerID, input, output, reasoning, cacheRead, cacheWrite):
            let reasoningField = reasoning.map { ",\"reasoning\":\($0)" } ?? ""
            return #"""
            {"role":"assistant","time":{"created":0,"completed":0},"modelID":"\#(modelID)","providerID":"\#(providerID)","tokens":{"input":\#(input),"output":\#(output)\#(reasoningField),"cache":{"read":\#(cacheRead),"write":\#(cacheWrite)}}}
            """#
        case let .assistantNoTokens(providerID):
            return #"""
            {"role":"assistant","time":{"created":0,"completed":0},"modelID":"unknown","providerID":"\#(providerID)"}
            """#
        }
    }
}
