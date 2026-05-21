import Foundation
import Testing
@testable import TokenBarCore

/// CL-P2-016: aggregation throughput benchmark. Smoke-tests that 100k
/// synthetic events produce a snapshot in well under the 200 ms goal so we
/// catch O(n²) regressions in PRs without waiting for Instruments.
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
                cacheTokens: 200,
                reasoningTokens: nil,
                sourcePath: "/tmp/perf-\(idx).jsonl",
                parser: .codex,
                confidence: 1
            )
        }

        let start = Date()
        let snapshot = UsageAggregator.makeSnapshot(from: events, referenceDate: reference, calendar: calendar)
        let elapsed = Date().timeIntervalSince(start)

        // 200 ms hard ceiling per CHECKLIST CL-P2-016. We give the test
        // env 4× slack (800 ms) to absorb sanitizer + CI overhead.
        #expect(elapsed < 0.8, "aggregator over budget: \(elapsed)s")
        #expect(snapshot.last30Days.count == 30)
        #expect(snapshot.today.totalTokens > 0)
    }
}
