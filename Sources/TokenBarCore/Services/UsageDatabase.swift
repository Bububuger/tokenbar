import Foundation
import GRDB

public final class UsageDatabase: @unchecked Sendable {
    public let queue: DatabaseQueue

    public init(url: URL = UsageDatabase.defaultDatabaseURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        queue = try DatabaseQueue(path: url.path)
        try UsageDatabase.migrator.migrate(queue)
    }

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("tokenbar.sqlite")
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("initial") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS usage_events (
                id TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                project_path TEXT,
                project_name TEXT NOT NULL,
                session_id TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER,
                source_path TEXT NOT NULL,
                parser TEXT NOT NULL,
                confidence REAL NOT NULL
            );
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_ts ON usage_events(timestamp);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_project ON usage_events(project_name, timestamp);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_agent ON usage_events(agent, timestamp);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_session ON usage_events(session_id);")

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS prompts (
                id TEXT PRIMARY KEY,
                event_id TEXT,
                agent TEXT NOT NULL,
                project_name TEXT NOT NULL,
                session_id TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                content TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                source_path TEXT NOT NULL,
                FOREIGN KEY (event_id) REFERENCES usage_events(id)
            );
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_prompts_session ON prompts(session_id, timestamp);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_prompts_project ON prompts(project_name, timestamp);")

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS source_watermarks (
                source_path TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                last_mtime INTEGER NOT NULL,
                last_byte_offset INTEGER NOT NULL,
                last_event_id TEXT,
                updated_at INTEGER NOT NULL
            );
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS checkpoints (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                trigger TEXT NOT NULL,
                events_added INTEGER NOT NULL DEFAULT 0,
                prompts_added INTEGER NOT NULL DEFAULT 0,
                warnings INTEGER NOT NULL DEFAULT 0,
                error TEXT
            );
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS source_warnings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                checkpoint_id INTEGER,
                source_name TEXT NOT NULL,
                source_path TEXT NOT NULL,
                line_number INTEGER,
                message TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (checkpoint_id) REFERENCES checkpoints(id)
            );
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_source_warnings_checkpoint ON source_warnings(checkpoint_id);")

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS custom_sources (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                engine TEXT NOT NULL DEFAULT 'claudeCode',
                directory TEXT NOT NULL,
                glob_pattern TEXT NOT NULL,
                format TEXT NOT NULL,
                display_agent TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                field_mapping TEXT NOT NULL DEFAULT '{"inputTokens":"usage.input_tokens","outputTokens":"usage.output_tokens","cacheTokens":"usage.cache_read_tokens","model":"model"}',
                created_at INTEGER NOT NULL
            );
            """)
        }
        migrator.registerMigration("v2_add_inode_to_watermarks") { db in
            let columns = try db.columns(in: "source_watermarks")
            if !columns.contains(where: { $0.name == "last_inode" }) {
                try db.alter(table: "source_watermarks") { table in
                    table.add(column: "last_inode", .integer)
                }
            }
        }
        migrator.registerMigration("v3_ensure_source_warnings_table") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS source_warnings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                checkpoint_id INTEGER,
                source_name TEXT NOT NULL,
                source_path TEXT NOT NULL,
                line_number INTEGER,
                message TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (checkpoint_id) REFERENCES checkpoints(id)
            );
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_source_warnings_checkpoint ON source_warnings(checkpoint_id);")
        }
        migrator.registerMigration("v4_add_model_name_to_usage_events") { db in
            let columns = try db.columns(in: "usage_events")
            if !columns.contains(where: { $0.name == "model_name" }) {
                try db.alter(table: "usage_events") { table in
                    table.add(column: "model_name", .text)
                }
                try db.execute(sql: "DELETE FROM source_watermarks")
            }
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_model_name ON usage_events(model_name);")
        }
        migrator.registerMigration("v5_add_custom_source_field_mapping") { db in
            let columns = try db.columns(in: "custom_sources")
            if !columns.contains(where: { $0.name == "field_mapping" }) {
                try db.alter(table: "custom_sources") { table in
                    table.add(column: "field_mapping", .text)
                }
                try db.execute(sql: """
                UPDATE custom_sources
                SET field_mapping = '{"inputTokens":"usage.input_tokens","outputTokens":"usage.output_tokens","cacheTokens":"usage.cache_read_tokens","model":"model"}'
                WHERE field_mapping IS NULL OR LENGTH(TRIM(field_mapping)) = 0
                """)
            }
        }
        migrator.registerMigration("v6_add_custom_source_engine") { db in
            let columns = try db.columns(in: "custom_sources")
            if !columns.contains(where: { $0.name == "engine" }) {
                try db.alter(table: "custom_sources") { table in
                    table.add(column: "engine", .text)
                }
                try db.execute(sql: """
                UPDATE custom_sources
                SET engine = CASE
                    WHEN format = 'codex_jsonl' THEN 'codex'
                    WHEN format = 'claude_code_jsonl' THEN 'claudeCode'
                    ELSE 'claudeCode'
                END
                WHERE engine IS NULL OR LENGTH(TRIM(engine)) = 0
                """)
            }
        }
        migrator.registerMigration("v7_deduplicate_custom_sources_by_path") { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, directory, glob_pattern
                FROM custom_sources
                ORDER BY created_at ASC, name ASC
                """
            )
            var seenKeys = Set<String>()
            for row in rows {
                let id: String = row["id"]
                let directory: String = row["directory"]
                let globPattern: String = row["glob_pattern"]
                let key = CustomSourceRecord.sourcePathKey(directory: directory, globPattern: globPattern)
                if seenKeys.contains(key) {
                    try db.execute(sql: "DELETE FROM custom_sources WHERE id = ?", arguments: [id])
                } else {
                    seenKeys.insert(key)
                }
            }
        }
        return migrator
    }
}

extension Date {
    var tokenBarMillisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1_000).rounded())
    }

    static func tokenBarDate(millisecondsSince1970 value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
    }
}
