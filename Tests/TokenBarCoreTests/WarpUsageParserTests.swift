import Foundation
import GRDB
import Testing
@testable import TokenBarCore

struct WarpUsageParserTests {
    @Test
    func parsesConversationWithSingleModel() throws {
        let dbURL = createWarpDB()
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-1",
            data: conversationJSON(tokenUsage: [
                modelTokenUsage(modelId: "claude-opus-4", warpTokens: 5000, byokTokens: 2000),
            ]),
            lastModified: fixedDate()
        )

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.count == 1)

        let event = result.events[0]
        #expect(event.agent == .warp)
        #expect(event.sessionId == "conv-1")
        #expect(event.modelName == "claude-opus-4")
        #expect(event.outputTokens == 7000)
        #expect(event.inputTokens == 0)
        #expect(event.parser == .warp)
        #expect(event.confidence == 1.0)
    }

    @Test
    func parsesConversationWithMultipleModels() throws {
        let dbURL = createWarpDB()
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-multi",
            data: conversationJSON(tokenUsage: [
                modelTokenUsage(modelId: "claude-opus-4", warpTokens: 3000, byokTokens: 0),
                modelTokenUsage(modelId: "claude-sonnet-4", warpTokens: 1000, byokTokens: 500),
            ]),
            lastModified: fixedDate()
        )

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.count == 2)

        let models = Set(result.events.compactMap(\.modelName))
        #expect(models == Set(["claude-opus-4", "claude-sonnet-4"]))

        let opusEvent = result.events.first { $0.modelName == "claude-opus-4" }!
        #expect(opusEvent.outputTokens == 3000)

        let sonnetEvent = result.events.first { $0.modelName == "claude-sonnet-4" }!
        #expect(sonnetEvent.outputTokens == 1500)
    }

    @Test
    func skipsZeroTokenConversations() throws {
        let dbURL = createWarpDB()
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-zero",
            data: conversationJSON(tokenUsage: [
                modelTokenUsage(modelId: "claude-opus-4", warpTokens: 0, byokTokens: 0),
            ]),
            lastModified: fixedDate()
        )

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.isEmpty)
    }

    @Test
    func handlesmalformedJSON() throws {
        let dbURL = createWarpDB()
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-bad",
            data: "{invalid json!!!",
            lastModified: fixedDate()
        )

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message.contains("JSON decode failed"))
    }

    @Test
    func handlesMissingUsageMetadata() throws {
        let dbURL = createWarpDB()
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-empty",
            data: "{}",
            lastModified: fixedDate()
        )

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test
    func incrementalWatermarkSkipsOldConversations() throws {
        let dbURL = createWarpDB()
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_100_000)

        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-old",
            data: conversationJSON(tokenUsage: [
                modelTokenUsage(modelId: "m1", warpTokens: 100, byokTokens: 0),
            ]),
            lastModified: oldDate
        )
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-new",
            data: conversationJSON(tokenUsage: [
                modelTokenUsage(modelId: "m2", warpTokens: 200, byokTokens: 0),
            ]),
            lastModified: newDate
        )

        let watermark = SourceWatermark(
            sourcePath: dbURL.path,
            agent: .warp,
            lastMtime: oldDate,
            lastByteOffset: 0,
            lastEventId: nil,
            lastInode: nil,
            updatedAt: oldDate
        )

        let result = try WarpUsageParser.parse(databaseURL: dbURL, watermark: watermark)
        #expect(result.events.count == 1)
        #expect(result.events[0].sessionId == "conv-new")
    }

    @Test
    func derivesProjectNameFromAiQueries() throws {
        let dbURL = createWarpDB(includeAiQueries: true)
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-proj",
            data: conversationJSON(tokenUsage: [
                modelTokenUsage(modelId: "claude-opus-4", warpTokens: 1000, byokTokens: 0),
            ]),
            lastModified: fixedDate()
        )
        insertAiQuery(dbURL: dbURL, conversationId: "conv-proj", workingDirectory: "/Users/dev/projects/myapp")

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.count == 1)
        #expect(result.events[0].projectName == "myapp")
    }

    @Test
    func handlesBackwardCompatTotalTokensAlias() throws {
        let dbURL = createWarpDB()
        let json = """
        {"conversation_usage_metadata":{"was_summarized":false,"context_window_usage":0.5,"credits_spent":1.0,"token_usage":[{"model_id":"old-model","total_tokens":8000}]}}
        """
        insertConversation(dbURL: dbURL, conversationId: "conv-legacy", data: json, lastModified: fixedDate())

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.count == 1)
        #expect(result.events[0].outputTokens == 8000)
    }

    @Test
    func returnsEmptyForMissingTable() throws {
        let dbURL = temporaryDirectory().appendingPathComponent("empty-warp.sqlite")
        var config = Configuration()
        config.readonly = false
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE dummy (id INTEGER PRIMARY KEY)")
        }

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.events.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test
    func watermarkUpdatesAfterParse() throws {
        let dbURL = createWarpDB()
        insertConversation(
            dbURL: dbURL,
            conversationId: "conv-wm",
            data: conversationJSON(tokenUsage: [
                modelTokenUsage(modelId: "m1", warpTokens: 500, byokTokens: 0),
            ]),
            lastModified: fixedDate()
        )

        let result = try WarpUsageParser.parse(databaseURL: dbURL)
        #expect(result.nextWatermarks.count == 1)
        let wm = result.nextWatermarks[0]
        #expect(wm.agent == .warp)
        #expect(wm.lastMtime == fixedDate())
    }

    // MARK: - Helpers

    private func fixedDate() -> Date {
        Date(timeIntervalSince1970: 1_770_000_000)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("warp-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createWarpDB(includeAiQueries: Bool = false) -> URL {
        let dbURL = temporaryDirectory().appendingPathComponent("warp.sqlite")
        var config = Configuration()
        config.readonly = false
        let queue = try! DatabaseQueue(path: dbURL.path, configuration: config)
        try! queue.write { db in
            try db.execute(sql: """
            CREATE TABLE agent_conversations (
                id INTEGER PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                active_task_id TEXT,
                conversation_data TEXT NOT NULL,
                last_modified_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """)
            if includeAiQueries {
                try db.execute(sql: """
                CREATE TABLE ai_queries (
                    id INTEGER PRIMARY KEY NOT NULL,
                    exchange_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL,
                    start_ts TIMESTAMP,
                    input TEXT,
                    working_directory TEXT,
                    output_status TEXT NOT NULL DEFAULT '',
                    model_id TEXT NOT NULL DEFAULT '',
                    planning_model_id TEXT NOT NULL DEFAULT '',
                    coding_model_id TEXT NOT NULL DEFAULT ''
                )
                """)
            }
        }
        return dbURL
    }

    private func insertConversation(dbURL: URL, conversationId: String, data: String, lastModified: Date) {
        var config = Configuration()
        config.readonly = false
        let queue = try! DatabaseQueue(path: dbURL.path, configuration: config)
        try! queue.write { db in
            try db.execute(
                sql: "INSERT INTO agent_conversations (conversation_id, conversation_data, last_modified_at) VALUES (?, ?, ?)",
                arguments: [conversationId, data, lastModified]
            )
        }
    }

    private func insertAiQuery(dbURL: URL, conversationId: String, workingDirectory: String) {
        var config = Configuration()
        config.readonly = false
        let queue = try! DatabaseQueue(path: dbURL.path, configuration: config)
        try! queue.write { db in
            try db.execute(
                sql: "INSERT INTO ai_queries (exchange_id, conversation_id, working_directory) VALUES (?, ?, ?)",
                arguments: [UUID().uuidString, conversationId, workingDirectory]
            )
        }
    }

    private func conversationJSON(tokenUsage: [String]) -> String {
        let usageArray = tokenUsage.joined(separator: ",")
        return """
        {"conversation_usage_metadata":{"was_summarized":false,"context_window_usage":0.5,"credits_spent":1.0,"token_usage":[\(usageArray)]}}
        """
    }

    private func modelTokenUsage(modelId: String, warpTokens: UInt32, byokTokens: UInt32) -> String {
        """
        {"model_id":"\(modelId)","warp_tokens":\(warpTokens),"byok_tokens":\(byokTokens)}
        """
    }
}
