import Foundation
import GRDB

/// Parses Kiro CLI usage from its SQLite store at
/// `~/Library/Application Support/kiro-cli/data.sqlite3`.
///
/// `conversations_v2(id, conversation TEXT, updated_at INTEGER)` stores one row
/// per conversation; `conversation` is a JSON object whose `history` array holds
/// turns. Assistant turns carry a usage object with token counts. Kiro reports
/// input WITHOUT the cached read folded in (`inputIncludesCached == false`)
/// unless a mock proves otherwise — see `kiro-接入.md`.
///
/// The exact field口径 is fixed by Subagent A's `kiro-接入.md`. This parser keys
/// off the documented `conversations_v2` shape: each assistant turn exposes a
/// usage dict under `usage` with `input_tokens` / `output_tokens` /
/// `cache_read_input_tokens` / `cache_creation_input_tokens` (CamelCase /
/// snake_case aliases accepted), a `model` / `model_id`, and the row carries the
/// per-turn message id used for dedup.
public enum KiroUsageParser {
    public static func parse(
        databaseURL: URL,
        watermark: SourceWatermark? = nil
    ) throws -> UsageSourceLoadResult {
        let sourcePath = databaseURL.path
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: sourcePath, configuration: configuration)

        return try queue.read { db in
            let currentFingerprint = try? JSONLIncrementalReader.fingerprint(at: sourcePath)
            var warnings: [UsageSourceWarning] = []

            let effectiveWatermark: SourceWatermark?
            if let watermark,
               let currentFingerprint,
               let lastInode = watermark.lastInode,
               currentFingerprint.inode != lastInode {
                effectiveWatermark = nil
                warnings.append(
                    UsageSourceWarning(
                        sourceName: "Kiro",
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "forced full reparse: inode changed \(lastInode) -> \(currentFingerprint.inode)"
                    )
                )
            } else {
                effectiveWatermark = watermark
            }

            var arguments = StatementArguments()
            var filter = ""
            if let effectiveWatermark {
                filter = "AND updated_at > ?"
                let ts = Int64(effectiveWatermark.lastMtime.timeIntervalSince1970 * 1_000)
                arguments += [ts]
            }

            let rows = try Row.fetchAll(db, sql: """
            SELECT id           AS id,
                   conversation AS conversation,
                   updated_at   AS updated_at
            FROM conversations_v2
            WHERE 1=1 \(filter)
            ORDER BY updated_at ASC, id ASC
            """, arguments: arguments)

            var events: [UsageEvent] = []
            for row in rows {
                let conversationID: String = row["id"] ?? "unknown"
                let updatedAt: Int64 = row["updated_at"] ?? 0
                let conversationText: String? = row["conversation"]

                guard let conversationText,
                      !conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let data = conversationText.data(using: .utf8),
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    continue
                }

                let projectName = resolveProject(root) ?? "kiro"
                let projectPath = (root["cwd"] as? String) ?? (root["workspace"] as? String)
                let sessionID = (root["conversation_id"] as? String) ?? conversationID
                let conversationModel = stringValue(root, "model", "model_id", "modelId")
                let turns = assistantTurns(root)

                for (idx, turn) in turns.enumerated() {
                    guard let usage = turn["usage"] as? [String: Any] else { continue }

                    let input = intValue(usage, "input_tokens", "inputTokens", "input")
                    let output = intValue(usage, "output_tokens", "outputTokens", "output")
                    let cacheRead = intValue(usage, "cache_read_input_tokens", "cacheReadInputTokens", "cache_read_tokens", "cacheReadTokens")
                    let cacheCreation = intValue(usage, "cache_creation_input_tokens", "cacheCreationInputTokens", "cache_write_tokens", "cacheCreationTokens")
                    guard input + output + cacheRead + cacheCreation > 0 else { continue }

                    let turnID = (turn["id"] as? String)
                        ?? (turn["message_id"] as? String)
                        ?? "\(sessionID)#\(idx)"
                    let model = stringValue(turn, "model", "model_id", "modelId")
                        ?? stringValue(usage, "model", "model_id", "modelId")
                        ?? conversationModel

                    events.append(
                        UsageEvent(
                            id: "\(sourcePath)#kiro#\(turnID)",
                            agent: .kiro,
                            projectPath: projectPath,
                            projectName: projectName,
                            sessionId: sessionID,
                            timestamp: .tokenBarDate(millisecondsSince1970: updatedAt),
                            inputTokens: max(input, 0),
                            outputTokens: max(output, 0),
                            cacheReadTokens: max(cacheRead, 0),
                            cacheCreationTokens: max(cacheCreation, 0),
                            reasoningTokens: nil,
                            modelName: model,
                            sourcePath: sourcePath,
                            parser: .kiro,
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
            let prefix = "\(sourcePath)#kiro#"
            let nextLastEventId = maxEvent
                .map { String($0.id.dropFirst(prefix.count)) }
                ?? watermark?.lastEventId

            let nextWatermark = SourceWatermark(
                sourcePath: sourcePath,
                agent: .kiro,
                lastMtime: maxEvent?.timestamp ?? watermark?.lastMtime ?? .distantPast,
                lastByteOffset: 0,
                lastEventId: nextLastEventId,
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

    /// Extracts assistant turns from the conversation JSON. Kiro nests turns
    /// under `history` (array of turns); a turn may itself be an array of
    /// [user, assistant] entries, or a flat dict. We collect any dict that
    /// carries a `usage` object and is not explicitly a user/tool role.
    private static func assistantTurns(_ root: [String: Any]) -> [[String: Any]] {
        var collected: [[String: Any]] = []
        let history = (root["history"] as? [Any]) ?? (root["transcript"] as? [Any]) ?? []
        collectTurns(from: history, into: &collected)
        return collected
    }

    private static func collectTurns(from any: Any, into collected: inout [[String: Any]]) {
        if let array = any as? [Any] {
            for element in array {
                collectTurns(from: element, into: &collected)
            }
            return
        }
        guard let dict = any as? [String: Any] else { return }
        if dict["usage"] is [String: Any] {
            let role = (dict["role"] as? String) ?? (dict["type"] as? String)
            if role == nil || role == "assistant" || role == "Assistant" {
                collected.append(dict)
                return
            }
        }
        // Recurse into nested containers (e.g. {"Response": {...usage...}}).
        for value in dict.values {
            if value is [Any] || value is [String: Any] {
                collectTurns(from: value, into: &collected)
            }
        }
    }

    private static func resolveProject(_ root: [String: Any]) -> String? {
        for key in ["cwd", "workspace", "project", "directory"] {
            if let path = root[key] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        return nil
    }

    private static func intValue(_ object: [String: Any], _ keys: String...) -> Int {
        for key in keys {
            if let raw = object[key] {
                if let n = raw as? NSNumber { return n.intValue }
                if let n = raw as? Int { return n }
                if let s = raw as? String, let n = Int(s) { return n }
            }
        }
        return 0
    }

    private static func stringValue(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
