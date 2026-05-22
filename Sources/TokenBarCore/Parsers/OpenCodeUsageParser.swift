import Foundation
import GRDB

public enum OpenCodeUsageParser {
    public static func parse(
        databaseURL: URL,
        watermark: SourceWatermark? = nil
    ) throws -> UsageSourceLoadResult {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        return try queue.read { db in
            let currentFingerprint = try? JSONLIncrementalReader.fingerprint(at: databaseURL.path)
            var warnings: [UsageSourceWarning] = []

            let effectiveWatermark: SourceWatermark?
            if let watermark,
               let currentFingerprint,
               let lastInode = watermark.lastInode,
               currentFingerprint.inode != lastInode {
                effectiveWatermark = nil
                warnings.append(
                    UsageSourceWarning(
                        sourceName: "OpenCode",
                        sourcePath: databaseURL.path,
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
                filter = "AND (m.time_created > ? OR (m.time_created = ? AND m.id > ?))"
                let ts = Int64(effectiveWatermark.lastMtime.timeIntervalSince1970 * 1_000)
                arguments += [ts, ts, effectiveWatermark.lastEventId ?? ""]
            }

            let rows = try Row.fetchAll(db, sql: """
            SELECT m.id           AS id,
                   m.session_id   AS session_id,
                   m.time_created AS time_created,
                   m.data         AS data,
                   p.worktree     AS project_path,
                   p.name         AS project_name
            FROM message m
            JOIN session s ON s.id = m.session_id
            JOIN project p ON p.id = s.project_id
            WHERE 1=1 \(filter)
            ORDER BY m.time_created ASC, m.id ASC
            """, arguments: arguments)

            var events: [UsageEvent] = []
            let decoder = JSONDecoder()
            for row in rows {
                let messageID: String = row["id"]
                let sessionID: String = row["session_id"]
                let timeCreated: Int64 = row["time_created"] ?? 0
                let dataText: String = row["data"] ?? ""
                let projectPath: String? = row["project_path"]
                let projectNameRaw: String? = row["project_name"]

                guard let payloadData = dataText.data(using: .utf8),
                      let payload = try? decoder.decode(OpenCodeMessagePayload.self, from: payloadData) else {
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: "OpenCode",
                            sourcePath: databaseURL.path,
                            lineNumber: nil,
                            message: "malformed message.data for id=\(messageID)"
                        )
                    )
                    continue
                }

                guard payload.role == "assistant" else {
                    continue
                }

                guard let tokens = payload.tokens else {
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: "OpenCode",
                            sourcePath: databaseURL.path,
                            lineNumber: nil,
                            message: "token_count record missing usage for opencode assistant message id=\(messageID) (provider=\(payload.providerID ?? "unknown"))"
                        )
                    )
                    continue
                }

                let input = max(tokens.input ?? 0, 0)
                let output = max(tokens.output ?? 0, 0)
                let cacheRead = max(tokens.cache?.read ?? 0, 0)
                let cacheWrite = max(tokens.cache?.write ?? 0, 0)
                let cache = cacheRead + cacheWrite
                let reasoning = tokens.reasoning.map { max($0, 0) }

                guard input + output + cache + (reasoning ?? 0) > 0 else {
                    warnings.append(
                        UsageSourceWarning(
                            sourceName: "OpenCode",
                            sourcePath: databaseURL.path,
                            lineNumber: nil,
                            message: "token_count usage fields are incomplete (zero-sum) for opencode message id=\(messageID)"
                        )
                    )
                    continue
                }

                let projectName: String = {
                    if let projectNameRaw, !projectNameRaw.isEmpty {
                        return projectNameRaw
                    }
                    if let projectPath, !projectPath.isEmpty {
                        return URL(fileURLWithPath: projectPath).lastPathComponent
                    }
                    return "opencode"
                }()

                events.append(
                    UsageEvent(
                        id: "\(databaseURL.path)#opencode#\(messageID)",
                        agent: .openCode,
                        projectPath: projectPath,
                        projectName: projectName,
                        sessionId: sessionID,
                        timestamp: .tokenBarDate(millisecondsSince1970: timeCreated),
                        inputTokens: input,
                        outputTokens: output,
                        cacheTokens: cache,
                        reasoningTokens: reasoning,
                        modelName: payload.modelID,
                        sourcePath: databaseURL.path,
                        parser: .openCode,
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
            let prefix = "\(databaseURL.path)#opencode#"
            let nextLastEventId = maxEvent
                .map { String($0.id.dropFirst(prefix.count)) }
                ?? watermark?.lastEventId

            let nextWatermark = SourceWatermark(
                sourcePath: databaseURL.path,
                agent: .openCode,
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
}

private struct OpenCodeMessagePayload: Decodable {
    let role: String?
    let modelID: String?
    let providerID: String?
    let tokens: OpenCodeTokens?
}

private struct OpenCodeTokens: Decodable {
    let input: Int?
    let output: Int?
    let reasoning: Int?
    let cache: OpenCodeCacheTokens?
}

private struct OpenCodeCacheTokens: Decodable {
    let read: Int?
    let write: Int?
}
