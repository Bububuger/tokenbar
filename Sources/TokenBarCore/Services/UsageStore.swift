import Foundation

public struct UsageStoreState: Sendable, Hashable {
    public let events: [UsageEvent]
    public let prompts: [PromptRecord]
    public let eventCount: Int
    public let promptCount: Int
    public let eventSignature: String
    public let promptSignature: String
    public let snapshot: UsageSnapshot
    public let warnings: [UsageSourceWarning]
    public let lastIndexedAt: Date?
    public let lastRebuildError: String?
    public let lastCheckpoint: CheckpointSummary?

    public init(
        events: [UsageEvent],
        prompts: [PromptRecord] = [],
        eventCount: Int? = nil,
        promptCount: Int? = nil,
        eventSignature: String? = nil,
        promptSignature: String? = nil,
        snapshot: UsageSnapshot,
        warnings: [UsageSourceWarning],
        lastIndexedAt: Date?,
        lastRebuildError: String?,
        lastCheckpoint: CheckpointSummary? = nil
    ) {
        self.events = events
        self.prompts = prompts
        self.eventCount = eventCount ?? events.count
        self.promptCount = promptCount ?? prompts.count
        self.eventSignature = eventSignature ?? Self.makeEventSignature(from: events)
        self.promptSignature = promptSignature ?? Self.makePromptSignature(from: prompts)
        self.snapshot = snapshot
        self.warnings = warnings
        self.lastIndexedAt = lastIndexedAt
        self.lastRebuildError = lastRebuildError
        self.lastCheckpoint = lastCheckpoint
    }

    fileprivate static func makeEventSignature(from events: [UsageEvent]) -> String {
        guard !events.isEmpty else {
            return "events:0:ts0:ts0:0:0"
        }
        var minTimestamp = Int64.max
        var maxTimestamp = Int64.min
        var minId = ""
        var maxId = ""
        var eventBytes = 0

        for event in events {
            let timestamp = event.timestamp.tokenBarMillisecondsSince1970
            minTimestamp = min(minTimestamp, timestamp)
            maxTimestamp = max(maxTimestamp, timestamp)
            if minId.isEmpty || event.id < minId {
                minId = event.id
            }
            if maxId.isEmpty || event.id > maxId {
                maxId = event.id
            }
            eventBytes += event.id.utf8.count
        }

        return "events:\(events.count):\(minTimestamp):\(maxTimestamp):\(eventBytes):\(minId):\(maxId)"
    }

    fileprivate static func makePromptSignature(from prompts: [PromptRecord]) -> String {
        guard !prompts.isEmpty else {
            return "prompts:0:ts0:ts0:0:0"
        }
        var minTimestamp = Int64.max
        var maxTimestamp = Int64.min
        var minHash = ""
        var maxHash = ""
        var hashBytes = 0

        for prompt in prompts {
            let timestamp = prompt.timestamp.tokenBarMillisecondsSince1970
            minTimestamp = min(minTimestamp, timestamp)
            maxTimestamp = max(maxTimestamp, timestamp)
            if minHash.isEmpty || prompt.contentHash < minHash {
                minHash = prompt.contentHash
            }
            if maxHash.isEmpty || prompt.contentHash > maxHash {
                maxHash = prompt.contentHash
            }
            hashBytes += prompt.contentHash.utf8.count
        }

        return "prompts:\(prompts.count):\(minTimestamp):\(maxTimestamp):\(hashBytes):\(minHash):\(maxHash)"
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

    public func deleteCustomSourceData(id: String) throws {
        try repository.deleteCustomSourceData(id: id)
    }

    public func allSavedPrompts() throws -> [SavedPrompt] {
        try repository.allSavedPrompts()
    }

    public func savedPrompt(slug: String) throws -> SavedPrompt? {
        try repository.savedPrompt(slug: slug)
    }

    public func upsertSavedPrompt(_ prompt: SavedPrompt) throws {
        try repository.upsertSavedPrompt(prompt)
    }

    public func deleteSavedPrompt(id: String) throws {
        try repository.deleteSavedPrompt(id: id)
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
        lastRebuildError newLastRebuildError: String? = nil,
        includePrompts: Bool = false,
        includeEvents: Bool = false
    ) -> UsageStoreState {
        warnings = userActionableWarnings(newWarnings)
        lastIndexedAt = indexedAt
        lastRebuildError = newLastRebuildError
        _ = try? repository.replaceEvents(newEvents)
        return makeState(
            referenceDate: referenceDate,
            calendar: calendar,
            includePrompts: includePrompts,
            includeEvents: includeEvents
        )
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
        lastRebuildError newLastRebuildError: String?,
        stateIncludesPrompts: Bool = true
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
        return makeState(referenceDate: referenceDate, calendar: calendar, includePrompts: stateIncludesPrompts)
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
        calendar: Calendar,
        includePrompts: Bool = false,
        includeEvents: Bool = true
    ) -> UsageStoreState {
        lastRebuildError = message
        // Events preserved (callers like CheckpointEngine surface them in
        // IndexRebuildResult). Prompts skipped — was hardcoded true, no
        // caller in tree needs the full prompt content on failure.
        return makeState(
            referenceDate: referenceDate,
            calendar: calendar,
            includePrompts: includePrompts,
            includeEvents: includeEvents
        )
    }

    public func state(
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian),
        includePrompts: Bool = false,
        includeEvents: Bool = false
    ) -> UsageStoreState {
        makeState(
            referenceDate: referenceDate,
            calendar: calendar,
            includePrompts: includePrompts,
            includeEvents: includeEvents
        )
    }

    public func projectEvents(projectName: String, limit: Int? = nil) throws -> [UsageEvent] {
        try repository.projectEvents(projectName: projectName, limit: limit)
    }

    public func eventTimeBounds() throws -> UsageEventTimeBounds {
        try repository.eventTimeBounds()
    }

    public func projectBreakdowns(
        start: Date,
        end: Date,
        topCount: Int? = nil
    ) throws -> [UsageBreakdown] {
        try repository.projectBreakdowns(start: start, end: end, topCount: topCount)
    }

    public func rangeAggregate(
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws -> UsageRangeAggregate {
        try repository.rangeAggregate(start: start, end: end, calendar: calendar)
    }

    public func projectPromptHistory(
        projectName: String,
        limit: Int? = nil,
        includeContent: Bool = false
    ) throws -> [PromptRecord] {
        try repository.projectPromptHistory(
            projectName: projectName,
            limit: limit,
            includeContent: includeContent
        )
    }

    public func projectPromptHistoryPage(
        projectName: String,
        limit: Int,
        offset: Int,
        includeContent: Bool = false,
        query: String = "",
        kindFilter: PromptHistoryKindFilter = .all,
        bookmarkedIds: Set<String> = []
    ) throws -> PromptHistoryPage {
        try repository.projectPromptHistoryPage(
            projectName: projectName,
            limit: limit,
            offset: offset,
            includeContent: includeContent,
            query: query,
            kindFilter: kindFilter,
            bookmarkedIds: bookmarkedIds
        )
    }

    public func projectPromptCountsByDay(
        projectName: String,
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws -> [Date: Int] {
        try repository.projectPromptCountsByDay(
            projectName: projectName,
            start: start,
            end: end,
            calendar: calendar
        )
    }

    public func projectSummary(projectName: String) throws -> UsageSummary {
        try repository.projectSummary(projectName: projectName)
    }

    private func makeState(
        referenceDate: Date,
        calendar: Calendar,
        includePrompts: Bool,
        includeEvents: Bool = true
    ) -> UsageStoreState {
        let signatures = (try? repository.collectionSignatures()) ?? nil
        // Lazy event/prompt load: callers that only need snapshot+counts skip
        // pulling the full content. Was unconditionally full-table per call.
        let events: [UsageEvent]
        let snapshotFallbackEvents: [UsageEvent]
        if includeEvents {
            let loaded = (try? repository.allEvents()) ?? []
            events = loaded
            snapshotFallbackEvents = loaded
        } else {
            events = []
            snapshotFallbackEvents = []
        }
        let prompts = includePrompts
            ? (try? repository.allPrompts()) ?? []
            : []
        let latestCheckpoint = try? repository.latestCheckpoint()
        let effectiveWarnings = warnings.isEmpty && lastIndexedAt == nil
            ? userActionableWarnings((try? repository.latestWarnings()) ?? [])
            : warnings
        let effectiveLastIndexedAt = lastIndexedAt ?? latestCheckpoint?.startedAt
        let effectiveRebuildError = lastRebuildError ?? latestCheckpoint?.error
        let baseSnapshot = (try? repository.makeSnapshot(referenceDate: referenceDate, calendar: calendar))
            ?? UsageAggregator.makeSnapshot(from: snapshotFallbackEvents, referenceDate: referenceDate, calendar: calendar)
        // CL-P0-022: snapshot.warningCount is the single source of truth used
        // by Popover footer, Sidebar Diagnostics badge, and Diagnostics view.
        let snapshot = baseSnapshot.with(warningCount: effectiveWarnings.count)
        let eventCount = includeEvents
            ? events.count
            : signatures?.eventCount ?? events.count
        return UsageStoreState(
            events: events,
            prompts: prompts,
            eventCount: eventCount,
            promptCount: includePrompts
                ? prompts.count
                : signatures?.promptCount ?? 0,
            eventSignature: signatures?.eventSignature ?? UsageStoreState.makeEventSignature(from: events),
            promptSignature: includePrompts
                ? UsageStoreState.makePromptSignature(from: prompts)
                : signatures?.promptSignature ?? UsageStoreState.makePromptSignature(from: []),
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
