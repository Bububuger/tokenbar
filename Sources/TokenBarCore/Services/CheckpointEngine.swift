import Foundation

public struct CheckpointRunResult: Sendable, Hashable {
    public let state: UsageStoreState
    public let failure: IndexRebuildFailure?
    public let checkpoint: CheckpointSummary?

    public init(state: UsageStoreState, failure: IndexRebuildFailure?, checkpoint: CheckpointSummary?) {
        self.state = state
        self.failure = failure
        self.checkpoint = checkpoint
    }
}

public actor CheckpointEngine {
    private enum RunState {
        case idle
        case running
        case pending(trigger: String)
    }

    public let sources: [any UsageEventSource]
    public let store: UsageStore
    private let resourceThrottle: IndexingResourceThrottle?
    private let stateIncludesPrompts: Bool
    private var runState: RunState = .idle

    public init(
        sources: [any UsageEventSource],
        store: UsageStore,
        resourceThrottle: IndexingResourceThrottle? = nil,
        stateIncludesPrompts: Bool = true
    ) {
        self.sources = sources
        self.store = store
        self.resourceThrottle = resourceThrottle
        self.stateIncludesPrompts = stateIncludesPrompts
    }

    /// Per-source progress callback. Fires once per source as its TaskGroup
    /// child completes, in completion order. Callers (e.g. the runtime model)
    /// use this to drive a live `indexingState` while a bootstrap refresh is
    /// reading from disk.
    public typealias SourceProgressHandler = @Sendable (_ sourceName: String, _ succeeded: Bool) async -> Void

    public func trigger(
        _ trigger: String,
        startedAt: Date = Date(),
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        onSourceProgress: SourceProgressHandler? = nil
    ) async -> CheckpointRunResult? {
        switch runState {
        case .idle:
            runState = .running
        case .running, .pending:
            runState = .pending(trigger: trigger)
            return nil
        }

        var result = await execute(
            trigger: trigger,
            startedAt: startedAt,
            referenceDate: referenceDate,
            calendar: calendar,
            onSourceProgress: onSourceProgress
        )

        while case .pending(let pendingTrigger) = runState {
            runState = .running
            result = await execute(
                trigger: pendingTrigger,
                startedAt: Date(),
                referenceDate: Date(),
                calendar: calendar,
                onSourceProgress: nil
            )
        }

        runState = .idle
        return result
    }

    public func run(
        trigger: String,
        startedAt: Date = Date(),
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        onSourceProgress: SourceProgressHandler? = nil
    ) async -> CheckpointRunResult {
        if let result = await self.trigger(trigger, startedAt: startedAt, referenceDate: referenceDate, calendar: calendar, onSourceProgress: onSourceProgress) {
            return result
        }
        let state = await store.state(referenceDate: referenceDate, calendar: calendar, includePrompts: stateIncludesPrompts)
        return CheckpointRunResult(state: state, failure: nil, checkpoint: state.lastCheckpoint)
    }

    private struct PerSourceOutcome: Sendable {
        let sourceIndex: Int
        let slotIndex: Int
        let sourceName: String
        let result: UsageSourceLoadResult?
        let failureMessage: String?
    }

    /// Concurrency degree for `execute`. Fixed mapping (Decision A in
    /// docs/work-items/2026-05-23-tokenbar-parallel-refresh-and-throttle.md):
    /// no budget → serial; `.initialIndex` (≥ 20% CPU) → 3 slots; else 2.
    nonisolated static func parallelSlotCount(for throttle: IndexingResourceThrottle?) -> Int {
        guard let throttle else { return 1 }
        return throttle.budget.cpuPercent >= IndexingResourceBudget.initialIndexCPUPercent ? 3 : 2
    }

    private func execute(
        trigger: String,
        startedAt: Date,
        referenceDate: Date,
        calendar: Calendar,
        onSourceProgress: SourceProgressHandler? = nil
    ) async -> CheckpointRunResult {
        let watermarks = (try? await store.watermarks()) ?? [:]
        let slotCount = Self.parallelSlotCount(for: resourceThrottle)

        // Per-slot throttles preserve single-timeline accounting within each
        // slot. Decision B: orchestrator owns the slot throttles; sources never
        // share. After the run we fold each slot's snapshot back into the
        // caller-visible parent throttle so external `.snapshot()` stays
        // meaningful.
        let slotThrottles: [IndexingResourceThrottle?] = if let parent = resourceThrottle {
            (0..<slotCount).map { _ in IndexingResourceThrottle(budget: parent.budget) }
        } else {
            Array(repeating: nil, count: slotCount)
        }

        var outcomes: [PerSourceOutcome] = []
        outcomes.reserveCapacity(sources.count)

        await withTaskGroup(of: PerSourceOutcome.self) { group in
            var nextSourceIndex = 0
            let prime = min(slotCount, sources.count)
            for slot in 0..<prime {
                let i = nextSourceIndex
                nextSourceIndex += 1
                let source = sources[i]
                let throttle = slotThrottles[slot]
                group.addTask {
                    await Self.loadOne(
                        source: source,
                        sourceIndex: i,
                        slotIndex: slot,
                        watermarks: watermarks,
                        referenceDate: referenceDate,
                        calendar: calendar,
                        throttle: throttle
                    )
                }
            }

            while let outcome = await group.next() {
                outcomes.append(outcome)
                if let onSourceProgress {
                    await onSourceProgress(outcome.sourceName, outcome.result != nil)
                }
                if nextSourceIndex < sources.count {
                    let i = nextSourceIndex
                    nextSourceIndex += 1
                    let source = sources[i]
                    let slot = outcome.slotIndex
                    let throttle = slotThrottles[slot]
                    group.addTask {
                        await Self.loadOne(
                            source: source,
                            sourceIndex: i,
                            slotIndex: slot,
                            watermarks: watermarks,
                            referenceDate: referenceDate,
                            calendar: calendar,
                            throttle: throttle
                        )
                    }
                }
            }
        }

        // Deterministic order regardless of completion order.
        outcomes.sort { $0.sourceIndex < $1.sourceIndex }

        var allEvents: [UsageEvent] = []
        var allPrompts: [PromptRecord] = []
        var allNextWatermarks: [SourceWatermark] = []
        var allWarnings: [UsageSourceWarning] = []
        var failures: [IndexRebuildFailure] = []

        for outcome in outcomes {
            if let result = outcome.result {
                allEvents.append(contentsOf: result.events)
                allPrompts.append(contentsOf: result.prompts)
                allNextWatermarks.append(contentsOf: result.nextWatermarks)
                allWarnings.append(contentsOf: result.warnings)
            } else if let message = outcome.failureMessage {
                failures.append(
                    IndexRebuildFailure(sourceName: outcome.sourceName, message: message)
                )
            }
        }

        if let parent = resourceThrottle {
            for slotThrottle in slotThrottles {
                if let slotThrottle {
                    let snapshot = await slotThrottle.snapshot()
                    await parent.merge(snapshot)
                }
            }
        }

        let errorSummary = failures.isEmpty ? nil : failures.map { "\($0.sourceName): \($0.message)" }.joined(separator: " | ")
        // Only fall through to `recordFailure` when *every* source failed and
        // produced nothing. A partial failure (one source throws while others
        // return empty results at-watermark) is the parallel-path steady
        // state — applying the checkpoint advances the surviving sources'
        // watermarks and records `lastRebuildError` for the failing one.
        if failures.count == sources.count, !sources.isEmpty,
           allEvents.isEmpty, allPrompts.isEmpty,
           let firstFailure = failures.first {
            let state = await store.recordFailure(errorSummary ?? firstFailure.message, referenceDate: referenceDate, calendar: calendar)
            return CheckpointRunResult(state: state, failure: firstFailure, checkpoint: state.lastCheckpoint)
        }

        let endedAt = Date()
        let state = await store.applyCheckpoint(
            trigger: trigger,
            startedAt: startedAt,
            endedAt: endedAt,
            events: allEvents,
            prompts: allPrompts,
            nextWatermarks: allNextWatermarks,
            warnings: allWarnings,
            referenceDate: referenceDate,
            calendar: calendar,
            lastRebuildError: errorSummary,
            stateIncludesPrompts: stateIncludesPrompts
        )
        return CheckpointRunResult(state: state, failure: failures.first, checkpoint: state.lastCheckpoint)
    }

    private static func loadOne(
        source: any UsageEventSource,
        sourceIndex: Int,
        slotIndex: Int,
        watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar,
        throttle: IndexingResourceThrottle?
    ) async -> PerSourceOutcome {
        do {
            let result: UsageSourceLoadResult
            if let budgeted = source as? any ResourceBudgetedUsageEventSource {
                result = try await budgeted.loadEvents(
                    since: watermarks,
                    referenceDate: referenceDate,
                    calendar: calendar,
                    resourceThrottle: throttle
                )
            } else {
                result = try await source.loadEvents(
                    since: watermarks,
                    referenceDate: referenceDate,
                    calendar: calendar
                )
            }
            return PerSourceOutcome(
                sourceIndex: sourceIndex,
                slotIndex: slotIndex,
                sourceName: source.sourceName,
                result: result,
                failureMessage: nil
            )
        } catch {
            return PerSourceOutcome(
                sourceIndex: sourceIndex,
                slotIndex: slotIndex,
                sourceName: source.sourceName,
                result: nil,
                failureMessage: describe(error)
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
