import Foundation

/// Shared watermark-loop scaffold used by every JSONL-walking EventSource
/// (Claude / Codex / OpenClaw). Each used to carry ~30 lines of nearly-
/// identical code: walk discovered files → JSONLIncrementalReader → carry
/// watermark forward → call per-source parser → map `ParseWarning` to
/// `UsageSourceWarning` → tail-rest the throttle. This helper replaces all
/// three copies so a fourth JSONL agent only needs a parse closure.
public enum JSONLWatermarkLoader {
    public static func load(
        files: [URL],
        agent: AgentKind,
        sourceName: String,
        watermarks: [String: SourceWatermark],
        referenceDate: Date,
        resourceThrottle: IndexingResourceThrottle?,
        parse: (_ lines: [JSONLLineRecord], _ fileURL: URL) async -> ParseResult
    ) async throws -> UsageSourceLoadResult {
        var events: [UsageEvent] = []
        var prompts: [PromptRecord] = []
        var nextWatermarks: [SourceWatermark] = []
        var warnings: [UsageSourceWarning] = []

        for file in files {
            let incremental = try await JSONLIncrementalReader.read(
                fileURL: file,
                sourceName: sourceName,
                agent: agent,
                watermark: watermarks[file.path],
                now: referenceDate,
                resourceThrottle: resourceThrottle
            )
            warnings.append(contentsOf: incremental.warnings)

            // No new bytes — carry the previous lastEventId forward so we
            // don't lose dedup state across runs (JSONLIncrementalReader
            // does not preserve it).
            if incremental.lines.isEmpty {
                nextWatermarks.append(
                    SourceWatermark(
                        sourcePath: incremental.nextWatermark.sourcePath,
                        agent: incremental.nextWatermark.agent,
                        lastMtime: incremental.nextWatermark.lastMtime,
                        lastByteOffset: incremental.nextWatermark.lastByteOffset,
                        lastEventId: watermarks[file.path]?.lastEventId,
                        lastInode: incremental.nextWatermark.lastInode,
                        updatedAt: incremental.nextWatermark.updatedAt
                    )
                )
                continue
            }

            let result = await parse(incremental.lines, file)
            events.append(contentsOf: result.events)
            prompts.append(contentsOf: result.prompts)
            nextWatermarks.append(
                SourceWatermark(
                    sourcePath: incremental.nextWatermark.sourcePath,
                    agent: incremental.nextWatermark.agent,
                    lastMtime: incremental.nextWatermark.lastMtime,
                    lastByteOffset: incremental.nextWatermark.lastByteOffset,
                    lastEventId: result.events.last?.id ?? watermarks[file.path]?.lastEventId,
                    lastInode: incremental.nextWatermark.lastInode,
                    updatedAt: incremental.nextWatermark.updatedAt
                )
            )
            warnings.append(contentsOf: result.warnings.map { w in
                UsageSourceWarning(
                    sourceName: sourceName,
                    sourcePath: w.sourcePath,
                    lineNumber: w.lineNumber,
                    message: w.message
                )
            })

            if let resourceThrottle {
                await resourceThrottle.rest(afterActive: 0.002)
            }
        }

        return UsageSourceLoadResult(
            events: events,
            prompts: prompts,
            nextWatermarks: nextWatermarks,
            warnings: warnings
        )
    }
}
