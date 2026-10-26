import Foundation

/// Parses DeepSeek Harness (DSH) session JSONL files.
///
/// DSH stores one zstd-compressed JSONL file per session under
/// <DSH_HOME>/sessions/<project-slug>/<session-id>/session.v4.jsonl.zstd
/// (v4) or session.jsonl.zstd (legacy v0). The event source decompresses
/// before handing lines here, so the parser itself is format-only.
///
/// Line shape (both versions):
///   { "type": ..., "seq": <monotonic int>, "time": <ms epoch>, "data": ... }
///
/// Token usage comes from "assistant/message" events:
///   data.usage = { inputTokens, outputTokens, totalTokens?, cacheReadTokens?,
///                  cacheWriteTokens?, reasoningTokens? }
/// - inputTokens is already cache-exclusive (DSH's own rollup calls it
///   uncachedInputTokens), so inputIncludesCached == false.
/// - totalTokens is the per-request total (input + output + cacheRead), not a
///   cumulative figure; it is ignored in favour of the raw components.
///
/// The legacy v0 format additionally carries reasoningTokens; v4 does not.
/// "assistant/attempt" events only mirror stream chunks (usage is always 0 or
/// a duplicate of the accepted message) and must NOT be counted.
///
/// Project attribution comes from the leading "session" event (data.cwd).
/// Human prompts are "user/message" events whose data.source.kind == "user";
/// every other kind (agent-instructions, plugin, skill-catalog,
/// runtime-context, model-selection, ...) is an injected message and is
/// filtered out.
public enum DshUsageParser {
    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL
    ) -> ParseResult {
        let sourcePath = fileURL.path
        let sessionID = resolveSessionID(fileURL: fileURL)
        var projectPath: String?
        var sessionCreatedAt: Date?

        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var warnings: [ParseWarning] = []
        // A user/message record (any source.kind — injected context also
        // dispatches a turn) is the generation boundary; the next
        // assistant/message pairs against it and consumes it. assistant/attempt
        // stream mirrors are not boundaries.
        var lastTriggerMs: Int64?

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            let eventType = object["type"] as? String ?? ""
            let payload = object["data"] as? [String: Any] ?? [:]
            let seq = intValue(object["seq"])
            let timestamp = resolveTimestamp(object) ?? sessionCreatedAt ?? .distantPast

            if eventType == "user/message",
               let triggerTimestamp = resolveTimestamp(object) {
                lastTriggerMs = triggerTimestamp.tokenBarMillisecondsSince1970
            }

            switch eventType {
            case "session":
                // Leading identity row. NOTE: id/createdAt/cwd are TOP-LEVEL
                // fields on this event, not nested under "data".
                projectPath = object["cwd"] as? String ?? projectPath
                if let created = object["createdAt"] as? NSNumber {
                    sessionCreatedAt = Date(timeIntervalSince1970: created.doubleValue / 1000.0)
                }

            case "assistant/message":
                let startMs = lastTriggerMs
                lastTriggerMs = nil
                let endMs = timestamp.tokenBarMillisecondsSince1970
                let generationStartMs = (startMs != nil && startMs! < endMs) ? startMs : nil
                appendUsageEvent(
                    payload: payload,
                    object: object,
                    seq: seq,
                    timestamp: timestamp,
                    sourcePath: sourcePath,
                    sessionID: sessionID,
                    projectPath: projectPath,
                    fileURL: fileURL,
                    lineNumber: line.lineNumber,
                    events: &events,
                    warnings: &warnings,
                    generationStartMs: generationStartMs,
                    generationEndMs: generationStartMs != nil ? endMs : nil
                )

            case "user/message":
                appendPromptRecord(
                    payload: payload,
                    seq: seq,
                    timestamp: timestamp,
                    sourcePath: sourcePath,
                    sessionID: sessionID,
                    projectPath: projectPath,
                    fileURL: fileURL,
                    lineNumber: line.lineNumber,
                    prompts: &prompts
                )

            default:
                continue
            }
        }

        return ParseResult(events: events, prompts: prompts, warnings: warnings)
    }

    /// <session-id>/session.v4.jsonl.zstd and <session-id>/session.jsonl.zstd
    /// both sit directly below their session directory.
    private static func resolveSessionID(fileURL: URL) -> String {
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        if parent.hasPrefix("session-") {
            return parent
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private static func appendUsageEvent(
        payload: [String: Any],
        object: [String: Any],
        seq: Int,
        timestamp: Date,
        sourcePath: String,
        sessionID: String,
        projectPath: String?,
        fileURL: URL,
        lineNumber: Int,
        events: inout [UsageEvent],
        warnings: inout [ParseWarning],
        generationStartMs: Int64?,
        generationEndMs: Int64?
    ) {
        guard let usage = payload["usage"] as? [String: Any] else {
            warnings.append(
                ParseWarning(
                    sourcePath: sourcePath,
                    lineNumber: lineNumber,
                    message: "assistant/message record missing usage"
                )
            )
            return
        }

        let input = intValue(usage["inputTokens"])
        let output = intValue(usage["outputTokens"])
        let cacheRead = intValue(usage["cacheReadTokens"])
        let cacheCreation = intValue(usage["cacheWriteTokens"])
        let reasoning = intValue(usage["reasoningTokens"])
        guard input + output + cacheRead + cacheCreation + reasoning > 0 else {
            // Degenerate stream mirror rows (e.g. aborted attempts) carry all
            // zeros; counting them would inflate every total.
            return
        }

        let model = (payload["message"] as? [String: Any])?["source"] as? [String: Any]
        let modelName = (model?["model"] as? String) ?? (model?["provider"] as? String)

        let resolvedProject = resolvedProjectPath(projectPath, fileURL: fileURL)
        let recordID = seq > 0
            ? String(seq)
            : "line-" + String(lineNumber)

        events.append(
            UsageEvent(
                id: sourcePath + "#dsh#" + sessionID + "#" + recordID,
                agent: .dsh,
                projectPath: resolvedProject.path,
                projectName: resolvedProject.name,
                sessionId: sessionID,
                timestamp: timestamp,
                inputTokens: max(input, 0),
                outputTokens: max(output, 0),
                cacheReadTokens: max(cacheRead, 0),
                cacheCreationTokens: max(cacheCreation, 0),
                reasoningTokens: reasoning > 0 ? reasoning : nil,
                modelName: modelName,
                sourcePath: sourcePath,
                parser: .dsh,
                confidence: 1.0,
                generationStartMs: generationStartMs,
                generationEndMs: generationEndMs
            )
        )
    }

    private static func appendPromptRecord(
        payload: [String: Any],
        seq: Int,
        timestamp: Date,
        sourcePath: String,
        sessionID: String,
        projectPath: String?,
        fileURL: URL,
        lineNumber: Int,
        prompts: inout [PromptRecord]
    ) {
        let source = payload["source"] as? [String: Any]
        guard (source?["kind"] as? String) == "user" else {
            // Injected context (agent-instructions, skill-catalog,
            // runtime-context, model-selection, ...) is not a human prompt.
            return
        }

        let content = PromptExtraction.strings(fromContent: payload["content"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !PromptExtraction.isSystemReminder($0) }
            .joined(separator: "\n\n")
        guard !content.isEmpty else {
            return
        }

        let resolvedProject = resolvedProjectPath(projectPath, fileURL: fileURL)
        let contentHash = PromptExtraction.hash(content)
        let recordID = seq > 0
            ? String(seq)
            : "line-" + String(lineNumber)

        prompts.append(
            PromptRecord(
                id: sourcePath + "#dsh#prompt#" + sessionID + "#" + recordID + "#" + contentHash,
                eventId: nil,
                agent: .dsh,
                projectName: resolvedProject.name,
                sessionId: sessionID,
                timestamp: timestamp,
                content: content,
                contentHash: contentHash,
                sourcePath: sourcePath
            )
        )
    }

    private static func resolvedProjectPath(_ projectPath: String?, fileURL: URL) -> (path: String?, name: String) {
        if let projectPath, !projectPath.isEmpty {
            let name = URL(fileURLWithPath: projectPath).lastPathComponent
            if !name.isEmpty {
                return (projectPath, name)
            }
        }
        // sessions/<project-slug>/session-<id>/file.zstd
        let slug = fileURL.deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        return (nil, slug.isEmpty ? "dsh" : slug)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }

    private static func resolveTimestamp(_ object: [String: Any]) -> Date? {
        if let n = object["time"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        return nil
    }
}
