import Foundation
import Testing
@testable import TokenBarCore

struct BurnRateTests {
    private let referenceDate = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 12))!

    @Test
    func emptyInputYieldsZero() {
        let rate = BurnRate(events: [] as [UsageEvent], asOf: referenceDate)
        #expect(rate.totalTokens == 0)
        #expect(rate.tokensPerMinute == 0)
        #expect(rate.window == BurnRate.defaultWindow)
    }

    @Test
    func sumsAllFourTokenFieldsButNotReasoning() {
        let events = [
            event(
                timestamp: referenceDate.addingTimeInterval(-60),
                input: 100, output: 50, cacheRead: 30, cacheCreation: 20,
                reasoning: 999
            ),
        ]
        let rate = BurnRate(events: events, asOf: referenceDate)
        #expect(rate.totalTokens == 200)
    }

    @Test
    func tokensPerMinuteDividesByWindowMinutes() {
        let defaultWindow = BurnRate(
            events: [event(timestamp: referenceDate.addingTimeInterval(-60), input: 6000)],
            asOf: referenceDate
        )
        #expect(defaultWindow.tokensPerMinute == 600)

        let customWindow = BurnRate(
            events: [event(timestamp: referenceDate.addingTimeInterval(-60), input: 600)],
            asOf: referenceDate,
            window: 300
        )
        #expect(customWindow.tokensPerMinute == 120)
    }

    @Test
    func windowIsHalfOpenAroundAsOf() {
        let windowStart = referenceDate.addingTimeInterval(-BurnRate.defaultWindow)
        let events = [
            // Exactly at the window start: included.
            event(timestamp: windowStart, input: 10),
            // Just inside the window: included.
            event(timestamp: windowStart.addingTimeInterval(1), input: 10),
            // Older than the window: excluded.
            event(timestamp: windowStart.addingTimeInterval(-1), input: 1000),
            // Exactly at asOf: excluded (half-open [start, asOf)).
            event(timestamp: referenceDate, input: 1000),
            // Future-dated: excluded.
            event(timestamp: referenceDate.addingTimeInterval(60), input: 1000),
        ]
        let rate = BurnRate(events: events, asOf: referenceDate)
        #expect(rate.totalTokens == 20)
    }

    @Test
    func cursorRemoteEventsExcludedEvenInWindow() {
        let events = [
            event(
                timestamp: referenceDate.addingTimeInterval(-60),
                input: 500,
                sourcePath: UsageRepository.cursorRemoteSourcePath
            ),
            event(timestamp: referenceDate.addingTimeInterval(-60), input: 100),
        ]
        let rate = BurnRate(events: events, asOf: referenceDate)
        #expect(rate.totalTokens == 100)
    }

    @Test
    func distantPastTimestampsNeverSatisfyWindow() {
        let rate = BurnRate(
            events: [event(timestamp: .distantPast, input: 10_000)],
            asOf: referenceDate
        )
        #expect(rate.totalTokens == 0)
        #expect(rate.tokensPerMinute == 0)
    }

    // MARK: - helpers

    private func event(
        timestamp: Date,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        reasoning: Int? = nil,
        sourcePath: String = "/tmp/source.jsonl"
    ) -> UsageEvent {
        UsageEvent(
            id: "burn-\(UUID().uuidString)",
            agent: .codex,
            projectPath: "/tmp/proj",
            projectName: "proj",
            sessionId: "s1",
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            reasoningTokens: reasoning,
            sourcePath: sourcePath,
            parser: .codex,
            confidence: 1
        )
    }
}
