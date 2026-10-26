import Foundation

/// Parses Grok CLI session usage from `~/.grok/sessions/*/*/updates.jsonl`.
///
/// Each `turn_completed` session-update line carries the turn's aggregate
/// billing ledger (`usage`): `inputTokens` is the FULL prompt size
/// (uncached + cache reads + cache writes — see grok's own
/// `TokenUsage` doc comment; do not double-subtract), `cachedReadTokens` /
/// `cacheCreationTokens` are the cache-hit / cache-write subsets of it, and
/// `costUsdTicks` is USD × 1e10. Per-model rows live under
/// `usage.modelUsage`; their sums equal the top-level ledger (verified
/// 20/20 sessions, GROK-DEVIN-SUPPORT-PLAN.md §4.1).
///
/// Mapping per (prompt_id, model): fresh input = `inputTokens −
/// cachedRead − cacheCreation` (clamped ≥ 0); output / cacheRead /
/// cacheCreation / reasoning pass through; `actualCostUSD = costUsdTicks /
/// 1e10` — only from a single-model `modelUsage` row or a per-row
/// `costUsdTicks`, never summed across rows (no double counting).
///
/// Project attribution prefers the sibling `summary.json`
/// (`source_workspace_dir` for worktree sessions, else `info.cwd`,
/// else `git_root_dir`) and falls back to the URL-decoded session
/// directory name, which is the percent-encoded cwd.
public enum GrokUsageParser {
    public static func parse(
        lines: [JSONLLineRecord],
        fileURL: URL
    ) -> ParseResult {
        let sourcePath = fileURL.path
        var events: [UsageEvent] = []
        var warnings: [ParseWarning] = []

        let sessionDirectory = fileURL.deletingLastPathComponent()
        let sessionID = sessionDirectory.lastPathComponent
        let sessionProject = resolveSessionProject(
            sessionDirectory: sessionDirectory,
            sourcePath: sourcePath,
            warnings: &warnings
        )

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            guard let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed" else {
                continue
            }

            guard let usage = update["usage"] as? [String: Any] else {
                warnings.append(
                    ParseWarning(
                        sourcePath: sourcePath,
                        lineNumber: line.lineNumber,
                        message: "grok turn_completed record missing usage"
                    )
                )
                continue
            }

            let promptID = (update["prompt_id"] as? String).flatMap { trim($0) } ?? "line-\(line.lineNumber)"

            let rowSessionID = (params["sessionId"] as? String).flatMap { trim($0) } ?? sessionID
            let timestamp = resolveTimestamp(object) ?? .distantPast
            let topLevelCost = doubleValue(usage["costUsdTicks"]).map { $0 / 1e10 }
            let modelUsage = usage["modelUsage"] as? [String: [String: Any]] ?? [:]

            // `elapsed_ms` on a turn_completed update is the wall-clock
            // dispatch → response-end duration (TTFT included); absent or
            // non-positive values report no timing rather than an estimate.
            let endMs = timestamp.tokenBarMillisecondsSince1970
            let elapsedMs = (update["elapsed_ms"] as? NSNumber)?.int64Value
            let generationStartMs: Int64? = {
                guard let elapsedMs, elapsedMs > 0, endMs > elapsedMs else { return nil }
                return endMs - elapsedMs
            }()

            if modelUsage.isEmpty {
                appendEvent(
                    into: &events,
                    sourcePath: sourcePath,
                    eventID: "\(sourcePath)#grok#\(promptID)",
                    sessionID: rowSessionID,
                    timestamp: timestamp,
                    usage: usage,
                    model: (usage["primaryModelId"] as? String).flatMap { trim($0) },
                    costUSD: topLevelCost,
                    project: sessionProject,
                    generationStartMs: generationStartMs,
                    generationEndMs: generationStartMs != nil ? endMs : nil
                )
                continue
            }

            for (model, row) in modelUsage.sorted(by: { $0.key < $1.key }) {
                let trimmedModel = trim(model)
                let cost = doubleValue(row["costUsdTicks"]).map { $0 / 1e10 }
                    ?? (modelUsage.count == 1 ? topLevelCost : nil)
                appendEvent(
                    into: &events,
                    sourcePath: sourcePath,
                    eventID: "\(sourcePath)#grok#\(promptID)#\(model)",
                    sessionID: rowSessionID,
                    timestamp: timestamp,
                    usage: row,
                    model: trimmedModel,
                    costUSD: cost,
                    project: sessionProject,
                    generationStartMs: generationStartMs,
                    generationEndMs: generationStartMs != nil ? endMs : nil
                )
            }
        }

        return ParseResult(events: events, prompts: [], warnings: warnings)
    }

    private static func appendEvent(
        into events: inout [UsageEvent],
        sourcePath: String,
        eventID: String,
        sessionID: String,
        timestamp: Date,
        usage: [String: Any],
        model: String?,
        costUSD: Double?,
        project: (projectName: String, projectPath: String?)?,
        generationStartMs: Int64?,
        generationEndMs: Int64?
    ) {
        let input = intValue(usage["inputTokens"])
        let output = intValue(usage["outputTokens"])
        let cacheRead = intValue(usage["cachedReadTokens"])
        let cacheCreation = intValue(usage["cacheCreationTokens"])
        let reasoning = intValue(usage["reasoningTokens"])
        guard input + output + cacheRead + cacheCreation > 0 else { return }

        // `inputTokens` includes both cache-hit and cache-write subsets.
        let freshInput = max(input - cacheRead - cacheCreation, 0)

        events.append(
            UsageEvent(
                id: eventID,
                agent: .grok,
                projectPath: project?.projectPath,
                projectName: project?.projectName ?? "unknown",
                sessionId: sessionID,
                timestamp: timestamp,
                inputTokens: freshInput,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation,
                reasoningTokens: reasoning,
                modelName: model,
                actualCostUSD: costUSD,
                sourcePath: sourcePath,
                parser: .grok,
                confidence: 1.0,
                generationStartMs: generationStartMs,
                generationEndMs: generationEndMs
            )
        )
    }

    /// `summary.json` sibling → URL-decoded session directory → nil.
    private static func resolveSessionProject(
        sessionDirectory: URL,
        sourcePath: String,
        warnings: inout [ParseWarning]
    ) -> (projectName: String, projectPath: String?)? {
        let summaryURL = sessionDirectory.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summaryURL),
           let summary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let candidates = [
                (summary["source_workspace_dir"] as? String).flatMap { trim($0) },
                ((summary["info"] as? [String: Any])?["cwd"] as? String).flatMap { trim($0) },
                (summary["git_root_dir"] as? String).flatMap { trim($0) }
            ]
            for candidate in candidates where !(candidate?.isEmpty ?? true) {
                let path = candidate!
                return (projectName: projectName(fromPath: path), projectPath: path)
            }
        }

        // The parent-of-parent directory name is the percent-encoded cwd.
        let encoded = sessionDirectory.deletingLastPathComponent().lastPathComponent
        if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
            return (projectName: projectName(fromPath: decoded), projectPath: decoded)
        }
        return nil
    }

    private static func projectName(fromPath path: String) -> String {
        let candidate = URL(fileURLWithPath: path).lastPathComponent
        return candidate.isEmpty ? path : candidate
    }

    /// Top-level `timestamp` is Unix seconds (10 digits); stay defensive
    /// against a future millisecond switch (13 digits).
    private static func resolveTimestamp(_ object: [String: Any]) -> Date? {
        guard let n = object["timestamp"] as? NSNumber else { return nil }
        let value = n.doubleValue
        if value >= 1e12 {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        return Date(timeIntervalSince1970: value)
    }

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? NSNumber { return n.intValue }
        if let n = raw as? Int { return n }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let n = Double(s) { return n }
        return nil
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
