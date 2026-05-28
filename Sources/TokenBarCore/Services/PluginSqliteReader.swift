import Foundation
import GRDB

public enum PluginSqliteReader {
    private static let allowedIdentifierPattern = #"^[a-zA-Z_][a-zA-Z0-9_]*$"#

    public static func parse(
        databaseURL: URL,
        query: PluginSQLiteQuery,
        timestampFormat: PluginTimestampFormat = .iso8601,
        watermark: SourceWatermark? = nil
    ) throws -> UsageSourceLoadResult {
        let sourcePath = databaseURL.path
        var events: [UsageEvent] = []
        var warnings: [UsageSourceWarning] = []

        guard isValidIdentifier(query.table) else {
            warnings.append(UsageSourceWarning(
                sourceName: "plugin-sqlite",
                sourcePath: sourcePath,
                lineNumber: nil,
                message: "invalid table name: \(query.table)"
            ))
            return UsageSourceLoadResult(events: [], warnings: warnings)
        }

        let selectColumns = buildSelectColumns(query.columns)
        guard !selectColumns.isEmpty else {
            warnings.append(UsageSourceWarning(
                sourceName: "plugin-sqlite",
                sourcePath: sourcePath,
                lineNumber: nil,
                message: "no valid column mappings found"
            ))
            return UsageSourceLoadResult(events: [], warnings: warnings)
        }

        let dbQueue: DatabaseQueue
        do {
            var config = Configuration()
            config.readonly = true
            dbQueue = try DatabaseQueue(path: sourcePath, configuration: config)
        } catch {
            warnings.append(UsageSourceWarning(
                sourceName: "plugin-sqlite",
                sourcePath: sourcePath,
                lineNumber: nil,
                message: "failed to open database: \(error.localizedDescription)"
            ))
            return UsageSourceLoadResult(events: [], warnings: warnings)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: sourcePath)
        let currentInode = (attrs?[.systemFileNumber] as? UInt64) ?? 0
        let currentMtime = (attrs?[.modificationDate] as? Date) ?? Date()

        if let watermark, let lastInode = watermark.lastInode, lastInode != currentInode {
            warnings.append(UsageSourceWarning(
                sourceName: "plugin-sqlite",
                sourcePath: sourcePath,
                lineNumber: nil,
                message: "inode changed \(lastInode) → \(currentInode), forced full reparse"
            ))
        }

        let columnList = selectColumns.map(\.sql).joined(separator: ", ")
        var sql = "SELECT \(columnList) FROM \(query.table)"
        var arguments: [DatabaseValueConvertible] = []

        var conditions: [String] = []
        if let wmCol = query.watermarkColumn, isValidIdentifier(wmCol),
           let watermark, watermark.lastInode == currentInode || watermark.lastInode == nil {
            conditions.append("\(wmCol) > ?")
            arguments.append(watermark.lastMtime.tokenBarMillisecondsSince1970)
        }
        if let whereClause = query.where, !whereClause.isEmpty {
            conditions.append("(\(whereClause))")
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        if let wmCol = query.watermarkColumn, isValidIdentifier(wmCol) {
            sql += " ORDER BY \(wmCol) ASC"
        }

        do {
            try dbQueue.read { db in
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                for (idx, row) in rows.enumerated() {
                    let cols = query.columns
                    let inputTokens = intValue(row, column: cols.inputTokens) ?? 0
                    let outputTokens = intValue(row, column: cols.outputTokens) ?? 0
                    let cacheRead = intValue(row, column: cols.cacheReadTokens) ?? 0
                    let cacheCreation = intValue(row, column: cols.cacheCreationTokens) ?? 0
                    let reasoning = intValue(row, column: cols.reasoningTokens) ?? 0
                    let model = stringValue(row, column: cols.model)
                    let sessionId = stringValue(row, column: cols.sessionId) ?? "unknown"
                    let project = stringValue(row, column: cols.project) ?? databaseURL.deletingLastPathComponent().lastPathComponent

                    let timestamp: Date
                    if let tsCol = cols.timestamp, !tsCol.isEmpty, isValidIdentifier(tsCol) {
                        let rawTs: DatabaseValue = row[tsCol]
                        timestamp = parseTimestamp(rawTs, format: timestampFormat) ?? Date()
                    } else {
                        timestamp = Date()
                    }

                    let eventId = "\(sourcePath)#\(query.table)#\(idx)"

                    events.append(UsageEvent(
                        id: eventId,
                        agent: .custom,
                        projectPath: nil,
                        projectName: project,
                        sessionId: sessionId,
                        timestamp: timestamp,
                        inputTokens: max(inputTokens, 0),
                        outputTokens: max(outputTokens, 0),
                        cacheReadTokens: max(cacheRead, 0),
                        cacheCreationTokens: max(cacheCreation, 0),
                        reasoningTokens: reasoning > 0 ? reasoning : nil,
                        modelName: model,
                        sourcePath: sourcePath,
                        parser: .custom,
                        confidence: 1.0
                    ))
                }
            }
        } catch {
            warnings.append(UsageSourceWarning(
                sourceName: "plugin-sqlite",
                sourcePath: sourcePath,
                lineNumber: nil,
                message: "query failed: \(error.localizedDescription)"
            ))
        }

        let nextWatermark = SourceWatermark(
            sourcePath: sourcePath,
            agent: .custom,
            lastMtime: events.last?.timestamp ?? watermark?.lastMtime ?? currentMtime,
            lastByteOffset: 0,
            lastEventId: events.last?.id,
            lastInode: currentInode,
            updatedAt: Date()
        )

        return UsageSourceLoadResult(
            events: events,
            nextWatermarks: [nextWatermark],
            warnings: warnings
        )
    }

    private struct SelectColumn {
        let sql: String
    }

    private static func buildSelectColumns(_ mapping: PluginFieldMapping) -> [SelectColumn] {
        var cols: [SelectColumn] = []
        func add(_ field: String?) {
            guard let field, !field.isEmpty, isValidIdentifier(field) else { return }
            cols.append(SelectColumn(sql: field))
        }
        add(mapping.inputTokens)
        add(mapping.outputTokens)
        add(mapping.cacheReadTokens)
        add(mapping.cacheCreationTokens)
        add(mapping.reasoningTokens)
        add(mapping.model)
        add(mapping.timestamp)
        add(mapping.sessionId)
        add(mapping.project)
        return cols
    }

    private static func isValidIdentifier(_ name: String) -> Bool {
        name.range(of: allowedIdentifierPattern, options: .regularExpression) != nil
    }

    private static func intValue(_ row: Row, column: String?) -> Int? {
        guard let column, !column.isEmpty, isValidIdentifier(column) else { return nil }
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .int64(let v): return Int(v)
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private static func stringValue(_ row: Row, column: String?) -> String? {
        guard let column, !column.isEmpty, isValidIdentifier(column) else { return nil }
        let dbValue: DatabaseValue = row[column]
        switch dbValue.storage {
        case .string(let s): return s
        case .int64(let v): return String(v)
        default: return nil
        }
    }

    private static func parseTimestamp(_ dbValue: DatabaseValue, format: PluginTimestampFormat) -> Date? {
        switch dbValue.storage {
        case .int64(let v):
            return format.parse(v)
        case .double(let v):
            return format.parse(v)
        case .string(let s):
            return format.parse(s)
        default:
            return nil
        }
    }
}
