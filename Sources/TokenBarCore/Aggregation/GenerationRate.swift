import Foundation

/// Per-response generation speed (output tokens ÷ wall-clock dispatch→end,
/// TTFT included) over a trailing window, used by the menu bar output-speed
/// mirror. Only events whose source recorded explicit generation boundaries
/// contribute; the rest are skipped rather than estimated. Excludes Cursor
/// remote-account events (same convention as BurnRate).
public struct GenerationRate: Sendable, Hashable {
    public static let defaultWindow: TimeInterval = 600
    /// Lower bound on one response's measured seconds — sub-500ms
    /// completions would otherwise inflate tok/s toward infinity.
    public static let minimumDurationSeconds: Double = 0.5

    /// Trailing window over which completed responses contribute, seconds.
    public let window: TimeInterval
    /// Responses that contributed a valid timing sample.
    public let sampleCount: Int
    /// Sum of output tokens across samples.
    public let outputTokens: Int
    /// Sum of per-response durations after the 500 ms floor, seconds.
    public let totalDurationSeconds: Double

    /// Output-weighted generation speed, or nil when no response in the
    /// window carries valid timing — callers render `nil` as `—`.
    public var tokensPerSecond: Double? {
        guard sampleCount > 0, totalDurationSeconds > 0 else { return nil }
        return Double(outputTokens) / totalDurationSeconds
    }

    public init(events: [UsageEvent], window: TimeInterval = GenerationRate.defaultWindow, asOf: Date = Date()) {
        let windowStartMs = Int64((asOf.addingTimeInterval(-window).timeIntervalSince1970 * 1_000).rounded())
        let asOfMs = Int64((asOf.timeIntervalSince1970 * 1_000).rounded())
        var samples = 0
        var output = 0
        var duration = 0.0
        for event in events {
            guard let durationMs = event.generationDurationMs,
                  let endMs = event.generationEndMs,
                  event.outputTokens > 0,
                  endMs >= windowStartMs, endMs < asOfMs,
                  event.sourcePath != UsageRepository.cursorRemoteSourcePath else {
                continue
            }
            samples += 1
            output += event.outputTokens
            duration += max(Double(durationMs) / 1_000.0, GenerationRate.minimumDurationSeconds)
        }
        self.window = window
        self.sampleCount = samples
        self.outputTokens = output
        self.totalDurationSeconds = duration
    }
}
