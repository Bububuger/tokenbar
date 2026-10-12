import Foundation

/// Parses Devin CLI transcripts at
/// `~/.local/share/devin/cli/transcripts/*.json` (ATIF schema).
///
/// Each step with a `metrics` block is one model request:
/// `prompt_tokens` is the FULL prompt size and `cached_tokens` is the
/// cache-hit subset of it (OpenAI wire semantics — verified via the
/// `cached_{t+1} ≈ prompt_t` chain across 6371 steps and the 84/84
/// `sum(steps) == final_metrics` check, GROK-DEVIN-SUPPORT-PLAN.md §4.2).
/// Claude models also report cache writes in
/// `metrics.extra.cache_creation_input_tokens`, included in the prompt.
/// Fresh input excludes both cache reads and writes; output is
/// `completion_tokens`. Per-request cost stays nil (subscription).
///
/// Project attribution is resolved by the caller from the sibling
/// `sessions.db` (`sessions.working_directory`) and passed in as a
/// session_id → path map; transcripts carry no cwd of their own.
public enum DevinUsageParser {
    public static func parse(
        data: Data,
        fileURL: URL,
        projects: [String: String] = [:]
    ) -> ParseResult {
        let sourcePath = fileURL.path
        var warnings: [ParseWarning] = []

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ParseResult(
                events: [],
                prompts: [],
                warnings: [
                    ParseWarning(sourcePath: sourcePath, lineNumber: 0, message: "devin transcript malformed JSON")
                ]
            )
        }

        guard let schemaVersion = object["schema_version"] as? String,
              schemaVersion.hasPrefix("ATIF-v1") else {
            let version = (object["schema_version"] as? String) ?? "missing"
            return ParseResult(
                events: [],
                prompts: [],
                warnings: [
                    ParseWarning(
                        sourcePath: sourcePath,
                        lineNumber: 0,
                        message: "devin transcript schema not supported: \(version)"
                    )
                ]
            )
        }

        let sessionID = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fileURL.deletingPathExtension().lastPathComponent
        let agentModel = ((object["agent"] as? [String: Any])?["model_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let steps = (object["steps"] as? [[String: Any]]) ?? []

        let projectPath = projects[sessionID]
        let projectName = projectPath.flatMap { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? nil : name
        } ?? "unknown"

        var events: [UsageEvent] = []
        var promptTotal = 0
        var cachedTotal = 0
        var completionTotal = 0

        for (index, step) in steps.enumerated() {
            guard let metrics = step["metrics"] as? [String: Any],
                  let rawPrompt = metrics["prompt_tokens"] as? NSNumber else {
                continue
            }
            let prompt = rawPrompt.intValue
            let cached = (metrics["cached_tokens"] as? NSNumber)?.intValue ?? 0
            let extra = metrics["extra"] as? [String: Any]
            let cacheCreation = max((extra?["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0, 0)
            let completion = (metrics["completion_tokens"] as? NSNumber)?.intValue ?? 0
            promptTotal += prompt
            cachedTotal += cached
            completionTotal += completion

            let freshInput = max(prompt - cached - cacheCreation, 0)
            guard freshInput + completion + cached + cacheCreation > 0 else { continue }

            let stepID = (step["step_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "step-\(index)"
            let timestamp = resolveTimestamp(step) ?? .distantPast
            let model = (step["model_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? agentModel

            events.append(
                UsageEvent(
                    id: "\(sourcePath)#devin#\(stepID)",
                    agent: .devin,
                    projectPath: projectPath,
                    projectName: projectName,
                    sessionId: sessionID,
                    timestamp: timestamp,
                    inputTokens: freshInput,
                    outputTokens: completion,
                    cacheReadTokens: cached,
                    cacheCreationTokens: cacheCreation,
                    reasoningTokens: nil,
                    modelName: model,
                    actualCostUSD: nil,
                    sourcePath: sourcePath,
                    parser: .devin,
                    confidence: 1.0
                )
            )
        }

        if let finalMetrics = object["final_metrics"] as? [String: Any] {
            let expectedPrompt = (finalMetrics["total_prompt_tokens"] as? NSNumber)?.intValue
            let expectedCached = (finalMetrics["total_cached_tokens"] as? NSNumber)?.intValue
            let expectedCompletion = (finalMetrics["total_completion_tokens"] as? NSNumber)?.intValue
            if let expectedPrompt, expectedPrompt != promptTotal {
                warnings.append(
                    ParseWarning(
                        sourcePath: sourcePath,
                        lineNumber: 0,
                        message: "devin transcript final_metrics mismatch: prompt \(promptTotal) vs \(expectedPrompt)"
                    )
                )
            }
            if let expectedCached, expectedCached != cachedTotal {
                warnings.append(
                    ParseWarning(
                        sourcePath: sourcePath,
                        lineNumber: 0,
                        message: "devin transcript final_metrics mismatch: cached \(cachedTotal) vs \(expectedCached)"
                    )
                )
            }
            if let expectedCompletion, expectedCompletion != completionTotal {
                warnings.append(
                    ParseWarning(
                        sourcePath: sourcePath,
                        lineNumber: 0,
                        message: "devin transcript final_metrics mismatch: completion \(completionTotal) vs \(expectedCompletion)"
                    )
                )
            }
        }

        return ParseResult(events: events, prompts: [], warnings: warnings)
    }

    private static func resolveTimestamp(_ step: [String: Any]) -> Date? {
        guard let raw = step["timestamp"] as? String else { return nil }
        if let date = iso8601WithFractional.date(from: raw) {
            return date
        }
        if let date = iso8601NoFractional.date(from: raw) {
            return date
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
