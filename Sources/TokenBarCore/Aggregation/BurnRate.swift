import Foundation

/// Token consumption over a trailing window (default 10 min), used by the
/// menu bar burn-rate display. Excludes Cursor remote-account events: their
/// timestamps describe account-scope activity, not this Mac's.
public struct BurnRate: Sendable, Hashable {
    public static let defaultWindow: TimeInterval = 600

    public let window: TimeInterval
    public let totalTokens: Int

    public var tokensPerMinute: Double {
        guard window > 0 else { return 0 }
        return Double(totalTokens) / (window / 60)
    }

    public init(events: some Sequence<UsageEvent>, asOf: Date, window: TimeInterval = BurnRate.defaultWindow) {
        let windowStart = asOf.addingTimeInterval(-window)
        var tokens = 0
        for event in events where event.timestamp >= windowStart && event.timestamp < asOf
            && event.sourcePath != UsageRepository.cursorRemoteSourcePath {
            tokens += event.inputTokens + event.outputTokens + event.cacheReadTokens + event.cacheCreationTokens
        }
        self.window = window
        self.totalTokens = tokens
    }
}
