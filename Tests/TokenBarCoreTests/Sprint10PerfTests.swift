import Foundation
import Testing
@testable import TokenBarCore

/// CL-P2-016: aggregation throughput benchmark. Smoke-tests that 100k
/// synthetic events stay within the debug smoke-test budget so we catch
/// O(n²) regressions in PRs. The separate release acceptance goal is 200 ms.
struct Sprint10PerfTests {
    @Test
    func aggregator100kEventsCompletesWithinBudget_CL_P2_016() {
        let calendar = Calendar(identifier: .gregorian)
        let reference = calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 12))!
        let dayWindow = 30
        let events: [UsageEvent] = (0..<100_000).map { idx in
            let offsetDays = idx % dayWindow
            let timestamp = calendar.date(byAdding: .day, value: -offsetDays, to: reference) ?? reference
            return UsageEvent(
                id: "perf-\(idx)",
                agent: (idx % 3 == 0) ? .codex : .claudeCode,
                projectPath: nil,
                projectName: "proj-\(idx % 50)",
                sessionId: "s-\(idx % 5000)",
                timestamp: timestamp,
                inputTokens: 1_000,
                outputTokens: 500,
                cacheReadTokens: 200,
                cacheCreationTokens: 0,
                reasoningTokens: nil,
                sourcePath: "/tmp/perf-\(idx).jsonl",
                parser: .codex,
                confidence: 1
            )
        }

        let start = ContinuousClock.now
        let snapshot = UsageAggregator.makeSnapshot(from: events, referenceDate: reference, calendar: calendar)
        let elapsed = start.duration(to: .now)

        // Preserve the 1.0 s debug smoke-test budget (5× the release goal).
        // CI runs this suite separately from functional tests to avoid measuring
        // their concurrent CPU/I/O load. Use a monotonic clock, not civil time.
        #expect(elapsed < .seconds(1), "aggregator over budget: \(elapsed)")
        #expect(snapshot.last30Days.count == 30)
        #expect(snapshot.today.totalTokens > 0)
    }
}
