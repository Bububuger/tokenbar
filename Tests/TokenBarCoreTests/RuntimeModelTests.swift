import Foundation
import Testing
@testable import TokenBarCore

struct RuntimeModelTests {
    @Test
    func refreshStateBecomesStaleWhenIndexedDataAgesPastThreshold() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12, minute: 0))!
        let indexedAt = calendar.date(byAdding: .minute, value: -15, to: now)!

        let state = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: indexedAt,
            lastRebuildError: nil,
            refreshInterval: .fiveMinutes
        )

        #expect(state == .stale)
    }

    @Test
    func refreshStateBecomesFailedWhenRebuildErrorExists() {
        let now = Date(timeIntervalSince1970: 1_777_000_000)

        let state = RefreshStateEvaluator.evaluate(
            now: now,
            lastIndexedAt: now,
            lastRebuildError: "codex: read failed",
            refreshInterval: .fiveMinutes
        )

        #expect(state == .failed)
    }

    @Test
    func diagnosticsSnapshotSummarizesWarningsAndSourceStatuses() {
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let status = UsageDataSourceStatus(
            sourceName: "Codex",
            rootPath: "~/.codex/sessions",
            isReadable: true,
            discoveredFileCount: 12
        )

        let snapshot = DiagnosticsSnapshot(
            dataSourceStatuses: [status],
            lastIndexedAt: now,
            lastUIRefreshAt: now,
            parserWarningCount: 3,
            refreshState: .idle,
            rebuildError: nil
        )

        #expect(snapshot.dataSourceStatuses.count == 1)
        #expect(snapshot.parserWarningCount == 3)
        #expect(snapshot.refreshState == .idle)
    }
}
