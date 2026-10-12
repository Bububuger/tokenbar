import Foundation
import Testing
@testable import TokenBarCore

/// Reconciles TokenBar's DSH parsing against DSH's own accounting.
///
/// Ground truth: <DSH_HOME>/storages/session_projcache/sessions/<id>.json
/// carries record.rows.tokenUsage.val.totals (uncachedInputTokens,
/// outputTokens, cacheReadTokens, cacheWriteTokens) — the same numbers DSH
/// itself displays. The cache is a lagging snapshot for live sessions, so
/// the comparison truncates our parsed events at the seq the cache recorded
/// (tokenUsage.seq).
///
/// Skipped on machines without a DSH home (CI).
struct DshGroundTruthTests {
    private static let dshHome = NSString(string: NSHomeDirectory()).appendingPathComponent(".dsh")
    private static let sessionsRoot = NSString(string: dshHome).appendingPathComponent("sessions")
    private static let projcacheRoot = NSString(string: dshHome)
        .appendingPathComponent("storages/session_projcache/sessions")

    private static func hasGroundTruth() -> Bool {
        FileManager.default.fileExists(atPath: projcacheRoot)
    }

    @Test(.disabled(if: !hasGroundTruth(), "no local DSH home"))
    func parsedTotalsMatchProjcacheTotals() async throws {
        let source = DshUsageEventSource(rootPath: Self.dshHome)
        let reference = Date()
        let result = try await source.loadEvents(referenceDate: reference, calendar: Calendar(identifier: .gregorian))

        // Group by session id.
        var bySession: [String: [UsageEvent]] = [:]
        for event in result.events {
            bySession[event.sessionId, default: []].append(event)
        }
        #expect(!bySession.isEmpty)

        var checked = 0
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: Self.projcacheRoot)
        for file in files where file.hasSuffix(".json") {
            let path = NSString(string: Self.projcacheRoot).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let record = object["record"] as? [String: Any],
                  let rows = record["rows"] as? [String: Any],
                  let tokenUsage = rows["tokenUsage"] as? [String: Any],
                  let cutoffSeq = (tokenUsage["seq"] as? NSNumber)?.intValue,
                  let usage = tokenUsage["val"] as? [String: Any],
                  let totals = usage["totals"] as? [String: Any] else {
                continue
            }

            let sessionID = (file as NSString).deletingPathExtension
            // Initialized sessions can legitimately have no usage events and
            // four zero totals. Nonzero cache totals still fail the comparison.
            let events = bySession[sessionID] ?? []

            // Truncate at the seq the projcache snapshot recorded.
            let truncated = events.filter { event in
                Self.seq(of: event) <= cutoffSeq
            }
            let input = truncated.reduce(0) { $0 + $1.inputTokens }
            let output = truncated.reduce(0) { $0 + $1.outputTokens }
            let cacheRead = truncated.reduce(0) { $0 + $1.cacheReadTokens }
            let cacheWrite = truncated.reduce(0) { $0 + $1.cacheCreationTokens }

            let label = sessionID
            #expect(input == (totals["uncachedInputTokens"] as? NSNumber)?.intValue, Comment(rawValue: "input mismatch for " + label))
            #expect(output == (totals["outputTokens"] as? NSNumber)?.intValue, Comment(rawValue: "output mismatch for " + label))
            #expect(cacheRead == (totals["cacheReadTokens"] as? NSNumber)?.intValue, Comment(rawValue: "cacheRead mismatch for " + label))
            #expect(cacheWrite == (totals["cacheWriteTokens"] as? NSNumber)?.intValue, Comment(rawValue: "cacheWrite mismatch for " + label))
            checked += 1
        }
        #expect(checked >= 1)
    }

    /// Event id is "<path>#dsh#<session-id>#<seq>"; the trailing integer is
    /// the session-global seq DSH stamped on the assistant/message event.
    private static func seq(of event: UsageEvent) -> Int {
        let parts = event.id.split(separator: "#")
        guard let last = parts.last else { return Int.max }
        return Int(last) ?? Int.max
    }
}
