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
    private var runState: RunState = .idle

    public init(sources: [any UsageEventSource], store: UsageStore) {
        self.sources = sources
        self.store = store
    }

    public func trigger(
        _ trigger: String,
        startedAt: Date = Date(),
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
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
            calendar: calendar
        )

        while case .pending(let pendingTrigger) = runState {
            runState = .running
            result = await execute(
                trigger: pendingTrigger,
                startedAt: Date(),
                referenceDate: Date(),
                calendar: calendar
            )
        }

        runState = .idle
        return result
    }

    public func run(
        trigger: String,
        startedAt: Date = Date(),
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) async -> CheckpointRunResult {
        if let result = await self.trigger(trigger, startedAt: startedAt, referenceDate: referenceDate, calendar: calendar) {
            return result
        }
        let state = await store.state(referenceDate: referenceDate, calendar: calendar)
        return CheckpointRunResult(state: state, failure: nil, checkpoint: state.lastCheckpoint)
    }

    private func execute(
        trigger: String,
        startedAt: Date,
        referenceDate: Date,
        calendar: Calendar
    ) async -> CheckpointRunResult {
        var allEvents: [UsageEvent] = []
        var allPrompts: [PromptRecord] = []
        var allNextWatermarks: [SourceWatermark] = []
        var allWarnings: [UsageSourceWarning] = []
        var failures: [IndexRebuildFailure] = []
        let watermarks = (try? await store.watermarks()) ?? [:]

        for source in sources {
            do {
                let result = try await source.loadEvents(since: watermarks, referenceDate: referenceDate, calendar: calendar)
                allEvents.append(contentsOf: result.events)
                allPrompts.append(contentsOf: result.prompts)
                allNextWatermarks.append(contentsOf: result.nextWatermarks)
                allWarnings.append(contentsOf: result.warnings)
            } catch {
                failures.append(
                    IndexRebuildFailure(sourceName: source.sourceName, message: describe(error))
                )
            }
        }

        let errorSummary = failures.isEmpty ? nil : failures.map { "\($0.sourceName): \($0.message)" }.joined(separator: " | ")
        if allEvents.isEmpty, allPrompts.isEmpty, let firstFailure = failures.first {
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
            lastRebuildError: errorSummary
        )
        return CheckpointRunResult(state: state, failure: failures.first, checkpoint: state.lastCheckpoint)
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
