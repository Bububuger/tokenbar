import Foundation

public typealias OpenClawParseWarning = ParseWarning
public typealias OpenClawParseResult = ParseResult

/// Parses `~/.openclaw/agents/*/sessions/*.jsonl`. Session header (`type:
/// "session"`) carries the project `cwd` and session id; assistant messages
/// with `message.usage` carry the token counts (input / output / cacheRead /
/// cacheWrite + model + provider-supplied unix-ms timestamp).
public enum OpenClawUsageParser {
    public static func sessionContext(fileURL: URL) -> (sessionID: String?, projectPath: String?) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return (nil, nil)
        }
        for raw in text.split(whereSeparator: \.isNewline).prefix(8) {
            let trimmed = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (object["type"] as? String) == "session" else {
                continue
            }
            return (object["id"] as? String, object["cwd"] as? String)
        }
        return (nil, nil)
    }

    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL,
        initialSessionID: String? = nil,
        initialProjectPath: String? = nil
    ) -> OpenClawParseResult {
        let sourcePath = fileURL.path
        var sessionID = initialSessionID
        var projectPath = initialProjectPath
        var events: [UsageEvent] = []
        var warnings: [OpenClawParseWarning] = []

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }

            if type == "session" {
                if let id = object["id"] as? String { sessionID = id }
                if let cwd = object["cwd"] as? String { projectPath = cwd }
                continue
            }

            guard type == "message",
                  let messageDict = object["message"] as? [String: Any],
                  let usage = messageDict["usage"] as? [String: Any] else {
                continue
            }

            let input = intValue(usage["input"])
            let output = intValue(usage["output"])
            let cacheRead = intValue(usage["cacheRead"])
            let cacheWrite = intValue(usage["cacheWrite"])
            let cacheTotal = cacheRead + cacheWrite
            guard input + output + cacheTotal > 0 else { continue }

            guard let timestamp = resolveTimestamp(messageDict: messageDict, outer: object) else {
                warnings.append(OpenClawParseWarning(
                    sourcePath: sourcePath,
                    lineNumber: line.lineNumber,
                    message: "missing or unparseable timestamp"
                ))
                continue
            }

            let messageID = (object["id"] as? String) ?? "line-\(line.lineNumber)"
            let resolvedSession = sessionID ?? fileURL.deletingPathExtension().lastPathComponent
            let resolvedProjectName = projectPath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? "openclaw"
            let model = messageDict["model"] as? String

            events.append(UsageEvent(
                id: "\(sourcePath)#\(messageID)",
                agent: .openclaw,
                projectPath: projectPath,
                projectName: resolvedProjectName,
                sessionId: resolvedSession,
                timestamp: timestamp,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheWrite,
                reasoningTokens: 0,
                modelName: model,
                sourcePath: sourcePath,
                parser: .openclaw,
                confidence: 1.0
            ))
        }

        return OpenClawParseResult(events: events, warnings: warnings)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let n = raw as? Int { return n }
        return 0
    }

    private static func resolveTimestamp(messageDict: [String: Any], outer: [String: Any]) -> Date? {
        if let n = messageDict["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        if let outerIso = outer["timestamp"] as? String {
            return ISO8601Fast.parseUTC(outerIso) ?? iso8601WithFractional.date(from: outerIso) ?? iso8601NoFractional.date(from: outerIso)
        }
        return nil
    }

    // ISO8601DateFormatter.date(from:) is thread-safe on macOS 10.15+; share
    // read-only instances to avoid rebuilding ICU SimpleDateFormat per event.
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
