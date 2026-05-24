import Foundation

public typealias ClaudeParseWarning = ParseWarning
public typealias ClaudeParseResult = ParseResult

private typealias ClaudeParserThrottle = JSONLThrottleTunables

public enum ClaudeUsageParser {
    public static func parse(fileURL: URL, fallbackProjectSlug: String) throws -> ClaudeParseResult {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).enumerated().map {
            JSONLLineRecord(
                text: String($0.element),
                lineNumber: $0.offset + 1,
                startOffset: 0,
                endOffset: 0
            )
        }
        return parse(lines: lines, fileURL: fileURL, fallbackProjectSlug: fallbackProjectSlug)
    }

    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL,
        fallbackProjectSlug: String
    ) -> ClaudeParseResult {
        let sourcePath = fileURL.path

        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var warnings: [ClaudeParseWarning] = []

        for line in lines {
            let lineNumber = line.lineNumber
            let lineText = line.text

            guard let data = lineText.data(using: .utf8) else {
                warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "line is not valid UTF-8"))
                continue
            }

            let object: [String: Any]
            do {
                object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch {
                warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "malformed JSON"))
                continue
            }

            if let prompt = extractUserPrompt(
                object: object,
                sourcePath: sourcePath,
                lineNumber: lineNumber,
                fileURL: fileURL,
                fallbackProjectSlug: fallbackProjectSlug
            ) {
                prompts.append(prompt)
                continue
            }

            guard let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            guard let rawInput = usage["input_tokens"] as? Int,
                  let rawOutput = usage["output_tokens"] as? Int,
                  let rawCacheCreation = usage["cache_creation_input_tokens"] as? Int,
                  let rawCacheRead = usage["cache_read_input_tokens"] as? Int else {
                warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "usage fields are incomplete"))
                continue
            }
            // CL-P0-029: clamp negative token counts to 0 and warn once per line so the
            // downstream aggregator never sees negatives (which would otherwise corrupt
            // totals, focus shares, and KPI deltas).
            let inputClamp = TokenBarNumberFormatting.clampNonNegative(rawInput)
            let outputClamp = TokenBarNumberFormatting.clampNonNegative(rawOutput)
            let cacheCreationClamp = TokenBarNumberFormatting.clampNonNegative(rawCacheCreation)
            let cacheReadClamp = TokenBarNumberFormatting.clampNonNegative(rawCacheRead)
            if inputClamp.wasNegative || outputClamp.wasNegative || cacheCreationClamp.wasNegative || cacheReadClamp.wasNegative {
                warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "negative token count clamped to 0"))
            }
            let inputTokens = inputClamp.value
            let outputTokens = outputClamp.value
            let cacheCreationTokens = cacheCreationClamp.value
            let cacheReadTokens = cacheReadClamp.value
            let modelName = message["model"] as? String

            let project = projectIdentity(
                cwd: object["cwd"] as? String,
                fallbackProjectSlug: fallbackProjectSlug,
                sourcePath: sourcePath
            )

            events.append(
                UsageEvent(
                    id: "\(sourcePath)#\(lineNumber)",
                    agent: .claudeCode,
                    projectPath: project.path,
                    projectName: project.name,
                    sessionId: object["sessionId"] as? String ?? fileURL.deletingPathExtension().lastPathComponent,
                    timestamp: parseTimestamp(object["timestamp"] as? String) ?? .distantPast,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheTokens: cacheCreationTokens + cacheReadTokens,
                    reasoningTokens: 0,
                    modelName: modelName,
                    sourcePath: sourcePath,
                    parser: .claudeCode,
                    confidence: 1.0
                )
            )
        }

        return ClaudeParseResult(events: events, prompts: prompts, warnings: warnings)
    }

    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL,
        fallbackProjectSlug: String,
        resourceThrottle: IndexingResourceThrottle?
    ) async -> ClaudeParseResult {
        let sourcePath = fileURL.path

        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var warnings: [ClaudeParseWarning] = []
        var sliceStartedAt = Date()
        var linesSinceThrottle = 0

        for line in lines {
            let lineNumber = line.lineNumber
            let lineText = line.text

            guard let data = lineText.data(using: .utf8) else {
                warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "line is not valid UTF-8"))
                continue
            }

            let object: [String: Any]
            do {
                object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch {
                warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "malformed JSON"))
                continue
            }

            if let prompt = extractUserPrompt(
                object: object,
                sourcePath: sourcePath,
                lineNumber: lineNumber,
                fileURL: fileURL,
                fallbackProjectSlug: fallbackProjectSlug
            ) {
                prompts.append(prompt)
            } else if let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] {
                guard let rawInput = usage["input_tokens"] as? Int,
                      let rawOutput = usage["output_tokens"] as? Int,
                      let rawCacheCreation = usage["cache_creation_input_tokens"] as? Int,
                      let rawCacheRead = usage["cache_read_input_tokens"] as? Int else {
                    warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "usage fields are incomplete"))
                    continue
                }
                let inputClamp = TokenBarNumberFormatting.clampNonNegative(rawInput)
                let outputClamp = TokenBarNumberFormatting.clampNonNegative(rawOutput)
                let cacheCreationClamp = TokenBarNumberFormatting.clampNonNegative(rawCacheCreation)
                let cacheReadClamp = TokenBarNumberFormatting.clampNonNegative(rawCacheRead)
                if inputClamp.wasNegative || outputClamp.wasNegative || cacheCreationClamp.wasNegative || cacheReadClamp.wasNegative {
                    warnings.append(ClaudeParseWarning(sourcePath: sourcePath, lineNumber: lineNumber, message: "negative token count clamped to 0"))
                }
                let modelName = message["model"] as? String
                let project = projectIdentity(
                    cwd: object["cwd"] as? String,
                    fallbackProjectSlug: fallbackProjectSlug,
                    sourcePath: sourcePath
                )

                events.append(
                    UsageEvent(
                        id: "\(sourcePath)#\(lineNumber)",
                        agent: .claudeCode,
                        projectPath: project.path,
                        projectName: project.name,
                        sessionId: object["sessionId"] as? String ?? fileURL.deletingPathExtension().lastPathComponent,
                        timestamp: parseTimestamp(object["timestamp"] as? String) ?? .distantPast,
                        inputTokens: inputClamp.value,
                        outputTokens: outputClamp.value,
                        cacheTokens: cacheCreationClamp.value + cacheReadClamp.value,
                        reasoningTokens: 0,
                        modelName: modelName,
                        sourcePath: sourcePath,
                        parser: .claudeCode,
                        confidence: 1.0
                    )
                )
            }

            linesSinceThrottle += 1
            if let resourceThrottle, linesSinceThrottle >= ClaudeParserThrottle.parserLineInterval {
                let active = Date().timeIntervalSince(sliceStartedAt)
                if active >= ClaudeParserThrottle.activeSliceSeconds {
                    await resourceThrottle.rest(afterActive: active)
                    sliceStartedAt = Date()
                }
                linesSinceThrottle = 0
            }
        }

        if let resourceThrottle {
            await resourceThrottle.rest(afterActive: Date().timeIntervalSince(sliceStartedAt))
        }

        return ClaudeParseResult(events: events, prompts: prompts, warnings: warnings)
    }

    public static func extractUserPrompts(fileURL: URL, fallbackProjectSlug: String) throws -> [PromptRecord] {
        try parse(fileURL: fileURL, fallbackProjectSlug: fallbackProjectSlug).prompts
    }

    private static func extractUserPrompt(
        object: [String: Any],
        sourcePath: String,
        lineNumber: Int,
        fileURL: URL,
        fallbackProjectSlug: String
    ) -> PromptRecord? {
        guard let type = object["type"] as? String, type == "user" else {
            return nil
        }
        guard let message = object["message"] as? [String: Any],
              let role = message["role"] as? String,
              role == "user" else {
            return nil
        }

        let content = PromptExtraction.strings(fromContent: message["content"])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !PromptExtraction.isSystemReminder($0) }
            .joined(separator: "\n\n")

        guard !content.isEmpty else {
            return nil
        }

        let project = projectIdentity(
            cwd: object["cwd"] as? String,
            fallbackProjectSlug: fallbackProjectSlug,
            sourcePath: sourcePath
        )
        let timestamp = parseTimestamp(object["timestamp"] as? String) ?? .distantPast
        let contentHash = PromptExtraction.hash(content)

        return PromptRecord(
            id: "\(sourcePath)#prompt#\(lineNumber)#\(contentHash)",
            eventId: nil,
            agent: .claudeCode,
            projectName: project.name,
            sessionId: object["sessionId"] as? String ?? fileURL.deletingPathExtension().lastPathComponent,
            timestamp: timestamp,
            content: content,
            contentHash: contentHash,
            sourcePath: sourcePath
        )
    }

    private static func projectIdentity(
        cwd: String?,
        fallbackProjectSlug: String,
        sourcePath: String
    ) -> (path: String?, name: String) {
        let fallbackName = ClaudeDataSource.readableProjectName(fromSlug: fallbackProjectSlug)
        let isSubagentFile = URL(fileURLWithPath: sourcePath).pathComponents.contains("subagents")

        if let cwd,
           let parentPath = generatedAgentWorktreeParentPath(cwd) {
            return (parentPath, fallbackName)
        }

        guard isSubagentFile else {
            let name = cwd
                .map { URL(fileURLWithPath: $0).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? fallbackName
            return (cwd, name)
        }

        let usablePath = cwd.flatMap { path -> String? in
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard name == fallbackName else {
                return nil
            }
            return path
        }
        return (usablePath, fallbackName)
    }

    private static func generatedAgentWorktreeParentPath(_ cwd: String) -> String? {
        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        let components = url.pathComponents
        guard let claudeIndex = components.lastIndex(of: ".claude"),
              components.indices.contains(claudeIndex + 2),
              components[claudeIndex + 1] == "worktrees",
              components[claudeIndex + 2].hasPrefix("agent-") else {
            return nil
        }
        let parentComponents = components[..<claudeIndex]
        guard !parentComponents.isEmpty else {
            return nil
        }
        return NSString.path(withComponents: Array(parentComponents))
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
