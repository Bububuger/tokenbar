import Foundation

public struct UsageSourceWarning: Sendable, Hashable {
    public let sourceName: String
    public let sourcePath: String
    public let lineNumber: Int?
    public let message: String

    public init(sourceName: String, sourcePath: String, lineNumber: Int?, message: String) {
        self.sourceName = sourceName
        self.sourcePath = sourcePath
        self.lineNumber = lineNumber
        self.message = message
    }
}

public struct UsageSourceLoadResult: Sendable, Hashable {
    public let events: [UsageEvent]
    public let prompts: [PromptRecord]
    public let nextWatermarks: [SourceWatermark]
    public let warnings: [UsageSourceWarning]

    public init(
        events: [UsageEvent],
        prompts: [PromptRecord] = [],
        nextWatermarks: [SourceWatermark] = [],
        warnings: [UsageSourceWarning]
    ) {
        self.events = events
        self.prompts = prompts
        self.nextWatermarks = nextWatermarks
        self.warnings = warnings
    }
}

public protocol UsageEventSource: Sendable {
    var sourceName: String { get }
    func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult
}

public extension UsageEventSource {
    func loadEvents(referenceDate: Date, calendar: Calendar) async throws -> UsageSourceLoadResult {
        try await loadEvents(since: [:], referenceDate: referenceDate, calendar: calendar)
    }
}

public protocol InspectableUsageEventSource: UsageEventSource {
    var rootPath: String { get }
    func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus
}
