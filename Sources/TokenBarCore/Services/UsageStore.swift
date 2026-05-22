import Foundation

public struct UsageStoreState: Sendable, Hashable {
    public let events: [UsageEvent]
    public let prompts: [PromptRecord]
    public let snapshot: UsageSnapshot
    public let warnings: [UsageSourceWarning]
    public let lastIndexedAt: Date?
    public let lastRebuildError: String?
    public let lastCheckpoint: CheckpointSummary?

    public init(
        events: [UsageEvent],
        prompts: [PromptRecord] = [],
        snapshot: UsageSnapshot,
        warnings: [UsageSourceWarning],
        lastIndexedAt: Date?,
        lastRebuildError: String?,
        lastCheckpoint: CheckpointSummary? = nil
    ) {
        self.events = events
        self.prompts = prompts
        self.snapshot = snapshot
        self.warnings = warnings
        self.lastIndexedAt = lastIndexedAt
        self.lastRebuildError = lastRebuildError
        self.lastCheckpoint = lastCheckpoint
    }
}

public actor UsageStore {
    private let repository: UsageRepository
    private var warnings: [UsageSourceWarning] = []
    private var lastIndexedAt: Date?
    private var lastRebuildError: String?

    public init(repository: UsageRepository? = nil) {
        if let repository {
            self.repository = repository
        } else {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenbar-store-\(UUID().uuidString).sqlite")
            self.repository = try! UsageRepository(databaseURL: fallbackURL)
        }
    }

    public init(databaseURL: URL) throws {
        self.repository = try UsageRepository(databaseURL: databaseURL)
    }

    public func customSources() throws -> [CustomSourceRecord] {
        try repository.listCustomSources()
    }

    public func upsertCustomSource(_ source: CustomSourceRecord) throws {
        try repository.upsertCustomSource(source)
    }

    public func deleteCustomSource(id: String) throws {
        try repository.deleteCustomSource(id: id)
    }

    public func watermarks() throws -> [String: SourceWatermark] {
        try repository.watermarks()
    }

    @discardableResult
    public func replace(
        events newEvents: [UsageEvent],
        warnings newWarnings: [UsageSourceWarning],
        indexedAt: Date,
        referenceDate: Date,
        calendar: Calendar,
        lastRebuildError newLastRebuildError: String? = nil
    ) -> UsageStoreState {
        warnings = userActionableWarnings(newWarnings)
        lastIndexedAt = indexedAt
        lastRebuildError = newLastRebuildError
        _ = try? repository.replaceEvents(newEvents)
        return makeState(referenceDate: referenceDate, calendar: calendar)
    }

    @discardableResult
    public func applyCheckpoint(
        trigger: String,
        startedAt: Date,
        endedAt: Date,
        events: [UsageEvent],
        prompts: [PromptRecord],
        nextWatermarks: [SourceWatermark] = [],
        warnings newWarnings: [UsageSourceWarning],
        referenceDate: Date,
        calendar: Calendar,
        lastRebuildError newLastRebuildError: String?
    ) -> UsageStoreState {
        let visibleWarnings = userActionableWarnings(newWarnings)
        warnings = visibleWarnings
        lastIndexedAt = startedAt
        lastRebuildError = newLastRebuildError
        _ = try? repository.insertCheckpoint(
            trigger: trigger,
            startedAt: startedAt,
            endedAt: endedAt,
            events: events,
            prompts: prompts,
            nextWatermarks: nextWatermarks,
            warnings: visibleWarnings,
            error: newLastRebuildError
        )
        return makeState(referenceDate: referenceDate, calendar: calendar)
    }

    public func reparseSource(_ sourcePath: String) throws {
        try repository.deleteWatermark(sourcePath: sourcePath)
    }

    public func reparseAll() throws {
        warnings = []
        lastIndexedAt = nil
        lastRebuildError = nil
        try repository.resetIndexForFullReparse()
    }

    public func pruneRecords(before cutoff: Date) throws {
        try repository.deleteRecords(before: cutoff)
    }

    /// CL-P1-021: hard-wipe stored prompts + VACUUM.
    public func wipePrompts() throws {
        try repository.deleteAllPromptsAndVacuum()
    }

    @discardableResult
    public func recordFailure(
        _ message: String,
        referenceDate: Date,
        calendar: Calendar
    ) -> UsageStoreState {
        lastRebuildError = message
        return makeState(referenceDate: referenceDate, calendar: calendar)
    }

    public func state(referenceDate: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> UsageStoreState {
        makeState(referenceDate: referenceDate, calendar: calendar)
    }

    private func makeState(referenceDate: Date, calendar: Calendar) -> UsageStoreState {
        let events = (try? repository.allEvents()) ?? []
        let prompts = (try? repository.allPrompts()) ?? []
        let latestCheckpoint = try? repository.latestCheckpoint()
        let effectiveWarnings = warnings.isEmpty && lastIndexedAt == nil
            ? userActionableWarnings((try? repository.latestWarnings()) ?? [])
            : warnings
        let effectiveLastIndexedAt = lastIndexedAt ?? latestCheckpoint?.startedAt
        let effectiveRebuildError = lastRebuildError ?? latestCheckpoint?.error
        let baseSnapshot = (try? repository.makeSnapshot(referenceDate: referenceDate, calendar: calendar))
            ?? UsageAggregator.makeSnapshot(from: events, referenceDate: referenceDate, calendar: calendar)
        // CL-P0-022: snapshot.warningCount is the single source of truth used
        // by Popover footer, Sidebar Diagnostics badge, and Diagnostics view.
        let snapshot = baseSnapshot.with(warningCount: effectiveWarnings.count)
        return UsageStoreState(
            events: events,
            prompts: prompts,
            snapshot: snapshot,
            warnings: effectiveWarnings,
            lastIndexedAt: effectiveLastIndexedAt,
            lastRebuildError: effectiveRebuildError,
            lastCheckpoint: latestCheckpoint
        )
    }

    private func userActionableWarnings(_ sourceWarnings: [UsageSourceWarning]) -> [UsageSourceWarning] {
        sourceWarnings.filter(\.isUserActionable)
    }
}
