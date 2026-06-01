import Foundation
import GRDB

/// Parses Qoder Desktop usage from its SQLite cache at
/// `~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db`.
///
/// `chat_message` rows carry a `token_info` JSON blob
/// (`prompt_tokens` / `completion_tokens` / `cached_tokens`) and a `model_info`
/// JSON blob (`model`, fallback `model_key` / `preferred_model_info.preferred_model`).
/// Each message JOINs `chat_session` for the workspace path. Qoder's
/// `prompt_tokens` is the FULL prompt that already includes the cached read, so
/// `inputIncludesCached == true` — normalization subtracts the cached read.
public enum QoderUsageParser {
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
                        sourceName: "Qoder",
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
                filter = "AND (m.gmt_create > ? OR (m.gmt_create = ? AND m.id > ?))"
                let ts = Int64(effectiveWatermark.lastMtime.timeIntervalSince1970 * 1_000)
                arguments += [ts, ts, effectiveWatermark.lastEventId ?? ""]
            }

            // Qoder's schema drifts across versions: the `chat_session.workspace`
            // column the JOIN relied on is absent on newer installs (they expose
            // `project_uri` / `project_name` instead), which made the query throw
            // "no such column: s.workspace" and fail the whole source — sticking
            // the indexing progress bar. Probe the columns and select the first
            // workspace-like one that exists; if none and no session table at
            // all, drop the JOIN entirely and fall back to a "qoder" project.
            let sessionColumns = Set(((try? db.columns(in: "chat_session")) ?? []).map { $0.name })
            let workspaceColumn = ["workspace", "project_uri", "project_name"].first { sessionColumns.contains($0) }
            let workspaceSelect = workspaceColumn.map { "s.\($0)   AS workspace" } ?? "NULL          AS workspace"
            let sessionJoin = workspaceColumn != nil ? "LEFT JOIN chat_session s ON s.session_id = m.session_id" : ""

            let rows = try Row.fetchAll(db, sql: """
            SELECT m.id          AS id,
                   m.session_id  AS session_id,
                   m.gmt_create  AS gmt_create,
                   m.token_info  AS token_info,
                   m.model_info  AS model_info,
                   \(workspaceSelect)
            FROM chat_message m
            \(sessionJoin)
            WHERE 1=1 \(filter)
            ORDER BY m.gmt_create ASC, m.id ASC
            """, arguments: arguments)

            var events: [UsageEvent] = []
            for row in rows {
                let messageID: String = row["id"] ?? ""
                let sessionID: String = row["session_id"] ?? "unknown"
                let gmtCreate: Int64 = row["gmt_create"] ?? 0
                let tokenInfoText: String? = row["token_info"]
                let modelInfoText: String? = row["model_info"]
                let workspace: String? = row["workspace"]

                guard let tokenInfoText,
                      !tokenInfoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let tokenData = tokenInfoText.data(using: .utf8),
                      let tokenObject = (try? JSONSerialization.jsonObject(with: tokenData)) as? [String: Any] else {
                    // Empty / missing token_info → user turns, system rows; skip silently.
                    continue
                }

                let prompt = intValue(tokenObject["prompt_tokens"])
                let completion = intValue(tokenObject["completion_tokens"])
                let cached = intValue(tokenObject["cached_tokens"])
                guard prompt + completion + cached > 0 else { continue }

                let normalized = TokenNormalizer.normalize(
                    rawInput: prompt,
                    rawOutput: completion,
                    cacheRead: cached,
                    cacheCreation: 0,
                    reasoning: 0,
                    inputIncludesCached: true
                )

                let model = resolveModel(modelInfoText)
                let projectName: String = {
                    if let workspace, !workspace.isEmpty {
                        return URL(fileURLWithPath: workspace).lastPathComponent
                    }
                    return "qoder"
                }()

                events.append(
                    UsageEvent(
                        id: "\(sourcePath)#qoder#\(messageID)",
                        agent: .qoder,
                        projectPath: workspace,
                        projectName: projectName,
                        sessionId: sessionID,
                        timestamp: .tokenBarDate(millisecondsSince1970: gmtCreate),
                        inputTokens: normalized.input,
                        outputTokens: normalized.output,
                        cacheReadTokens: normalized.cacheRead,
                        cacheCreationTokens: normalized.cacheCreation,
                        reasoningTokens: nil,
                        modelName: model,
                        sourcePath: sourcePath,
                        parser: .qoder,
                        confidence: 1.0
                    )
                )
            }

            let maxEvent = events.max { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id < rhs.id
                }
                return lhs.timestamp < rhs.timestamp
            }
            let prefix = "\(sourcePath)#qoder#"
            let nextLastEventId = maxEvent
                .map { String($0.id.dropFirst(prefix.count)) }
                ?? watermark?.lastEventId

            let nextWatermark = SourceWatermark(
                sourcePath: sourcePath,
                agent: .qoder,
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

    private static func resolveModel(_ text: String?) -> String? {
        guard let text,
              let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let model = object["model"] as? String, !model.isEmpty { return model }
        if let key = object["model_key"] as? String, !key.isEmpty { return key }
        if let preferred = object["preferred_model_info"] as? [String: Any],
           let model = preferred["preferred_model"] as? String, !model.isEmpty {
            return model
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let n = raw as? Int { return n }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }
}
