import Foundation
import Testing
@testable import TokenBarCore

struct IndexRebuilderTests {
    @Test
    func rebuildMergesSourceEventsAndWarningsIntoStore() async {
        let store = UsageStore()
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!

        let sourceA = FakeUsageEventSource(
            sourceName: "codex",
            result: .success(
                UsageSourceLoadResult(
                    events: [
                        makeEvent(id: "a", agent: .codex, project: "tokenbar", total: 120, timestamp: referenceDate),
                    ],
                    warnings: []
                )
            )
        )
        let sourceB = FakeUsageEventSource(
            sourceName: "claude",
            result: .success(
                UsageSourceLoadResult(
                    events: [
                        makeEvent(id: "b", agent: .claudeCode, project: "knowledge", total: 90, timestamp: referenceDate),
                    ],
                    warnings: [
                        UsageSourceWarning(sourceName: "claude", sourcePath: "/tmp/claude.jsonl", lineNumber: 8, message: "skipped malformed line"),
                    ]
                )
            )
        )

        let rebuilder = IndexRebuilder(sources: [sourceA, sourceB], store: store)
        let result = await rebuilder.rebuild(indexedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)

        #expect(result.failure == nil)
        #expect(result.state.events.count == 2)
        #expect(result.state.snapshot.today.totalTokens == 210)
        #expect(result.state.warnings.count == 1)
        #expect(result.state.lastIndexedAt == referenceDate)
    }

    @Test
    func rebuildFailurePreservesExistingStateAndSurfacesError() async {
        let store = UsageStore()
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!

        _ = await store.replace(
            events: [makeEvent(id: "seed", agent: .codex, project: "tokenbar", total: 110, timestamp: referenceDate)],
            warnings: [],
            indexedAt: referenceDate,
            referenceDate: referenceDate,
            calendar: calendar
        )

        let failingSource = FakeUsageEventSource(
            sourceName: "codex",
            result: .failure(FakeSourceError.failed("read failed"))
        )

        let rebuilder = IndexRebuilder(sources: [failingSource], store: store)
        let result = await rebuilder.rebuild(indexedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)

        #expect(result.failure?.sourceName == "codex")
        #expect(result.state.events.count == 1)
        #expect(result.state.snapshot.today.totalTokens == 110)
        #expect(result.state.lastRebuildError == "codex: read failed")
    }

    @Test
    func rebuildKeepsSuccessfulEventsWhenOneSourceFails() async {
        let store = UsageStore()
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 12))!

        let goodSource = FakeUsageEventSource(
            sourceName: "codex",
            result: .success(
                UsageSourceLoadResult(
                    events: [makeEvent(id: "a", agent: .codex, project: "tokenbar", total: 120, timestamp: referenceDate)],
                    warnings: []
                )
            )
        )
        let failingSource = FakeUsageEventSource(
            sourceName: "claude",
            result: .failure(FakeSourceError.failed("missing path"))
        )

        let rebuilder = IndexRebuilder(sources: [goodSource, failingSource], store: store)
        let result = await rebuilder.rebuild(indexedAt: referenceDate, referenceDate: referenceDate, calendar: calendar)

        #expect(result.failure?.sourceName == "claude")
        #expect(result.state.events.count == 1)
        #expect(result.state.snapshot.today.totalTokens == 120)
        #expect(result.state.lastRebuildError == "claude: missing path")
    }

    @Test
    func noOpWatcherStartsAndStopsWithoutError() async throws {
        let watcher = NoOpFileWatcher()
        try await watcher.start()
        await watcher.stop()
        #expect(Bool(true))
    }

    private func makeEvent(id: String, agent: AgentKind, project: String, total: Int, timestamp: Date) -> UsageEvent {
        let input = Int(Double(total) * 0.5)
        let output = Int(Double(total) * 0.3)
        let cache = total - input - output

        return UsageEvent(
            id: id,
            agent: agent,
            projectPath: "/tmp/\(project)",
            projectName: project,
            sessionId: id,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cache,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            sourcePath: "/tmp/\(id).jsonl",
            parser: agent == .codex ? .codex : .claudeCode,
            confidence: 1.0
        )
    }
}

private struct FakeUsageEventSource: UsageEventSource {
    let sourceName: String
    let result: Result<UsageSourceLoadResult, Error>

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = watermarks
        _ = referenceDate
        _ = calendar
        return try result.get()
    }
}

private enum FakeSourceError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
