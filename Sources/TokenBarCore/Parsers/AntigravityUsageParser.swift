import Foundation

/// Parses Antigravity sessions at `~/.gemini/antigravity/**/*.jsonl`
/// (and `~/Library/Application Support/Antigravity/**`).
///
/// JSONL; one assistant turn per line. Canonical fields with aliases:
/// `input_tokens|inputTokens|promptTokens`, `output_tokens|outputTokens|completionTokens`,
/// `cache_read_tokens|cacheReadTokens`, `cache_write_tokens|cacheWriteTokens|cacheCreationTokens`.
/// `inputIncludesCached == false`.
///
/// Implemented as a NATIVE parser (not declarative) so usage is attributed to
/// `AgentKind.antigravity` rather than the generic `.custom` agent —
/// see CONTRACT.md§AgentKind.
public enum AntigravityUsageParser {
    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL
    ) -> ParseResult {
        let sourcePath = fileURL.path
        var events: [UsageEvent] = []
        let sessionID = resolveSessionID(fileURL: fileURL)

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            let usage = (object["usage"] as? [String: Any]) ?? object

            let input = intValue(usage, "input_tokens", "inputTokens", "promptTokens")
            let output = intValue(usage, "output_tokens", "outputTokens", "completionTokens")
            let cacheRead = intValue(usage, "cache_read_tokens", "cacheReadTokens")
            let cacheCreation = intValue(usage, "cache_write_tokens", "cacheWriteTokens", "cacheCreationTokens")
            guard input + output + cacheRead + cacheCreation > 0 else { continue }

            let messageID = (object["id"] as? String)
                ?? (object["message_id"] as? String)
                ?? "line-\(line.lineNumber)"
            let model = stringValue(object, "model", "model_id", "modelId")
                ?? stringValue(usage, "model", "model_id", "modelId")
            let timestamp = resolveTimestamp(object) ?? .distantPast
            let projectPath = (object["cwd"] as? String) ?? (object["workspace"] as? String)

            events.append(
                UsageEvent(
                    id: "\(sourcePath)#antigravity#\(messageID)",
                    agent: .antigravity,
                    projectPath: projectPath,
                    projectName: projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "antigravity",
                    sessionId: sessionID,
                    timestamp: timestamp,
                    inputTokens: max(input, 0),
                    outputTokens: max(output, 0),
                    cacheReadTokens: max(cacheRead, 0),
                    cacheCreationTokens: max(cacheCreation, 0),
                    reasoningTokens: nil,
                    modelName: model,
                    sourcePath: sourcePath,
                    parser: .antigravity,
                    confidence: 1.0
                )
            )
        }

        return ParseResult(events: events, warnings: [])
    }

    private static func resolveSessionID(fileURL: URL) -> String {
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : parent
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

    private static func resolveTimestamp(_ object: [String: Any]) -> Date? {
        if let n = object["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        if let iso = object["timestamp"] as? String {
            return iso8601WithFractional.date(from: iso) ?? iso8601NoFractional.date(from: iso)
        }
        return nil
    }

    nonisolated(unsafe) private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let iso8601NoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
