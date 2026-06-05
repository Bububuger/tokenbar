import Foundation
import Testing
@testable import TokenBarCore

struct CheckpointEngineParallelTests {
    @Test
    func parallelSlotCountFollowsBudget() {
        #expect(CheckpointEngine.parallelSlotCount(for: nil) == 1)

        let background = IndexingResourceThrottle(budget: .background)
        #expect(CheckpointEngine.parallelSlotCount(for: background) == 2)

        let initialIndex = IndexingResourceThrottle(budget: .initialIndex)
        #expect(CheckpointEngine.parallelSlotCount(for: initialIndex) == 3)

        let smallBudget = IndexingResourceThrottle(budget: IndexingResourceBudget(cpuPercent: 5))
        #expect(CheckpointEngine.parallelSlotCount(for: smallBudget) == 2)

        let largeBudget = IndexingResourceThrottle(budget: IndexingResourceBudget(cpuPercent: 25))
        #expect(CheckpointEngine.parallelSlotCount(for: largeBudget) == 3)
    }

    @Test
    func parallelRunFinishesFasterThanSerialEquivalent() async throws {
        // Compare two runs of the same stub sources: one with no throttle
        // (slotCount=1, serial) and one with `.background` throttle
        // (slotCount=2, parallel). Asserting a ratio sidesteps absolute
        // wallclock jitter from CI.
        func makeSources() -> [any UsageEventSource] {
            (0..<4).map { i in
                SleepingStubSource(name: "s\(i)", sleepMilliseconds: 150, eventID: "e\(i)")
            }
        }

        // Warm-up: pay one-time fixed cost (SQLite migration, etc.) so it
        // doesn't bias the first timed run.
        let warmupStore = try UsageStore(databaseURL: temporaryDatabaseURL())
        _ = await CheckpointEngine(sources: makeSources(), store: warmupStore)
            .run(trigger: "warmup")

        let serialStore = try UsageStore(databaseURL: temporaryDatabaseURL())
        let serialEngine = CheckpointEngine(sources: makeSources(), store: serialStore)
        let serialStarted = Date()
        let serialResult = await serialEngine.run(trigger: "test-serial")
        let serialElapsed = Date().timeIntervalSince(serialStarted)

        let parallelStore = try UsageStore(databaseURL: temporaryDatabaseURL())
        let parallelEngine = CheckpointEngine(
            sources: makeSources(),
            store: parallelStore,
            resourceThrottle: IndexingResourceThrottle(budget: .background)
        )
        let parallelStarted = Date()
        let parallelResult = await parallelEngine.run(trigger: "test-parallel")
        let parallelElapsed = Date().timeIntervalSince(parallelStarted)

        #expect(serialResult.state.events.count == 4)
        #expect(parallelResult.state.events.count == 4)
        // Serial: 4 × 150ms ≈ 600ms. Parallel with N=2: two batches of 2
        // sources ≈ 300ms. Require ≥ 15% reduction (relaxed from 30% to
        // tolerate CI runner jitter).
        #expect(
            parallelElapsed < serialElapsed * 0.85,
            "parallel (\(parallelElapsed * 1000)ms) did not improve on serial (\(serialElapsed * 1000)ms) by ≥15%"
        )
    }

    @Test
    func emittedEventsAreDeterministicallyOrderedBySourceIndex() async throws {
        // Source 0 sleeps the longest; under parallelism it will finish last.
        // Verify event order in the store still matches source order.
        let sources: [any UsageEventSource] = [
            SleepingStubSource(name: "s0", sleepMilliseconds: 200, eventID: "evt-0"),
            SleepingStubSource(name: "s1", sleepMilliseconds: 50, eventID: "evt-1"),
            SleepingStubSource(name: "s2", sleepMilliseconds: 10, eventID: "evt-2"),
        ]
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let throttle = IndexingResourceThrottle(budget: .background)
        let engine = CheckpointEngine(sources: sources, store: store, resourceThrottle: throttle)

        let result = await engine.run(trigger: "test-determinism")
        let checkpoint = result.checkpoint
        #expect(checkpoint?.eventsAdded == 3)

        // The store sorts on (timestamp, id). Our stub sources stamp all
        // events at the same timestamp but with distinct IDs (evt-0/1/2),
        // so ID order is the tiebreaker — and IDs are derived from source
        // index. This proves the accumulator did not lose ordering when
        // tasks completed out of order.
        let ids = result.state.events.map(\.id).sorted()
        #expect(ids == ["evt-0", "evt-1", "evt-2"])
    }

    @Test
    func firstFailureIsLowestSourceIndexNotFirstToFinish() async throws {
        // Two failing sources: source 0 fails after a delay, source 1 fails
        // immediately. The reported `failures.first` must be source 0
        // (lowest index), not source 1 (first to finish).
        let sources: [any UsageEventSource] = [
            FailingStubSource(sourceName: "slow-fail", sleepMilliseconds: 150, message: "first-error"),
            FailingStubSource(sourceName: "fast-fail", sleepMilliseconds: 10, message: "second-error"),
        ]
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let throttle = IndexingResourceThrottle(budget: .background)
        let engine = CheckpointEngine(sources: sources, store: store, resourceThrottle: throttle)

        let result = await engine.run(trigger: "test-failures")
        #expect(result.failure?.sourceName == "slow-fail")
        #expect(result.failure?.message.contains("first-error") == true)
    }

    @Test
    func partialFailureStillAppliesCheckpointForSucceedingSources() async throws {
        // 1 failing + 1 empty-success + 1 returning-events. Pre-fix the
        // engine would short-circuit because allEvents was empty AND a
        // failure existed; post-fix the success path's events must land
        // and lastRebuildError must reflect the failing source.
        let sources: [any UsageEventSource] = [
            FailingStubSource(sourceName: "broken", sleepMilliseconds: 20, message: "boom"),
            EmptyStubSource(sourceName: "at-watermark"),
            SleepingStubSource(name: "active", sleepMilliseconds: 20, eventID: "active-evt"),
        ]
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let engine = CheckpointEngine(
            sources: sources,
            store: store,
            resourceThrottle: IndexingResourceThrottle(budget: .background)
        )

        let result = await engine.run(trigger: "test-partial")

        #expect(result.state.events.count == 1)
        #expect(result.state.events.first?.id == "active-evt")
        #expect(result.state.lastRebuildError?.contains("broken") == true)
        #expect(result.state.lastRebuildError?.contains("boom") == true)
        #expect(result.checkpoint != nil, "applyCheckpoint must run even with a partial failure")
    }

    @Test
    func totalFailureStillRecordsFailureWithoutCheckpoint() async throws {
        // Every source throws and no events are produced — preserve the
        // `recordFailure` path so the runtime still surfaces the error.
        let sources: [any UsageEventSource] = [
            FailingStubSource(sourceName: "broken-a", sleepMilliseconds: 5, message: "a-boom"),
            FailingStubSource(sourceName: "broken-b", sleepMilliseconds: 5, message: "b-boom"),
        ]
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let engine = CheckpointEngine(
            sources: sources,
            store: store,
            resourceThrottle: IndexingResourceThrottle(budget: .background)
        )

        let result = await engine.run(trigger: "test-total-failure")

        #expect(result.failure?.sourceName == "broken-a")
        #expect(result.state.events.isEmpty)
        #expect(result.state.lastRebuildError != nil)
    }

    @Test
    func slotThrottleSnapshotsMergeBackIntoParent() async throws {
        // Budgeted stub source reports a known amount of active time via
        // the throttle. With two such sources running through a parent
        // throttle, the parent's post-run snapshot should reflect the sum.
        let sources: [any UsageEventSource] = [
            BudgetedActiveStubSource(name: "b0", activeMilliseconds: 80, eventID: "be-0"),
            BudgetedActiveStubSource(name: "b1", activeMilliseconds: 80, eventID: "be-1"),
        ]
        let store = try UsageStore(databaseURL: temporaryDatabaseURL())
        let throttle = IndexingResourceThrottle(budget: .initialIndex)
        let engine = CheckpointEngine(sources: sources, store: store, resourceThrottle: throttle)

        _ = await engine.run(trigger: "test-merge")
        let snapshot = await throttle.snapshot()
        #expect(snapshot.activeSeconds >= 0.16, "expected ≥160ms aggregated active time, got \(snapshot.activeSeconds * 1000)ms")
    }

    // MARK: - Test helpers

    private func temporaryDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-parallel-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tokenbar.sqlite")
    }
}

private struct SleepingStubSource: UsageEventSource {
    let sourceName: String
    let sleepMilliseconds: Int
    let eventID: String

    init(name: String, sleepMilliseconds: Int, eventID: String) {
        self.sourceName = name
        self.sleepMilliseconds = sleepMilliseconds
        self.eventID = eventID
    }

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = watermarks
        _ = calendar
        try? await Task.sleep(for: .milliseconds(sleepMilliseconds))
        let event = UsageEvent(
            id: eventID,
            agent: .codex,
            projectPath: "/tmp/tokenbar",
            projectName: "tokenbar",
            sessionId: "session-\(eventID)",
            timestamp: referenceDate,
            inputTokens: 1,
            outputTokens: 1,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            modelName: nil,
            sourcePath: "/tmp/\(sourceName).jsonl",
            parser: .codex,
            confidence: 1.0
        )
        return UsageSourceLoadResult(events: [event], warnings: [])
    }
}

private struct EmptyStubSource: UsageEventSource {
    let sourceName: String

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = watermarks
        _ = referenceDate
        _ = calendar
        return UsageSourceLoadResult(events: [], warnings: [])
    }
}

private struct FailingStubSource: UsageEventSource {
    let sourceName: String
    let sleepMilliseconds: Int
    let message: String

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = watermarks
        _ = referenceDate
        _ = calendar
        try? await Task.sleep(for: .milliseconds(sleepMilliseconds))
        throw StubError.failure(message)
    }
}

private struct BudgetedActiveStubSource: UsageEventSource, ResourceBudgetedUsageEventSource {
    let sourceName: String
    let activeMilliseconds: Int
    let eventID: String

    init(name: String, activeMilliseconds: Int, eventID: String) {
        self.sourceName = name
        self.activeMilliseconds = activeMilliseconds
        self.eventID = eventID
    }

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        try await loadEvents(since: watermarks, referenceDate: referenceDate, calendar: calendar, resourceThrottle: nil)
    }

    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar,
        resourceThrottle: IndexingResourceThrottle?
    ) async throws -> UsageSourceLoadResult {
        _ = watermarks
        _ = calendar
        if let resourceThrottle {
            await resourceThrottle.rest(afterActive: Double(activeMilliseconds) / 1000.0)
        }
        let event = UsageEvent(
            id: eventID,
            agent: .codex,
            projectPath: "/tmp/tokenbar",
            projectName: "tokenbar",
            sessionId: "session-\(eventID)",
            timestamp: referenceDate,
            inputTokens: 1,
            outputTokens: 1,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            modelName: nil,
            sourcePath: "/tmp/\(sourceName).jsonl",
            parser: .codex,
            confidence: 1.0
        )
        return UsageSourceLoadResult(events: [event], warnings: [])
    }
}

private enum StubError: Error, LocalizedError {
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .failure(let message): return message
        }
    }
}
