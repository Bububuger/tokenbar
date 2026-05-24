import Foundation

public struct SampleUsageEventSource: InspectableUsageEventSource {
    public let sourceName = "Sample"
    public let rootPath = "sample://tokenbar"
    public let agent: AgentKind = .claudeCode

    public init() {}

    public func loadEvents(
        since watermarks: [String: SourceWatermark],
        referenceDate: Date,
        calendar: Calendar
    ) async throws -> UsageSourceLoadResult {
        _ = watermarks
        return UsageSourceLoadResult(
            events: SampleUsageProvider.events(referenceDate: referenceDate),
            warnings: []
        )
    }

    public func status(referenceDate: Date, calendar: Calendar) async -> UsageDataSourceStatus {
        UsageDataSourceStatus(
            sourceName: sourceName,
            rootPath: rootPath,
            isReadable: true,
            discoveredFileCount: SampleUsageProvider.events(referenceDate: referenceDate).count
        )
    }
}
