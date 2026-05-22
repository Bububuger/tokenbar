import Foundation

public struct IndexRebuildFailure: Sendable, Hashable {
    public let sourceName: String
    public let message: String

    public init(sourceName: String, message: String) {
        self.sourceName = sourceName
        self.message = message
    }
}

public struct IndexRebuildResult: Sendable, Hashable {
    public let state: UsageStoreState
    public let failure: IndexRebuildFailure?

    public init(state: UsageStoreState, failure: IndexRebuildFailure?) {
        self.state = state
        self.failure = failure
    }
}

public struct IndexRebuilder: Sendable {
    public let sources: [any UsageEventSource]
    public let store: UsageStore
    private let checkpointEngine: CheckpointEngine

    public init(
        sources: [any UsageEventSource],
        store: UsageStore,
        resourceThrottle: IndexingResourceThrottle? = nil
    ) {
        self.sources = sources
        self.store = store
        self.checkpointEngine = CheckpointEngine(sources: sources, store: store, resourceThrottle: resourceThrottle)
    }

    public func rebuild(
        indexedAt: Date = Date(),
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) async -> IndexRebuildResult {
        let result = await checkpointEngine.run(
            trigger: "rebuild",
            startedAt: indexedAt,
            referenceDate: referenceDate,
            calendar: calendar
        )
        return IndexRebuildResult(state: result.state, failure: result.failure)
    }
}
