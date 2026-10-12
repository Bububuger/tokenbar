import Foundation

public typealias PiParseWarning = ParseWarning
public typealias PiParseResult = ParseResult

/// Parses pi coding-agent sessions at
/// `~/.pi/agent/sessions/--<encoded-cwd>--/<ts>_<id>.jsonl`. The first line is a
/// version-3 session header (`type: "session"`) carrying the project `cwd` and
/// session id; subsequent `type: "message"` lines whose `message.role` is
/// `assistant` carry `message.usage` (input / output / cacheRead / cacheWrite),
/// `message.model`, and a unix-ms `message.timestamp`.
///
/// omp (oh-my-pi) is a fork of pi and writes the same schema under
/// `~/.omp/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl`; the only usage-level
/// difference is the reasoning field name, captured by `Dialect`.
public enum PiUsageParser {
    /// Per-fork differences between pi and omp. Keeping them in one value means a
    /// third fork is a new constant rather than a new parser that can drift.
    public struct Dialect: Sendable {
        public let agent: AgentKind
        public let parser: ParserKind
        /// Usage field carrying reasoning tokens: pi uses `reasoning`, omp uses
        /// `reasoningTokens`.
        public let reasoningKey: String

        public init(agent: AgentKind, parser: ParserKind, reasoningKey: String) {
            self.agent = agent
            self.parser = parser
            self.reasoningKey = reasoningKey
        }

        public static let pi = Dialect(agent: .pi, parser: .pi, reasoningKey: "reasoning")
        public static let omp = Dialect(agent: .omp, parser: .omp, reasoningKey: "reasoningTokens")
    }
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
        initialProjectPath: String? = nil,
        dialect: Dialect = .pi
    ) -> PiParseResult {
        let sourcePath = fileURL.path
        var sessionID = initialSessionID
        var projectPath = initialProjectPath
        var events: [UsageEvent] = []
        var warnings: [PiParseWarning] = []

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
                  let messageDict = object["message"] as? [String: Any] else {
                continue
            }
            // Only assistant turns carry usage; user / toolResult messages don't.
            if let role = messageDict["role"] as? String, role != "assistant" {
                continue
            }
            // Skip aborted / errored turns — their usage is empty / unreliable
            // (mirrors pi's own getLastAssistantUsage gating).
            if let stop = messageDict["stopReason"] as? String, stop == "aborted" || stop == "error" {
                continue
            }
            guard let usage = messageDict["usage"] as? [String: Any] else { continue }

            let input = intValue(usage["input"])
            let output = intValue(usage["output"])
            let cacheRead = intValue(usage["cacheRead"])
            let cacheWrite = intValue(usage["cacheWrite"])
            let cacheTotal = cacheRead + cacheWrite
            guard input + output + cacheTotal > 0 else { continue }
            // Reasoning is reported separately from output by both forks and is
            // never part of totalTokens; surface it for the Details view only.
            let reasoning = intValue(usage[dialect.reasoningKey])

            guard let timestamp = resolveTimestamp(messageDict: messageDict, outer: object) else {
                warnings.append(PiParseWarning(
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
            } ?? dialect.agent.rawValue
            let model = messageDict["model"] as? String

            events.append(UsageEvent(
                id: "\(sourcePath)#\(messageID)",
                agent: dialect.agent,
                projectPath: projectPath,
                projectName: resolvedProjectName,
                sessionId: resolvedSession,
                timestamp: timestamp,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheWrite,
                reasoningTokens: reasoning,
                modelName: model,
                actualCostUSD: reportedCost(usage["cost"]),
                sourcePath: sourcePath,
                parser: dialect.parser,
                confidence: 1.0
            ))
        }

        return PiParseResult(events: events, warnings: warnings)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let n = raw as? Int { return n }
        return 0
    }

    private static func reportedCost(_ raw: Any?) -> Double? {
        let value = (raw as? [String: Any])?["total"] ?? raw
        guard let number = value as? NSNumber else { return nil }
        let cost = number.doubleValue
        return cost.isFinite && cost >= 0 ? cost : nil
    }

    private static func resolveTimestamp(messageDict: [String: Any], outer: [String: Any]) -> Date? {
        // pi carries a unix-ms timestamp on the message and/or the entry; ISO
        // strings are also accepted as a fallback.
        if let n = messageDict["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        if let n = outer["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue / 1000.0)
        }
        if let messageIso = messageDict["timestamp"] as? String {
            if let d = ISO8601Fast.parseUTC(messageIso) ?? iso8601WithFractional.date(from: messageIso) ?? iso8601NoFractional.date(from: messageIso) {
                return d
            }
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
