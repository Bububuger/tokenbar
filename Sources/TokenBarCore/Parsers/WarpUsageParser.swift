import Foundation
import GRDB

public enum WarpUsageParser {
    public static func parse(databaseURL: URL, watermark: SourceWatermark? = nil) throws -> UsageSourceLoadResult {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        return try queue.read { db in
            let currentFingerprint = try? JSONLIncrementalReader.fingerprint(at: databaseURL.path)
            let effectiveWatermark: SourceWatermark?
            var warnings: [UsageSourceWarning] = []

            if let watermark,
               let currentFingerprint,
               let lastInode = watermark.lastInode,
               currentFingerprint.inode != lastInode {
                effectiveWatermark = nil
                warnings.append(
                    UsageSourceWarning(
                        sourceName: "Warp",
                        sourcePath: databaseURL.path,
                        lineNumber: nil,
                        message: "forced full reparse: inode changed \(lastInode) -> \(currentFingerprint.inode)"
                    )
                )
            } else {
                effectiveWatermark = watermark
            }

            guard hasTable("agent_conversations", db: db) else {
                return UsageSourceLoadResult(events: [], prompts: [], nextWatermarks: [], warnings: warnings)
            }

            var arguments = StatementArguments()
            var filter = ""
            if let effectiveWatermark {
                filter = "WHERE last_modified_at > ?"
                arguments += [effectiveWatermark.lastMtime]
            }

            let rows = try Row.fetchAll(db, sql: """
            SELECT conversation_id, conversation_data, last_modified_at
            FROM agent_conversations
            \(filter)
            ORDER BY last_modified_at ASC
            """, arguments: arguments)

            var events: [UsageEvent] = []
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            for row in rows {
                let conversationId: String = row["conversation_id"]
                let jsonText: String = row["conversation_data"] ?? "{}"
                let lastModified: Date = row["last_modified_at"] ?? .distantPast

                guard let jsonData = jsonText.data(using: .utf8) else {
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: "Warp",
                            sourcePath: databaseURL.path,
                            lineNumber: nil,
                            message: "invalid UTF-8 in conversation_data for \(conversationId)"
                        )
                    )
                    continue
                }

                let conversationData: WarpConversationData
                do {
                    conversationData = try decoder.decode(WarpConversationData.self, from: jsonData)
                } catch {
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: "Warp",
                            sourcePath: databaseURL.path,
                            lineNumber: nil,
                            message: "JSON decode failed for \(conversationId): \(error.localizedDescription)"
                        )
                    )
                    continue
                }

                guard let metadata = conversationData.conversationUsageMetadata else { continue }

                let projectName = deriveProjectName(
                    conversationId: conversationId,
                    db: db
                ) ?? "Warp"

                for tokenUsage in metadata.tokenUsage {
                    let totalTokens = Int(tokenUsage.warpTokens) + Int(tokenUsage.byokTokens)
                    guard totalTokens > 0 else { continue }

                    events.append(
                        UsageEvent(
                            id: "\(databaseURL.path)#warp#\(conversationId)#\(tokenUsage.modelId)",
                            agent: .warp,
                            projectPath: nil,
                            projectName: projectName,
                            sessionId: conversationId,
                            timestamp: lastModified,
                            inputTokens: 0,
                            outputTokens: totalTokens,
                            cacheReadTokens: 0,
                            cacheCreationTokens: 0,
                            reasoningTokens: nil,
                            modelName: tokenUsage.modelId,
                            sourcePath: databaseURL.path,
                            parser: .warp,
                            confidence: 1.0
                        )
                    )
                }
            }

            let maxEvent = events.max { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id < rhs.id
                }
                return lhs.timestamp < rhs.timestamp
            }
            let nextWatermark = SourceWatermark(
                sourcePath: databaseURL.path,
                agent: .warp,
                lastMtime: maxEvent?.timestamp ?? watermark?.lastMtime ?? .distantPast,
                lastByteOffset: 0,
                lastEventId: maxEvent?.id ?? watermark?.lastEventId,
                lastInode: currentFingerprint?.inode ?? watermark?.lastInode,
                updatedAt: Date()
            )

            return UsageSourceLoadResult(
                events: events,
                prompts: [],
                nextWatermarks: [nextWatermark],
                warnings: warnings
            )
        }
    }

    private static func hasTable(_ table: String, db: Database) -> Bool {
        guard let count = try? Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
            arguments: [table]
        ) else {
            return false
        }
        return count > 0
    }

    private static func deriveProjectName(conversationId: String, db: Database) -> String? {
        guard hasTable("ai_queries", db: db) else { return nil }
        guard let row = try? Row.fetchOne(
            db,
            sql: "SELECT working_directory FROM ai_queries WHERE conversation_id = ? AND working_directory IS NOT NULL LIMIT 1",
            arguments: [conversationId]
        ) else {
            return nil
        }
        let workingDir: String? = row["working_directory"]
        guard let dir = workingDir, !dir.isEmpty else { return nil }
        let basename = (dir as NSString).lastPathComponent
        return basename.isEmpty ? nil : basename
    }
}

struct WarpConversationData: Decodable {
    let conversationUsageMetadata: WarpUsageMetadata?
}

struct WarpUsageMetadata: Decodable {
    let tokenUsage: [WarpModelTokenUsage]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokenUsage = (try? container.decodeIfPresent([WarpModelTokenUsage].self, forKey: .tokenUsage)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case tokenUsage
    }
}

struct WarpModelTokenUsage: Decodable {
    let modelId: String
    let warpTokens: UInt32
    let byokTokens: UInt32

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelId = (try? container.decodeIfPresent(String.self, forKey: .modelId)) ?? "unknown"
        self.warpTokens = (try? container.decodeIfPresent(UInt32.self, forKey: .warpTokens))
            ?? (try? container.decodeIfPresent(UInt32.self, forKey: .totalTokens))
            ?? 0
        self.byokTokens = (try? container.decodeIfPresent(UInt32.self, forKey: .byokTokens)) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case modelId
        case warpTokens
        case totalTokens
        case byokTokens
    }
}
