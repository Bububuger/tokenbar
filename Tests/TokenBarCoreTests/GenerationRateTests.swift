import Foundation
import Testing
@testable import TokenBarCore

struct GenerationRateTests {
    private let referenceDate = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 12))!

    @Test
    func emptyInputYieldsNilRate() {
        let rate = GenerationRate(events: [] as [UsageEvent], asOf: referenceDate)
        #expect(rate.sampleCount == 0)
        #expect(rate.tokensPerSecond == nil)
    }

    @Test
    func singleSampleDividesOutputByDuration() {
        let events = [
            event(output: 300, startMs: ms(referenceDate, offset: -61_000), endMs: ms(referenceDate, offset: -58_000)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 1)
        #expect(rate.tokensPerSecond == 100)
    }

    @Test
    func subHalfSecondResponseFallsToFloor() {
        let events = [
            event(output: 100, startMs: ms(referenceDate, offset: -1_000), endMs: ms(referenceDate, offset: -800)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.totalDurationSeconds == 0.5)
        #expect(rate.tokensPerSecond == 200)
    }

    @Test
    func missingStartOrEndContributesNoSample() {
        let events = [
            event(output: 100, startMs: nil, endMs: ms(referenceDate, offset: -1_000)),
            event(output: 100, startMs: ms(referenceDate, offset: -2_000), endMs: nil),
            event(output: 100),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 0)
        #expect(rate.tokensPerSecond == nil)
    }

    @Test
    func nonPositiveIntervalIsExcluded() {
        let events = [
            event(output: 100, startMs: ms(referenceDate, offset: -1_000), endMs: ms(referenceDate, offset: -1_000)),
            event(output: 100, startMs: ms(referenceDate, offset: -1_000), endMs: ms(referenceDate, offset: -2_000)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 0)
        #expect(rate.tokensPerSecond == nil)
    }

    @Test
    func zeroOutputResponsesAreExcluded() {
        let events = [
            event(output: 0, startMs: ms(referenceDate, offset: -2_000), endMs: ms(referenceDate, offset: -1_000)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 0)
        #expect(rate.tokensPerSecond == nil)
    }

    @Test
    func windowMembershipIsHalfOpenOnEndTime() {
        let windowStart = referenceDate.addingTimeInterval(-GenerationRate.defaultWindow)
        let events = [
            // Ends exactly at windowStart → included.
            event(output: 10, startMs: ms(windowStart, offset: -1_000), endMs: ms(windowStart, offset: 0)),
            // Ends before windowStart → excluded.
            event(output: 1_000, startMs: ms(windowStart, offset: -2_000), endMs: ms(windowStart, offset: -1)),
            // Ends exactly at asOf → excluded.
            event(output: 1_000, startMs: ms(referenceDate, offset: -1_000), endMs: ms(referenceDate, offset: 0)),
            // Ends after asOf → excluded.
            event(output: 1_000, startMs: ms(referenceDate, offset: -1_000), endMs: ms(referenceDate, offset: 60_000)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 1)
        #expect(rate.outputTokens == 10)
    }

    @Test
    func cursorRemoteEventsExcludedEvenInWindow() {
        let events = [
            event(
                output: 500,
                startMs: ms(referenceDate, offset: -2_000),
                endMs: ms(referenceDate, offset: -1_000),
                sourcePath: UsageRepository.cursorRemoteSourcePath
            ),
            event(output: 100, startMs: ms(referenceDate, offset: -2_000), endMs: ms(referenceDate, offset: -1_000)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 1)
        #expect(rate.tokensPerSecond == 100)
    }

    @Test
    func outputWeightedAcrossSamples() {
        let events = [
            event(output: 200, startMs: ms(referenceDate, offset: -3_000), endMs: ms(referenceDate, offset: -1_000)),
            event(output: 300, startMs: ms(referenceDate, offset: -4_000), endMs: ms(referenceDate, offset: -1_000)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 2)
        #expect(rate.totalDurationSeconds == 5)
        #expect(rate.tokensPerSecond == 100)
    }

    @Test
    func allSamplesOutsideWindowYieldNil() {
        let events = [
            event(output: 100, startMs: ms(referenceDate, offset: -900_000), endMs: ms(referenceDate, offset: -800_000)),
        ]
        let rate = GenerationRate(events: events, asOf: referenceDate)
        #expect(rate.sampleCount == 0)
        #expect(rate.tokensPerSecond == nil)
    }

    private func ms(_ date: Date, offset: Int64) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded()) + offset
    }

    private func event(
        output: Int,
        startMs: Int64? = nil,
        endMs: Int64? = nil,
        sourcePath: String = "/tmp/source.jsonl"
    ) -> UsageEvent {
        UsageEvent(
            id: "gen-\(UUID().uuidString)",
            agent: .codex,
            projectPath: "/tmp/proj",
            projectName: "proj",
            sessionId: "s1",
            timestamp: referenceDate,
            inputTokens: 0,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            sourcePath: sourcePath,
            parser: .codex,
            confidence: 1,
            generationStartMs: startMs,
            generationEndMs: endMs
        )
    }
}
