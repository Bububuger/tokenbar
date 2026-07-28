import Foundation

/// Parses current Kimi Code sessions at `~/.kimi-code/sessions/**/wire.jsonl`
/// and legacy sessions at `~/.kimi/sessions/**/wire.jsonl`.
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
        let stateProjectPath = resolveStateProjectPath(fileURL: fileURL)

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            if let type = object["type"] as? String {
                guard type == "usage.record",
                      object["usageScope"] as? String == "turn" else {
                    continue
                }
            }

            // Current usage is nested and camelCase; legacy usage may be
            // flat or nested and snake_case.
            let usage = (object["usage"] as? [String: Any]) ?? object

            let input = intValue(usage["inputOther"] ?? usage["input_other"])
            let output = intValue(usage["output"])
            let cacheRead = intValue(usage["inputCacheRead"] ?? usage["input_cache_read"])
            let cacheCreation = intValue(usage["inputCacheCreation"] ?? usage["input_cache_creation"])
            guard input + output + cacheRead + cacheCreation > 0 else { continue }

            let model = (object["model"] as? String) ?? (usage["model"] as? String)
            let timestamp = resolveTimestamp(object) ?? .distantPast
            let projectPath = stateProjectPath ?? (object["cwd"] as? String)
            let recordID = (object["id"] as? String)
                ?? (object["message_id"] as? String)
                ?? "line-\(line.lineNumber)"

            events.append(
                UsageEvent(
                    id: "\(sourcePath)#kimi#\(recordID)",
                    agent: .kimi,
                    projectPath: projectPath,
                    projectName: projectPath
                        .map { URL(fileURLWithPath: $0).lastPathComponent }
                        .flatMap { $0.isEmpty ? nil : $0 }
                        ?? "kimi",
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

    /// Current files live below `<sessionId>/agents/<agentId>/wire.jsonl`.
    /// Legacy files use `<sessionId>/wire.jsonl`.
    private static func resolveSessionID(fileURL: URL) -> String {
        var directory = fileURL.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.lastPathComponent.hasPrefix("session_") {
                return directory.lastPathComponent
            }
            directory.deleteLastPathComponent()
        }
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? fileURL.deletingPathExtension().lastPathComponent : parent
    }

    private static func resolveStateProjectPath(fileURL: URL) -> String? {
        var directory = fileURL.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.lastPathComponent.hasPrefix("session_") {
                let stateURL = directory.appendingPathComponent("state.json")
                guard let data = try? Data(contentsOf: stateURL),
                      let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return nil
                }
                return (state["workDir"] as? String)
                    ?? (state["custom"] as? [String: Any])?["cwd"] as? String
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let n = raw as? Int { return n }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }

    private static func resolveTimestamp(_ object: [String: Any]) -> Date? {
        if let n = object["time"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        if let n = object["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        if let iso = object["timestamp"] as? String {
            return ISO8601Fast.parseUTC(iso) ?? iso8601WithFractional.date(from: iso) ?? iso8601NoFractional.date(from: iso)
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
