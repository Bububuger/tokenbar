import Foundation

public typealias CodexParseWarning = ParseWarning
public typealias CodexParseResult = ParseResult

private typealias CodexParserThrottle = JSONLThrottleTunables

private final class LockedISO8601TimestampParser: @unchecked Sendable {
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
        // Fast hand-rolled UTC parse first (see ISO8601Fast); the ICU-backed
        // ISO8601DateFormatter dominated the parse hot path on large sources.
        if let date = ISO8601Fast.parseUTC(value) {
            return date
        }
        // ISO8601DateFormatter.date(from:) is thread-safe on macOS 10.15+; no
        // lock needed. The previous NSLock serialized every worker through one
        // critical section and dominated the bootstrap parse hot path.
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
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let reasoning: Int?
    }

    private struct RawUsage: Equatable {
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let reasoning: Int
        let total: Int?

        var hasNegativeComponent: Bool {
            input < 0
                || cacheRead < 0
                || cacheWrite < 0
                || output < 0
                || reasoning < 0
                || (total ?? 0) < 0
        }
    }

    private struct UsageDedupState {
        let usage: UsageDedupKey
        let cumulativeTotal: RawUsage?
        let lineNumber: Int
    }

    private struct NormalizedUsage {
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let reasoning: Int?

        var dedupKey: UsageDedupKey {
            UsageDedupKey(
                input: input,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: reasoning
            )
        }
    }

    public static func parse(
        fileURL: URL,
        canonicalActiveRootPath: String? = nil
    ) throws -> CodexParseResult {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).enumerated().map {
            JSONLLineRecord(
                text: String($0.element),
                lineNumber: $0.offset + 1,
                startOffset: 0,
                endOffset: 0
            )
        }
        return parse(
            lines: lines,
            fileURL: fileURL,
            canonicalActiveRootPath: canonicalActiveRootPath
        )
    }

    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL,
        initialSessionID: String? = nil,
        initialProjectPath: String? = nil,
        canonicalActiveRootPath: String? = nil
    ) -> CodexParseResult {
        let sourcePath = fileURL.path
        let identityPath = stableIdentityPath(
            for: fileURL,
            canonicalActiveRootPath: canonicalActiveRootPath
        )

        var sessionID: String? = initialSessionID
        var projectPath: String? = initialProjectPath
        var modelName: String?
        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var warnings: [CodexParseWarning] = []
        var lastEmittedUsage: UsageDedupState?
        var previousTotalUsage: RawUsage?

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
                lastEmittedUsage = nil
                previousTotalUsage = nil
                continue
            }

            if let type = object["type"] as? String, type == "turn_context" {
                let payload = object["payload"] as? [String: Any]
                modelName = payload?["model"] as? String ?? modelName
                lastEmittedUsage = nil
                continue
            }

            if let prompt = extractUserPrompt(
                object: object,
                sourcePath: sourcePath,
                identityPath: identityPath,
                lineNumber: lineNumber,
                fileURL: fileURL,
                sessionID: sessionID,
                projectPath: projectPath
            ) {
                prompts.append(prompt)
                lastEmittedUsage = nil
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

            let lastUsage = info["last_token_usage"] as? [String: Any]
            let totalUsage = info["total_token_usage"] as? [String: Any]
            guard lastUsage != nil || totalUsage != nil else {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count record missing usage"))
                continue
            }

            let parsed = normalizeUsage(
                lastUsage: lastUsage,
                totalUsage: totalUsage,
                previousTotalUsage: &previousTotalUsage
            )
            guard let normalized = parsed.usage else {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count usage fields are incomplete"))
                continue
            }
            if parsed.hadNegativeValue {
                warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "negative token count clamped to 0"))
            }
            guard !parsed.isSynthetic else { continue }

            // Codex emits the same `last_token_usage` twice within ~7 lines
            // (initial + render-complete). Skip exact-match repeats to avoid
            // the 1.16-1.19× over-count observed on real rollouts.
            let dedupKey = normalized.dedupKey
            if isDuplicate(
                usage: dedupKey,
                cumulativeTotal: parsed.cumulativeTotal,
                lineNumber: lineNumber,
                prior: lastEmittedUsage
            ) {
                continue
            }
            lastEmittedUsage = UsageDedupState(
                usage: dedupKey,
                cumulativeTotal: parsed.cumulativeTotal,
                lineNumber: lineNumber
            )

            let timestamp = parseTimestamp(object["timestamp"] as? String) ?? .distantPast
            let normalizedProjectPath = projectPath
            let normalizedProjectName = normalizedProjectPath
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "unknown"

            events.append(
                UsageEvent(
                    id: "\(identityPath)#\(lineNumber)",
                    agent: .codex,
                    projectPath: normalizedProjectPath,
                    projectName: normalizedProjectName,
                    sessionId: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                    timestamp: timestamp,
                    inputTokens: normalized.input,
                    outputTokens: normalized.output,
                    cacheReadTokens: normalized.cacheRead,
                    cacheCreationTokens: normalized.cacheWrite,
                    reasoningTokens: normalized.reasoning,
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
        canonicalActiveRootPath: String? = nil,
        resourceThrottle: IndexingResourceThrottle?
    ) async -> CodexParseResult {
        let sourcePath = fileURL.path
        let identityPath = stableIdentityPath(
            for: fileURL,
            canonicalActiveRootPath: canonicalActiveRootPath
        )

        var sessionID: String? = initialSessionID
        var projectPath: String? = initialProjectPath
        var modelName: String?
        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var warnings: [CodexParseWarning] = []
        var lastEmittedUsage: UsageDedupState?
        var previousTotalUsage: RawUsage?
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
                lastEmittedUsage = nil
                previousTotalUsage = nil
            } else if let type = object["type"] as? String, type == "turn_context" {
                let payload = object["payload"] as? [String: Any]
                modelName = payload?["model"] as? String ?? modelName
                lastEmittedUsage = nil
            } else if let prompt = extractUserPrompt(
                object: object,
                sourcePath: sourcePath,
                identityPath: identityPath,
                lineNumber: lineNumber,
                fileURL: fileURL,
                sessionID: sessionID,
                projectPath: projectPath
            ) {
                prompts.append(prompt)
                lastEmittedUsage = nil
            } else if let type = object["type"] as? String, type == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String,
                      payloadType == "token_count" {
                guard let info = payload["info"] as? [String: Any] else {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count record missing info"))
                    continue
                }

                let lastUsage = info["last_token_usage"] as? [String: Any]
                let totalUsage = info["total_token_usage"] as? [String: Any]
                guard lastUsage != nil || totalUsage != nil else {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count record missing usage"))
                    continue
                }

                let parsed = normalizeUsage(
                    lastUsage: lastUsage,
                    totalUsage: totalUsage,
                    previousTotalUsage: &previousTotalUsage
                )
                guard let normalized = parsed.usage else {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "token_count usage fields are incomplete"))
                    continue
                }
                if parsed.hadNegativeValue {
                    warnings.append(CodexParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "negative token count clamped to 0"))
                }
                guard !parsed.isSynthetic else { continue }

                // Dedup back-to-back identical token_count emissions
                // (Codex emits the same `last_token_usage` twice). See
                // `UsageDedupKey` docs.
                let dedupKey = normalized.dedupKey
                if isDuplicate(
                    usage: dedupKey,
                    cumulativeTotal: parsed.cumulativeTotal,
                    lineNumber: lineNumber,
                    prior: lastEmittedUsage
                ) {
                    // skip duplicate; still counts as a throttle line below
                } else {
                    lastEmittedUsage = UsageDedupState(
                        usage: dedupKey,
                        cumulativeTotal: parsed.cumulativeTotal,
                        lineNumber: lineNumber
                    )
                    let timestamp = parseTimestamp(object["timestamp"] as? String) ?? .distantPast
                    let normalizedProjectPath = projectPath
                    let normalizedProjectName = normalizedProjectPath
                        .map { URL(fileURLWithPath: $0).lastPathComponent }
                        .flatMap { $0.isEmpty ? nil : $0 }
                        ?? "unknown"

                    events.append(
                        UsageEvent(
                            id: "\(identityPath)#\(lineNumber)",
                            agent: .codex,
                            projectPath: normalizedProjectPath,
                            projectName: normalizedProjectName,
                            sessionId: sessionID ?? fileURL.deletingPathExtension().lastPathComponent,
                            timestamp: timestamp,
                            inputTokens: normalized.input,
                            outputTokens: normalized.output,
                            cacheReadTokens: normalized.cacheRead,
                            cacheCreationTokens: normalized.cacheWrite,
                            reasoningTokens: normalized.reasoning,
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

    private static func normalizeUsage(
        lastUsage: [String: Any]?,
        totalUsage: [String: Any]?,
        previousTotalUsage: inout RawUsage?
    ) -> (usage: NormalizedUsage?, cumulativeTotal: RawUsage?, hadNegativeValue: Bool, isSynthetic: Bool) {
        let parsedTotal = totalUsage.flatMap(parseRawUsage)
        defer {
            if let parsedTotal {
                previousTotalUsage = parsedTotal
            }
        }

        let raw: RawUsage
        if let lastUsage {
            guard let parsedLast = parseRawUsage(lastUsage) else {
                return (nil, parsedTotal, false, false)
            }
            raw = parsedLast
        } else if let parsedTotal {
            if let previous = previousTotalUsage, !didReset(current: parsedTotal, previous: previous) {
                raw = RawUsage(
                    input: max(parsedTotal.input - previous.input, 0),
                    cacheRead: max(parsedTotal.cacheRead - previous.cacheRead, 0),
                    cacheWrite: max(parsedTotal.cacheWrite - previous.cacheWrite, 0),
                    output: max(parsedTotal.output - previous.output, 0),
                    reasoning: max(parsedTotal.reasoning - previous.reasoning, 0),
                    total: parsedTotal.total.flatMap { current in
                        previous.total.map { max(current - $0, 0) }
                    }
                )
            } else {
                raw = parsedTotal
            }
        } else {
            return (nil, parsedTotal, false, false)
        }

        let inputClamp = TokenBarNumberFormatting.clampNonNegative(raw.input)
        let readClamp = TokenBarNumberFormatting.clampNonNegative(raw.cacheRead)
        let writeClamp = TokenBarNumberFormatting.clampNonNegative(raw.cacheWrite)
        let outputClamp = TokenBarNumberFormatting.clampNonNegative(raw.output)
        let reasoningClamp = TokenBarNumberFormatting.clampNonNegative(raw.reasoning)
        let hadNegativeValue = inputClamp.wasNegative
            || readClamp.wasNegative
            || writeClamp.wasNegative
            || outputClamp.wasNegative
            || reasoningClamp.wasNegative

        let rawInput = inputClamp.value
        // Codex reports cache read/write as input classifications. Constrain
        // malformed classifications to the reported input so normalization is
        // both mutually exclusive and safe from Int subtraction overflow.
        let cacheRead = min(readClamp.value, rawInput)
        let inputAfterRead = rawInput - cacheRead
        let cacheWrite = min(writeClamp.value, inputAfterRead)
        let rawOutput = outputClamp.value
        let reasoning = reasoningClamp.value
        let isSynthetic = rawInput == 0
            && cacheRead == 0
            && cacheWrite == 0
            && rawOutput == 0
            && (raw.total ?? 0) > 0
        let output = reportedTotalIncludesSeparateReasoning(
            total: raw.total,
            input: rawInput,
            output: rawOutput,
            reasoning: reasoning
        ) ? rawOutput + reasoning : rawOutput

        return (
            NormalizedUsage(
                input: inputAfterRead - cacheWrite,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                reasoning: reasoning,
            ),
            parsedTotal,
            hadNegativeValue,
            isSynthetic
        )
    }

    private static func isDuplicate(
        usage: UsageDedupKey,
        cumulativeTotal: RawUsage?,
        lineNumber: Int,
        prior: UsageDedupState?
    ) -> Bool {
        guard let prior, prior.usage == usage else { return false }
        if let cumulativeTotal, let priorTotal = prior.cumulativeTotal {
            return cumulativeTotal == priorTotal
        }
        guard cumulativeTotal == nil, prior.cumulativeTotal == nil else {
            return false
        }
        // Legacy records may omit total_token_usage. Limit the fallback
        // heuristic to the observed duplicate-render window so a later,
        // legitimately identical completion is not dropped.
        return lineNumber > prior.lineNumber && lineNumber - prior.lineNumber <= 12
    }

    private static func parseRawUsage(_ usage: [String: Any]) -> RawUsage? {
        guard let input = usage["input_tokens"] as? Int,
              let cacheRead = usage["cached_input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else {
            return nil
        }
        return RawUsage(
            input: input,
            cacheRead: cacheRead,
            cacheWrite: usage["cache_write_input_tokens"] as? Int ?? 0,
            output: output,
            reasoning: usage["reasoning_output_tokens"] as? Int ?? 0,
            total: usage["total_tokens"] as? Int
        )
    }

    private static func didReset(current: RawUsage, previous: RawUsage) -> Bool {
        // Subtracting a negative cumulative counter from a large positive
        // counter can overflow Int. A negative counter is malformed anyway,
        // so treat that boundary as a reset and let the normal clamp path
        // sanitize the current record.
        if current.hasNegativeComponent || previous.hasNegativeComponent {
            return true
        }
        if let currentTotal = current.total, let previousTotal = previous.total {
            return currentTotal < previousTotal
        }
        return current.input < previous.input
            || current.cacheRead < previous.cacheRead
            || current.cacheWrite < previous.cacheWrite
            || current.output < previous.output
            || current.reasoning < previous.reasoning
    }

    private static func reportedTotalIncludesSeparateReasoning(
        total: Int?,
        input: Int,
        output: Int,
        reasoning: Int
    ) -> Bool {
        guard reasoning > 0, let total else { return false }
        let (inputAndOutput, overflowed) = input.addingReportingOverflow(output)
        guard !overflowed else { return false }
        let (legacyTotal, reasoningOverflowed) = inputAndOutput.addingReportingOverflow(reasoning)
        return !reasoningOverflowed && total == legacyTotal
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
        identityPath: String,
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
            id: "\(identityPath)#prompt#\(lineNumber)#\(contentHash)",
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

    private static func stableIdentityPath(
        for fileURL: URL,
        canonicalActiveRootPath: String?
    ) -> String {
        let archiveURL = fileURL.deletingLastPathComponent()
        guard canonicalActiveRootPath != nil || archiveURL.lastPathComponent == "archived_sessions" else {
            return fileURL.path
        }

        let filename = fileURL.lastPathComponent
        let dateStart = filename.index(filename.startIndex, offsetBy: "rollout-".count, limitedBy: filename.endIndex)
        guard filename.hasPrefix("rollout-"),
              let dateStart,
              let dateEnd = filename.index(dateStart, offsetBy: 10, limitedBy: filename.endIndex) else {
            return fileURL.path
        }
        let parts = filename[dateStart..<dateEnd].split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return fileURL.path
        }

        let activeRootURL = canonicalActiveRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? archiveURL
            .deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)

        return activeRootURL
            .appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: true)
            .appendingPathComponent(String(parts[2]), isDirectory: true)
            .appendingPathComponent(filename)
            .path
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        timestampParser.parse(value)
    }
}
