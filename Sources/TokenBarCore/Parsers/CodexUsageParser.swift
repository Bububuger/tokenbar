import Foundation

public typealias CodexParseWarning = ParseWarning
public typealias CodexParseResult = ParseResult

private typealias CodexParserThrottle = JSONLThrottleTunables

private final class LockedISO8601TimestampParser: @unchecked Sendable {
    private let lock = NSLock()
    private let fractionalFormatter: ISO8601DateFormatter
    private let plainFormatter: ISO8601DateFormatter

    init() {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalFormatter = fractionalFormatter

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        self.plainFormatter = plainFormatter
    }

    func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
}

public enum CodexUsageParser {
    private static let timestampParser = LockedISO8601TimestampParser()

    /// Dedup signature for back-to-back `token_count` events that carry
    /// identical `last_token_usage` payloads. Codex's `event_msg` stream
    /// emits the same payload twice (initial + render-complete) ~7 lines
    /// apart, so summing the deltas across raw events double-counts every
    /// turn — observed as a 1.16-1.19× over-count for input tokens on
    /// real rollouts. Skipping the duplicate emission keeps the per-turn
    /// time distribution while restoring the ground-truth totals.
    fileprivate struct UsageDedupKey: Equatable {
        let input: Int
        let cache: Int
        let output: Int
        let reasoning: Int?
    }

    public static func parse(fileURL: URL) throws -> CodexParseResult {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).enumerated().map {
            JSONLLineRecord(
                text: String($0.element),
                lineNumber: $0.offset + 1,
                startOffset: 0,
                endOffset: 0
            )
        }
        return parse(lines: lines, fileURL: fileURL)
    }

    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL,
        initialSessionID: String? = nil,
        initialProjectPath: String? = nil
    ) -> CodexParseResult {
        let sourcePath = fileURL.path

        var sessionID: String? = initialSessionID
        var projectPath: String? = initialProjectPath
        var modelName: String?
        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var warnings: [CodexParseWarning] = []
        var lastEmittedUsage: UsageDedupKey?

        for line in lines {
            let lineNumber = line.lineNumber
            let lineText = line.text

            guard let data = lineText.data(using: .utf8) else {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "line is not valid UTF-8"))
                continue
            }

            let object: [String: Any]
            do {
                object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "malformed JSON"))
                continue
            }

            if let type = object["type"] as? String, type == "session_meta" {
                let payload = object["payload"] as? [String: Any]
                sessionID = payload?["id"] as? String ?? sessionID
                projectPath = payload?["cwd"] as? String ?? projectPath
                modelName = payload?["model"] as? String ?? modelName
                continue
            }

            if let type = object["type"] as? String, type == "turn_context" {
                let payload = object["payload"] as? [String: Any]
                modelName = payload?["model"] as? String ?? modelName
                continue
            }

            if let prompt = extractUserPrompt(
                object: object,
                sourcePath: sourcePath,
                lineNumber: lineNumber,
                fileURL: fileURL,
                sessionID: sessionID,
                projectPath: projectPath
            ) {
                prompts.append(prompt)
                continue
            }

            guard let type = object["type"] as? String, type == "event_msg" else {
                continue
            }

            guard let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count" else {
                continue
            }

            guard let info = payload["info"] as? [String: Any] else {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count record missing info"))
                continue
            }

            let usage = (info["last_token_usage"] as? [String: Any]) ?? (info["total_token_usage"] as? [String: Any])
            guard let usage else {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count record missing usage"))
                continue
            }

            guard let rawInput = usage["input_tokens"] as? Int,
                  let rawCache = usage["cached_input_tokens"] as? Int,
                  let rawOutput = usage["output_tokens"] as? Int else {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count usage fields are incomplete"))
                continue
            }
            // CL-P0-029: defensive clamp matches ClaudeUsageParser.
            let inputClamp = TokenBarNumberFormatting.clampNonNegative(rawInput)
            let outputClamp = TokenBarNumberFormatting.clampNonNegative(rawOutput)
            let cacheClamp = TokenBarNumberFormatting.clampNonNegative(rawCache)
            if inputClamp.wasNegative || outputClamp.wasNegative || cacheClamp.wasNegative {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "negative token count clamped to 0"))
            }
            let inputTokens = inputClamp.value
            let outputTokens = outputClamp.value
            let cacheTokens = cacheClamp.value
            let reasoningTokens = usage["reasoning_output_tokens"] as? Int

            // Codex emits the same `last_token_usage` twice within ~7 lines
            // (initial + render-complete). Skip exact-match repeats to avoid
            // the 1.16-1.19× over-count observed on real rollouts.
            let dedupKey = UsageDedupKey(
                input: inputTokens, cache: cacheTokens,
                output: outputTokens, reasoning: reasoningTokens
            )
            if let prior = lastEmittedUsage, prior == dedupKey {
                continue
            }
            lastEmittedUsage = dedupKey

            let timestamp = parseTimestamp(object["timestamp"] as? String) ?? .distantPast
            let normalizedProjectPath = projectPath
            let normalizedProjectName = normalizedProjectPath
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "unknown"

            events.append(
                UsageEvent(
                    id: "\(sourcePath)#\(lineNumber)",
                    agent: .codex,
                    projectPath: normalizedProjectPath,
                    projectName: normalizedProjectName,
                    sessionId: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                    timestamp: timestamp,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheTokens,
                    cacheCreationTokens: 0,
                    reasoningTokens: reasoningTokens,
                    modelName: modelName,
                    sourcePath: sourcePath,
                    parser: .codex,
                    confidence: 1.0
                )
            )
        }

        return CodexParseResult(events: events, prompts: prompts, warnings: warnings)
    }

    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL,
        initialSessionID: String? = nil,
        initialProjectPath: String? = nil,
        resourceThrottle: IndexingResourceThrottle?
    ) async -> CodexParseResult {
        let sourcePath = fileURL.path

        var sessionID: String? = initialSessionID
        var projectPath: String? = initialProjectPath
        var modelName: String?
        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var warnings: [CodexParseWarning] = []
        var lastEmittedUsage: UsageDedupKey?
        var sliceStartedAt = Date()
        var linesSinceThrottle = 0

        for line in lines {
            let lineNumber = line.lineNumber
            let lineText = line.text

            guard let data = lineText.data(using: .utf8) else {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "line is not valid UTF-8"))
                continue
            }

            let object: [String: Any]
            do {
                object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "malformed JSON"))
                continue
            }

            if let type = object["type"] as? String, type == "session_meta" {
                let payload = object["payload"] as? [String: Any]
                sessionID = payload?["id"] as? String ?? sessionID
                projectPath = payload?["cwd"] as? String ?? projectPath
                modelName = payload?["model"] as? String ?? modelName
            } else if let type = object["type"] as? String, type == "turn_context" {
                let payload = object["payload"] as? [String: Any]
                modelName = payload?["model"] as? String ?? modelName
            } else if let prompt = extractUserPrompt(
                object: object,
                sourcePath: sourcePath,
                lineNumber: lineNumber,
                fileURL: fileURL,
                sessionID: sessionID,
                projectPath: projectPath
            ) {
                prompts.append(prompt)
            } else if let type = object["type"] as? String, type == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String,
                      payloadType == "token_count" {
                guard let info = payload["info"] as? [String: Any] else {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count record missing info"))
                    continue
                }

                let usage = (info["last_token_usage"] as? [String: Any]) ?? (info["total_token_usage"] as? [String: Any])
                guard let usage else {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count record missing usage"))
                    continue
                }

                guard let rawInput = usage["input_tokens"] as? Int,
                      let rawCache = usage["cached_input_tokens"] as? Int,
                      let rawOutput = usage["output_tokens"] as? Int else {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count usage fields are incomplete"))
                    continue
                }
                let inputClamp = TokenBarNumberFormatting.clampNonNegative(rawInput)
                let outputClamp = TokenBarNumberFormatting.clampNonNegative(rawOutput)
                let cacheClamp = TokenBarNumberFormatting.clampNonNegative(rawCache)
                if inputClamp.wasNegative || outputClamp.wasNegative || cacheClamp.wasNegative {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "negative token count clamped to 0"))
                }
                let reasoningTokens = usage["reasoning_output_tokens"] as? Int

                // Dedup back-to-back identical token_count emissions
                // (Codex emits the same `last_token_usage` twice). See
                // `UsageDedupKey` docs.
                let dedupKey = UsageDedupKey(
                    input: inputClamp.value, cache: cacheClamp.value,
                    output: outputClamp.value, reasoning: reasoningTokens
                )
                if let prior = lastEmittedUsage, prior == dedupKey {
                    // skip duplicate; still counts as a throttle line below
                } else {
                    lastEmittedUsage = dedupKey
                    let timestamp = parseTimestamp(object["timestamp"] as? String) ?? .distantPast
                    let normalizedProjectPath = projectPath
                    let normalizedProjectName = normalizedProjectPath
                        .map { URL(fileURLWithPath: $0).lastPathComponent }
                        .flatMap { $0.isEmpty ? nil : $0 }
                        ?? "unknown"

                    events.append(
                        UsageEvent(
                            id: "\(sourcePath)#\(lineNumber)",
                            agent: .codex,
                            projectPath: normalizedProjectPath,
                            projectName: normalizedProjectName,
                            sessionId: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                            timestamp: timestamp,
                            inputTokens: inputClamp.value,
                            outputTokens: outputClamp.value,
                            cacheReadTokens: cacheClamp.value,
                            cacheCreationTokens: 0,
                            reasoningTokens: reasoningTokens,
                            modelName: modelName,
                            sourcePath: sourcePath,
                            parser: .codex,
                            confidence: 1.0
                        )
                    )
                }
            }

            linesSinceThrottle += 1
            if let resourceThrottle, linesSinceThrottle >= CodexParserThrottle.parserLineInterval {
                let active = Date().timeIntervalSince(sliceStartedAt)
                if active >= CodexParserThrottle.activeSliceSeconds {
                    await resourceThrottle.rest(afterActive: active)
                    sliceStartedAt = Date()
                }
                linesSinceThrottle = 0
            }
        }

        if let resourceThrottle {
            await resourceThrottle.rest(afterActive: Date().timeIntervalSince(sliceStartedAt))
        }

        return CodexParseResult(events: events, prompts: prompts, warnings: warnings)
    }

    public static func sessionContext(fileURL: URL) -> (sessionID: String?, projectPath: String?) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return (nil, nil)
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8) else {
            return (nil, nil)
        }
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: false).prefix(40) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "session_meta" else {
                continue
            }
            let payload = object["payload"] as? [String: Any]
            return (payload?["id"] as? String, payload?["cwd"] as? String)
        }
        return (nil, nil)
    }

    public static func extractUserPrompts(fileURL: URL) throws -> [PromptRecord] {
        try parse(fileURL: fileURL).prompts
    }

    private static func extractUserPrompt(
        object: [String: Any],
        sourcePath: String,
        lineNumber: Int,
        fileURL: URL,
        sessionID: String?,
        projectPath: String?
    ) -> PromptRecord? {
        guard let type = object["type"] as? String, type == "response_item" else {
            return nil
        }
        guard let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "message",
              let role = payload["role"] as? String,
              role == "user" else {
            return nil
        }

        let content = PromptExtraction.strings(fromContent: payload["content"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !PromptExtraction.isSystemReminder($0) }
            .joined(separator: "\n\n")

        guard !content.isEmpty else {
            return nil
        }

        let normalizedProjectName = projectPath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "unknown"
        let timestamp = parseTimestamp(object["timestamp"] as? String) ?? .distantPast
        let contentHash = PromptExtraction.hash(content)

        return PromptRecord(
            id: "\(sourcePath)#prompt#\(lineNumber)#\(contentHash)",
            eventId: nil,
            agent: .codex,
            projectName: normalizedProjectName,
            sessionId: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
            timestamp: timestamp,
            content: content,
            contentHash: contentHash,
            sourcePath: sourcePath
        )
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        timestampParser.parse(value)
    }
}
