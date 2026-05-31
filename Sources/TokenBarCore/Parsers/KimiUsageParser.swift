import Foundation

/// Parses Kimi Code sessions at `~/.kimi/sessions/**/wire.jsonl`.
///
/// One JSONL line per assistant turn with FLAT usage fields:
/// `input_other` (input excluding cache), `output`, `input_cache_read`,
/// `input_cache_creation`. Mapping: `input = input_other`,
/// `cacheRead = input_cache_read`, `cacheCreation = input_cache_creation`.
/// `inputIncludesCached == false` — input is already cache-exclusive.
///
/// Implemented as a NATIVE parser (not declarative) so usage is attributed to
/// `AgentKind.kimi` rather than the generic `.custom` agent — see CONTRACT.md§AgentKind.
public enum KimiUsageParser {
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

            // Usage may be flat on the line or nested under "usage".
            let usage = (object["usage"] as? [String: Any]) ?? object

            let input = intValue(usage["input_other"])
            let output = intValue(usage["output"])
            let cacheRead = intValue(usage["input_cache_read"])
            let cacheCreation = intValue(usage["input_cache_creation"])
            guard input + output + cacheRead + cacheCreation > 0 else { continue }

            let messageID = (object["id"] as? String)
                ?? (object["message_id"] as? String)
                ?? "line-\(line.lineNumber)"
            let model = (object["model"] as? String) ?? (usage["model"] as? String)
            let timestamp = resolveTimestamp(object) ?? .distantPast

            events.append(
                UsageEvent(
                    id: "\(sourcePath)#kimi#\(messageID)",
                    agent: .kimi,
                    projectPath: object["cwd"] as? String,
                    projectName: (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "kimi",
                    sessionId: sessionID,
                    timestamp: timestamp,
                    inputTokens: max(input, 0),
                    outputTokens: max(output, 0),
                    cacheReadTokens: max(cacheRead, 0),
                    cacheCreationTokens: max(cacheCreation, 0),
                    reasoningTokens: nil,
                    modelName: model,
                    sourcePath: sourcePath,
                    parser: .kimi,
                    confidence: 1.0
                )
            )
        }

        return ParseResult(events: events, warnings: [])
    }

    /// `~/.kimi/sessions/<uuid>/wire.jsonl` → session id from the parent dir.
    private static func resolveSessionID(fileURL: URL) -> String {
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : parent
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let n = raw as? Int { return n }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
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
