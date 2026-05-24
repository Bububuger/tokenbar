import Foundation

public enum GeminiUsageParser {
    public struct ParseResult: Sendable, Hashable {
        public let events: [UsageEvent]
        public let lastEventId: String?
        public let warnings: [UsageSourceWarning]

        public init(events: [UsageEvent], lastEventId: String?, warnings: [UsageSourceWarning]) {
            self.events = events
            self.lastEventId = lastEventId
            self.warnings = warnings
        }
    }

    public static func parse(
        data: Data,
        fileURL: URL,
        projectResolver: (String) -> (projectName: String, projectPath: String?)
    ) -> ParseResult {
        let sourcePath = fileURL.path
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ParseResult(
                events: [],
                lastEventId: nil,
                warnings: [
                    UsageSourceWarning(
                        sourceName: "Gemini",
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "malformed JSON"
                    )
                ]
            )
        }

        guard let messages = object["messages"] as? [[String: Any]] else {
            return ParseResult(
                events: [],
                lastEventId: nil,
                warnings: [
                    UsageSourceWarning(
                        sourceName: "Gemini",
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "missing message list"
                    )
                ]
            )
        }

        let sessionId = object["sessionId"] as? String ?? fileURL.deletingPathExtension().lastPathComponent
        let resolvedProject = projectResolver(projectSlug(from: fileURL))
        var events: [UsageEvent] = []
        var warnings: [UsageSourceWarning] = []
        var lastEventId: String?

        for message in messages {
            guard let type = message["type"] as? String, type == "gemini" else {
                continue
            }

            guard let messageID = message["id"] as? String else {
                continue
            }
            guard let tokensObject = message["tokens"] as? [String: Any] else {
                warnings.append(
                    UsageSourceWarning(
                        sourceName: "Gemini",
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "gemini token_count record missing usage"
                    )
                )
                continue
            }

            guard let rawInput = intValue(from: tokensObject["input"]),
                  let rawOutput = intValue(from: tokensObject["output"]),
                  let rawCache = intValue(from: tokensObject["cached"]),
                  let rawThoughts = intValue(from: tokensObject["thoughts"]),
                  let rawTool = intValue(from: tokensObject["tool"]) else {
                warnings.append(
                    UsageSourceWarning(
                        sourceName: "Gemini",
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "gemini token_count usage fields are incomplete"
                    )
                )
                continue
            }

            let inputClamp = TokenBarNumberFormatting.clampNonNegative(rawInput)
            let outputClamp = TokenBarNumberFormatting.clampNonNegative(rawOutput)
            let cacheClamp = TokenBarNumberFormatting.clampNonNegative(rawCache)
            let thoughtsClamp = TokenBarNumberFormatting.clampNonNegative(rawThoughts)
            let toolClamp = TokenBarNumberFormatting.clampNonNegative(rawTool)
            if inputClamp.wasNegative || outputClamp.wasNegative || cacheClamp.wasNegative || thoughtsClamp.wasNegative || toolClamp.wasNegative {
                warnings.append(
                    UsageSourceWarning(
                        sourceName: "Gemini",
                        sourcePath: sourcePath,
                        lineNumber: nil,
                        message: "negative token count clamped to 0"
                    )
                )
            }

            let modelName = message["model"] as? String
            let timestamp = parseTimestamp(message["timestamp"] as? String) ?? .distantPast
            let event = UsageEvent(
                id: "\(sourcePath)#\(messageID)",
                agent: .geminiCLI,
                projectPath: resolvedProject.projectPath,
                projectName: resolvedProject.projectName,
                sessionId: sessionId,
                timestamp: timestamp,
                inputTokens: inputClamp.value,
                // Surface `thoughts` as reasoningTokens to match Codex /
                // OpenCode / Hermes convention. `tool` stays folded into
                // outputTokens (it's the model's tool-call payload size,
                // not a distinct reasoning dimension).
                outputTokens: outputClamp.value + toolClamp.value,
                cacheTokens: cacheClamp.value,
                reasoningTokens: thoughtsClamp.value,
                modelName: modelName,
                sourcePath: sourcePath,
                parser: .gemini,
                confidence: 1.0
            )
            events.append(event)
            lastEventId = messageID
        }

        return ParseResult(events: events, lastEventId: lastEventId, warnings: warnings)
    }

    private static func projectSlug(from fileURL: URL) -> String {
        let components = fileURL.pathComponents
        if let chatsIndex = components.lastIndex(of: "chats"), chatsIndex >= 1 {
            return components[chatsIndex - 1]
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let intValue as Int64:
            return Int(intValue)
        case let doubleValue as Double:
            return Int(doubleValue)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
