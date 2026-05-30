import Foundation
import GRDB
import Testing
@testable import TokenBarCore

// MARK: - PluginManifest Tests

struct PluginManifestTests {
    @Test
    func decodesJSONLManifest() throws {
        let json = """
        {
          "manifest_version": 1,
          "id": "github-copilot",
          "name": "GitHub Copilot",
          "version": "1.0.0",
          "description": "OTel JSONL",
          "author": "community",
          "source": {
            "type": "jsonl",
            "directory": "~/.copilot/otel",
            "glob": "*.jsonl",
            "fields": {
              "input_tokens": "attributes.gen_ai.usage.input_tokens",
              "output_tokens": "attributes.gen_ai.usage.output_tokens",
              "model": "attributes.gen_ai.response.model",
              "timestamp": "startTimeUnixNano"
            }
          },
          "token_semantics": {
            "input_includes_cached": false,
            "timestamp_format": "unix_nano"
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
        #expect(manifest.id == "github-copilot")
        #expect(manifest.name == "GitHub Copilot")
        #expect(manifest.version == "1.0.0")
        #expect(manifest.inputIncludesCached == false)
        #expect(manifest.timestampFormat == .unixNano)
        if case .jsonl(let src) = manifest.source {
            #expect(src.directory == "~/.copilot/otel")
            #expect(src.glob == "*.jsonl")
            #expect(src.fields.inputTokens == "attributes.gen_ai.usage.input_tokens")
        } else {
            Issue.record("Expected jsonl source")
        }
        try manifest.validate()
    }

    @Test
    func decodesSQLiteManifest() throws {
        let json = """
        {
          "manifest_version": 1,
          "id": "kiro-cli",
          "name": "Kiro CLI",
          "version": "1.0.0",
          "description": "SQLite reader",
          "author": "community",
          "source": {
            "type": "sqlite",
            "directory": "~/.kiro",
            "glob": "data.sqlite3",
            "query": {
              "table": "messages",
              "columns": {
                "input_tokens": "input_token_count",
                "output_tokens": "output_token_count",
                "model": "model_id",
                "timestamp": "created_at",
                "session_id": "conversation_id"
              },
              "watermark_column": "created_at",
              "where": "role = 'assistant'"
            }
          },
          "token_semantics": {
            "input_includes_cached": false,
            "timestamp_format": "unix_ms"
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
        #expect(manifest.id == "kiro-cli")
        if case .sqlite(let src) = manifest.source {
            #expect(src.query.table == "messages")
            #expect(src.query.watermarkColumn == "created_at")
            #expect(src.query.where == "role = 'assistant'")
        } else {
            Issue.record("Expected sqlite source")
        }
    }

    @Test
    func decodesExecutableManifest() throws {
        let json = """
        {
          "manifest_version": 1,
          "id": "cursor",
          "name": "Cursor",
          "version": "1.0.0",
          "description": "Cursor collector",
          "author": "community",
          "source": {
            "type": "executable",
            "command": "python3",
            "script": "collect.py",
            "args": ["--format", "ndjson"],
            "incremental_flag": "--since",
            "timeout_seconds": 60
          },
          "token_semantics": {
            "input_includes_cached": true,
            "timestamp_format": "iso8601"
          }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
        #expect(manifest.id == "cursor")
        #expect(manifest.inputIncludesCached == true)
        if case .executable(let src) = manifest.source {
            #expect(src.command == "python3")
            #expect(src.script == "collect.py")
            #expect(src.effectiveTimeout == 60)
        } else {
            Issue.record("Expected executable source")
        }
    }

    @Test
    func rejectsUnsupportedVersion() throws {
        let json = """
        {
          "manifest_version": 99,
          "id": "test",
          "name": "Test",
          "version": "1.0.0",
          "description": "test",
          "author": "test",
          "source": { "type": "jsonl", "directory": "~", "glob": "*.jsonl", "fields": {} }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
        #expect(throws: PluginManifestError.self) { try manifest.validate() }
    }

    @Test
    func rejectsInvalidId() throws {
        let json = """
        {
          "manifest_version": 1,
          "id": "INVALID ID!",
          "name": "Test",
          "version": "1.0.0",
          "description": "test",
          "author": "test",
          "source": { "type": "jsonl", "directory": "~", "glob": "*.jsonl", "fields": {} }
        }
        """
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
        #expect(throws: PluginManifestError.self) { try manifest.validate() }
    }

    @Test
    func rejectsUnknownSourceType() {
        let json = """
        {
          "manifest_version": 1,
          "id": "test",
          "name": "Test",
          "version": "1.0.0",
          "description": "test",
          "author": "test",
          "source": { "type": "graphql" }
        }
        """
        #expect(throws: Error.self) {
            try JSONDecoder().decode(PluginManifest.self, from: json.data(using: .utf8)!)
        }
    }
}

// MARK: - TokenNormalizer Tests

struct TokenNormalizerTests {
    @Test
    func normalizesWithInputIncludesCachedTrue() {
        let result = TokenNormalizer.normalize(
            rawInput: 5000, rawOutput: 1200,
            cacheRead: 3000, cacheCreation: 800, reasoning: 0,
            inputIncludesCached: true
        )
        #expect(result.input == 2000)
        #expect(result.output == 1200)
        #expect(result.cacheRead == 3000)
        #expect(result.cacheCreation == 800)
    }

    @Test
    func normalizesWithInputIncludesCachedFalse() {
        let result = TokenNormalizer.normalize(
            rawInput: 5000, rawOutput: 1200,
            cacheRead: 3000, cacheCreation: 800, reasoning: 0,
            inputIncludesCached: false
        )
        #expect(result.input == 5000)
        #expect(result.output == 1200)
        #expect(result.cacheRead == 3000)
    }

    @Test
    func clampsNegativeValues() {
        let result = TokenNormalizer.normalize(
            rawInput: -100, rawOutput: -50,
            cacheRead: -10, cacheCreation: -5, reasoning: -1,
            inputIncludesCached: false
        )
        #expect(result.input == 0)
        #expect(result.output == 0)
        #expect(result.cacheRead == 0)
        #expect(result.cacheCreation == 0)
        #expect(result.reasoning == 0)
    }

    @Test
    func cacheReadClampedToInput() {
        let result = TokenNormalizer.normalize(
            rawInput: 1000, rawOutput: 500,
            cacheRead: 5000, cacheCreation: 0, reasoning: 0,
            inputIncludesCached: true
        )
        #expect(result.input == 0)
        #expect(result.cacheRead == 1000)
    }

    @Test
    func normalizeEventsPassthroughWhenFalse() {
        let events = [
            UsageEvent(
                id: "test-1", agent: .custom, projectPath: nil, projectName: "proj",
                sessionId: "s1", timestamp: Date(),
                inputTokens: 5000, outputTokens: 1200,
                cacheReadTokens: 3000, cacheCreationTokens: 0,
                reasoningTokens: nil,
                sourcePath: "/test", parser: .custom, confidence: 1.0
            ),
        ]
        let result = TokenNormalizer.normalizeEvents(events, inputIncludesCached: false)
        #expect(result[0].inputTokens == 5000)
    }

    @Test
    func normalizeEventsSubtractsCacheWhenTrue() {
        let events = [
            UsageEvent(
                id: "test-1", agent: .custom, projectPath: nil, projectName: "proj",
                sessionId: "s1", timestamp: Date(),
                inputTokens: 5000, outputTokens: 1200,
                cacheReadTokens: 3000, cacheCreationTokens: 0,
                reasoningTokens: nil,
                sourcePath: "/test", parser: .custom, confidence: 1.0
            ),
        ]
        let result = TokenNormalizer.normalizeEvents(events, inputIncludesCached: true)
        #expect(result[0].inputTokens == 2000)
        #expect(result[0].cacheReadTokens == 3000)
    }
}

// MARK: - PluginSqliteReader Tests

struct PluginSqliteReaderTests {
    @Test
    func parsesBasicSQLiteTable() throws {
        let dbURL = createTestDB()
        createTable(dbURL: dbURL)
        insertRow(dbURL: dbURL, inputTokens: 1500, outputTokens: 800, model: "gpt-4o", createdAt: 1716800000000)
        insertRow(dbURL: dbURL, inputTokens: 2000, outputTokens: 1000, model: "gpt-4o", createdAt: 1716800060000)

        let query = PluginSQLiteQuery(
            table: "messages",
            columns: PluginFieldMapping(
                inputTokens: "input_tokens",
                outputTokens: "output_tokens",
                model: "model_name",
                timestamp: "created_at",
                sessionId: "conversation_id"
            ),
            watermarkColumn: "created_at"
        )

        let result = try PluginSqliteReader.parse(
            databaseURL: dbURL,
            query: query,
            timestampFormat: .unixMs
        )

        #expect(result.events.count == 2)
        #expect(result.events[0].inputTokens == 1500)
        #expect(result.events[0].outputTokens == 800)
        #expect(result.events[0].modelName == "gpt-4o")
        #expect(result.events[1].inputTokens == 2000)
    }

    @Test
    func respectsWhereClause() throws {
        let dbURL = createTestDB()
        createTable(dbURL: dbURL)
        insertRow(dbURL: dbURL, inputTokens: 1500, outputTokens: 800, model: "gpt-4o", createdAt: 1716800000000, role: "assistant")
        insertRow(dbURL: dbURL, inputTokens: 0, outputTokens: 0, model: "gpt-4o", createdAt: 1716800060000, role: "user")

        let query = PluginSQLiteQuery(
            table: "messages",
            columns: PluginFieldMapping(
                inputTokens: "input_tokens",
                outputTokens: "output_tokens",
                model: "model_name",
                timestamp: "created_at"
            ),
            watermarkColumn: "created_at",
            where: "role = 'assistant'"
        )

        let result = try PluginSqliteReader.parse(databaseURL: dbURL, query: query, timestampFormat: .unixMs)
        #expect(result.events.count == 1)
        #expect(result.events[0].inputTokens == 1500)
    }

    @Test
    func rejectsInvalidTableName() throws {
        let dbURL = createTestDB()

        let query = PluginSQLiteQuery(
            table: "DROP TABLE; --",
            columns: PluginFieldMapping(inputTokens: "input_tokens", outputTokens: "output_tokens")
        )

        let result = try PluginSqliteReader.parse(databaseURL: dbURL, query: query)
        #expect(result.events.isEmpty)
        #expect(!result.warnings.isEmpty)
        #expect(result.warnings[0].message.contains("invalid table name"))
    }

    @Test
    func incrementalWatermarkSkipsOldRows() throws {
        let dbURL = createTestDB()
        createTable(dbURL: dbURL)
        insertRow(dbURL: dbURL, inputTokens: 100, outputTokens: 50, model: "m", createdAt: 1000)
        insertRow(dbURL: dbURL, inputTokens: 200, outputTokens: 100, model: "m", createdAt: 2000)
        insertRow(dbURL: dbURL, inputTokens: 300, outputTokens: 150, model: "m", createdAt: 3000)

        let watermark = SourceWatermark(
            sourcePath: dbURL.path,
            agent: .custom,
            lastMtime: .tokenBarDate(millisecondsSince1970: 2000),
            lastByteOffset: 0,
            lastEventId: nil,
            lastInode: nil,
            updatedAt: Date()
        )

        let query = PluginSQLiteQuery(
            table: "messages",
            columns: PluginFieldMapping(
                inputTokens: "input_tokens",
                outputTokens: "output_tokens",
                model: "model_name",
                timestamp: "created_at"
            ),
            watermarkColumn: "created_at"
        )

        let result = try PluginSqliteReader.parse(
            databaseURL: dbURL,
            query: query,
            timestampFormat: .unixMs,
            watermark: watermark
        )
        #expect(result.events.count == 1)
        #expect(result.events[0].inputTokens == 300)
    }

    @Test
    func handlesNonexistentDatabase() throws {
        let dbURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).db")
        let query = PluginSQLiteQuery(
            table: "messages",
            columns: PluginFieldMapping(inputTokens: "input_tokens", outputTokens: "output_tokens")
        )

        let result = try PluginSqliteReader.parse(databaseURL: dbURL, query: query)
        #expect(result.events.isEmpty)
        #expect(!result.warnings.isEmpty)
    }

    private func createTestDB() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-test-\(UUID().uuidString).db")
        _ = try? DatabaseQueue(path: url.path)
        return url
    }

    private func createTable(dbURL: URL) {
        let dbQueue = try! DatabaseQueue(path: dbURL.path)
        try! dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                model_name TEXT,
                created_at INTEGER NOT NULL,
                conversation_id TEXT DEFAULT 'unknown',
                role TEXT DEFAULT 'assistant'
            )
            """)
        }
    }

    private func insertRow(dbURL: URL, inputTokens: Int, outputTokens: Int, model: String, createdAt: Int64, role: String = "assistant") {
        let dbQueue = try! DatabaseQueue(path: dbURL.path)
        try! dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO messages (input_tokens, output_tokens, model_name, created_at, role) VALUES (?, ?, ?, ?, ?)",
                arguments: [inputTokens, outputTokens, model, createdAt, role]
            )
        }
    }
}

// MARK: - PluginExecutableRunner Tests

struct PluginExecutableRunnerTests {
    @Test
    func parsesNDJSONOutput() async throws {
        let pluginDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-exec-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let script = pluginDir.appendingPathComponent("test.sh")
        try """
        #!/bin/bash
        echo '{"id":"evt-1","timestamp":"2026-05-27T10:00:00Z","input_tokens":1500,"output_tokens":800,"model":"gpt-4o","session_id":"s1","project":"myproj"}'
        echo '{"id":"evt-2","timestamp":"2026-05-27T10:05:00Z","input_tokens":2200,"output_tokens":1100,"model":"gpt-4o"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = PluginExecutableSource(command: "bash", script: "test.sh", timeoutSeconds: 10)
        let result = try await PluginExecutableRunner.run(
            config: config,
            pluginDir: pluginDir,
            timestampFormat: .iso8601
        )

        #expect(result.events.count == 2)
        #expect(result.events[0].id == "evt-1")
        #expect(result.events[0].inputTokens == 1500)
        #expect(result.events[0].outputTokens == 800)
        #expect(result.events[0].modelName == "gpt-4o")
        #expect(result.events[0].projectName == "myproj")
        #expect(result.events[1].id == "evt-2")
        #expect(result.events[1].inputTokens == 2200)

        try? FileManager.default.removeItem(at: pluginDir)
    }

    @Test
    func handlesNonZeroExitCode() async throws {
        let pluginDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-exec-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let script = pluginDir.appendingPathComponent("fail.sh")
        try """
        #!/bin/bash
        echo "error: something went wrong" >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = PluginExecutableSource(command: "bash", script: "fail.sh", timeoutSeconds: 10)
        let result = try await PluginExecutableRunner.run(config: config, pluginDir: pluginDir)

        #expect(result.events.isEmpty)
        #expect(result.warnings.contains { $0.message.contains("exited with code 1") })

        try? FileManager.default.removeItem(at: pluginDir)
    }

    @Test
    func handlesMalformedJSON() async throws {
        let pluginDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-exec-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let script = pluginDir.appendingPathComponent("bad.sh")
        try """
        #!/bin/bash
        echo '{"id":"evt-1","input_tokens":100,"output_tokens":50}'
        echo 'not json'
        echo '{"id":"evt-3","input_tokens":200,"output_tokens":100}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = PluginExecutableSource(command: "bash", script: "bad.sh", timeoutSeconds: 10)
        let result = try await PluginExecutableRunner.run(config: config, pluginDir: pluginDir)

        #expect(result.events.count == 2)
        #expect(result.warnings.contains { $0.message.contains("malformed JSON") })

        try? FileManager.default.removeItem(at: pluginDir)
    }
}

// MARK: - PluginManager Tests

struct PluginManagerTests {
    @Test
    func manifestToRecordJSONL() {
        let manifest = makeJSONLManifest()
        let store = UsageStore()
        let manager = PluginManager(store: store)
        let record = manager.manifestToRecord(manifest)

        #expect(record.pluginId == "test-jsonl")
        #expect(record.pluginVersion == "1.0.0")
        #expect(record.plugin == .claudeCode)
        #expect(record.directory == "~/.test/logs")
        #expect(record.globPattern == "*.jsonl")
        #expect(record.inputIncludesCached == false)
        #expect(record.isPlugin == true)
    }

    @Test
    func manifestToRecordSQLite() {
        let manifest = makeSQLiteManifest()
        let store = UsageStore()
        let manager = PluginManager(store: store)
        let record = manager.manifestToRecord(manifest)

        #expect(record.pluginId == "test-sqlite")
        #expect(record.plugin == .pluginSqlite)
        #expect(record.sqliteQuery != nil)
        #expect(record.sqliteQuery?.table == "events")
    }

    @Test
    func manifestToRecordExecutable() {
        let manifest = makeExecutableManifest()
        let store = UsageStore()
        let manager = PluginManager(store: store)
        let record = manager.manifestToRecord(manifest)

        #expect(record.pluginId == "test-exec")
        #expect(record.plugin == .pluginExecutable)
        #expect(record.executableConfig != nil)
        #expect(record.executableConfig?.command == "python3")
        #expect(record.inputIncludesCached == true)
    }

    @Test
    func installAndUninstall() async throws {
        let tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-mgr-\(UUID().uuidString).sqlite")
        let store = try UsageStore(databaseURL: tempDB)
        let manager = PluginManager(store: store)

        let manifest = makeJSONLManifest()
        let manifestData = try JSONEncoder().encode(manifest)
        try await manager.install(manifest: manifest, manifestData: manifestData)

        let sources = try await store.customSources()
        #expect(sources.contains { $0.pluginId == "test-jsonl" })

        try await manager.uninstall(pluginId: "test-jsonl")
        let afterUninstall = try await store.customSources()
        #expect(!afterUninstall.contains { $0.pluginId == "test-jsonl" })
    }

    private func makeJSONLManifest() -> PluginManifest {
        PluginManifest(
            manifestVersion: 1,
            id: "test-jsonl",
            name: "Test JSONL",
            version: "1.0.0",
            description: "test",
            author: "test",
            source: .jsonl(PluginJSONLSource(
                directory: "~/.test/logs",
                glob: "*.jsonl",
                fields: PluginFieldMapping(
                    inputTokens: "usage.input",
                    outputTokens: "usage.output",
                    model: "model"
                )
            )),
            tokenSemantics: PluginTokenSemantics(inputIncludesCached: false, timestampFormat: .iso8601)
        )
    }

    private func makeSQLiteManifest() -> PluginManifest {
        PluginManifest(
            manifestVersion: 1,
            id: "test-sqlite",
            name: "Test SQLite",
            version: "1.0.0",
            description: "test",
            author: "test",
            source: .sqlite(PluginSQLiteSource(
                directory: "~/.test",
                glob: "data.db",
                query: PluginSQLiteQuery(
                    table: "events",
                    columns: PluginFieldMapping(
                        inputTokens: "input_count",
                        outputTokens: "output_count",
                        model: "model_name",
                        timestamp: "created_at"
                    ),
                    watermarkColumn: "created_at"
                )
            ))
        )
    }

    private func makeExecutableManifest() -> PluginManifest {
        PluginManifest(
            manifestVersion: 1,
            id: "test-exec",
            name: "Test Exec",
            version: "1.0.0",
            description: "test",
            author: "test",
            source: .executable(PluginExecutableSource(
                command: "python3",
                script: "collect.py",
                incrementalFlag: "--since",
                timeoutSeconds: 30
            )),
            tokenSemantics: PluginTokenSemantics(inputIncludesCached: true, timestampFormat: .iso8601)
        )
    }
}

// MARK: - TimestampFormat Tests

struct TimestampFormatTests {
    @Test
    func parsesISO8601() {
        let date = PluginTimestampFormat.iso8601.parse("2026-05-27T10:30:00Z")
        #expect(date != nil)
    }

    @Test
    func parsesUnixSeconds() {
        let date = PluginTimestampFormat.unixS.parse(1716800000)
        #expect(date != nil)
        #expect(date!.timeIntervalSince1970 == 1716800000)
    }

    @Test
    func parsesUnixMilliseconds() {
        let date = PluginTimestampFormat.unixMs.parse(1716800000000)
        #expect(date != nil)
        #expect(date!.timeIntervalSince1970 == 1716800000)
    }

    @Test
    func parsesUnixNano() {
        let date = PluginTimestampFormat.unixNano.parse(UInt64(1716800000000000000))
        #expect(date != nil)
    }

    @Test
    func parsesStringNumbers() {
        let date = PluginTimestampFormat.unixS.parse("1716800000")
        #expect(date != nil)
    }

    @Test
    func returnsNilForInvalidInput() {
        let date = PluginTimestampFormat.iso8601.parse(12345)
        #expect(date == nil)
    }
}

// MARK: - DB Migration Tests

struct PluginDBMigrationTests {
    @Test
    func migrationAddsPluginColumns() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-migration-\(UUID().uuidString).sqlite")
        let db = try UsageDatabase(url: dbURL)

        try db.queue.read { db in
            let columns = try db.columns(in: "custom_sources")
            let columnNames = columns.map(\.name)
            #expect(columnNames.contains("plugin_id"))
            #expect(columnNames.contains("plugin_version"))
            #expect(columnNames.contains("input_includes_cached"))
            #expect(columnNames.contains("timestamp_format"))
            #expect(columnNames.contains("sqlite_query"))
            #expect(columnNames.contains("executable_config"))
        }
    }
}

// MARK: - CustomSourcePlugin Tests

struct CustomSourcePluginPluginTests {
    @Test
    func pluginSqliteProperties() {
        let engine = CustomSourcePlugin.pluginSqlite
        #expect(engine.isPlugin == true)
        #expect(engine.agentKind == .custom)
        #expect(engine.parserKind == .custom)
        #expect(engine.displayName == "Plugin (SQLite)")
    }

    @Test
    func pluginExecutableProperties() {
        let engine = CustomSourcePlugin.pluginExecutable
        #expect(engine.isPlugin == true)
        #expect(engine.agentKind == .custom)
        #expect(engine.parserKind == .custom)
        #expect(engine.displayName == "Plugin (Executable)")
    }

    @Test
    func existingEnginesNotPlugin() {
        #expect(CustomSourcePlugin.claudeCode.isPlugin == false)
        #expect(CustomSourcePlugin.codex.isPlugin == false)
        #expect(CustomSourcePlugin.hermes.isPlugin == false)
    }
}

// MARK: - RegistryIndex Tests

struct RegistryIndexTests {
    @Test
    func decodesRegistryIndex() throws {
        let json = """
        {
          "registry_version": 1,
          "updated_at": "2026-05-27T00:00:00Z",
          "plugins": [
            {
              "id": "github-copilot",
              "name": "GitHub Copilot",
              "version": "1.0.0",
              "description": "OTel JSONL",
              "type": "declarative",
              "download_url": "https://example.com/plugins/github-copilot/manifest.json"
            }
          ]
        }
        """
        let index = try JSONDecoder().decode(PluginRegistryIndex.self, from: json.data(using: .utf8)!)
        #expect(index.registryVersion == 1)
        #expect(index.plugins.count == 1)
        #expect(index.plugins[0].id == "github-copilot")
        #expect(index.plugins[0].downloadUrl == "https://example.com/plugins/github-copilot/manifest.json")
    }
}
