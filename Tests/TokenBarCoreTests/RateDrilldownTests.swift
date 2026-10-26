import Foundation
import Testing
@testable import TokenBarCore

struct RateDrilldownTests {
    private let referenceDate = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 12))!

    // (a) Empty input.
    @Test
    func emptyInputYieldsNoSlices() {
        #expect(RateDrilldown.makeSlices(events: [], asOf: referenceDate).isEmpty)
    }

    // (b) One agent with two models → agent slice + one slice per model.
    @Test
    func agentWithTwoModelsYieldsThreeSlices() {
        let events = [
            event(agent: .codex, model: "gpt-5", input: 100, output: 50,
                  startMs: ms(referenceDate, offset: -4_000), endMs: ms(referenceDate, offset: -2_000)),
            event(agent: .codex, model: "gpt-5", input: 60, output: 40,
                  startMs: ms(referenceDate, offset: -3_000), endMs: ms(referenceDate, offset: -1_000)),
            event(agent: .codex, model: "gpt-5-mini", input: 30, output: 20,
                  startMs: ms(referenceDate, offset: -2_000), endMs: ms(referenceDate, offset: -1_000)),
        ]
        let slices = RateDrilldown.makeSlices(events: events, asOf: referenceDate)

        #expect(slices.count == 3)
        #expect(slices.map(\.modelName) == [nil, "gpt-5", "gpt-5-mini"])
        #expect(slices.allSatisfy { $0.agent == .codex })

        let agentSlice = slices[0]
        #expect(agentSlice.eventCount == 3)
        #expect(agentSlice.burn.totalTokens == 300)
        #expect(agentSlice.burn.tokensPerMinute == 30)
        #expect(agentSlice.generation.sampleCount == 3)
        #expect(agentSlice.generation.outputTokens == 110)
        // Durations 2s + 2s + 1s → 110 output tokens / 5s.
        #expect(agentSlice.generation.tokensPerSecond == 22)

        let gpt5 = slices[1]
        #expect(gpt5.eventCount == 2)
        #expect(gpt5.burn.totalTokens == 250)
        #expect(gpt5.generation.sampleCount == 2)
        #expect(gpt5.generation.outputTokens == 90)
        #expect(gpt5.generation.tokensPerSecond == 90.0 / 4.0)

        let mini = slices[2]
        #expect(mini.eventCount == 1)
        #expect(mini.burn.totalTokens == 50)
        #expect(mini.generation.sampleCount == 1)
        #expect(mini.generation.tokensPerSecond == 20)
    }

    // (c) Agent whose events carry no modelName → agent slice only.
    @Test
    func unattributedAgentYieldsAgentSliceOnly() {
        let events = [
            event(agent: .geminiCLI, input: 10),
            event(agent: .geminiCLI, input: 20),
        ]
        let slices = RateDrilldown.makeSlices(events: events, asOf: referenceDate)

        #expect(slices.count == 1)
        #expect(slices[0].agent == .geminiCLI)
        #expect(slices[0].modelName == nil)
        #expect(slices[0].eventCount == 2)
        #expect(slices[0].burn.totalTokens == 30)
    }

    // (d) Mixed attribution — model slices come only from attributed events;
    // the agent slice still covers every event.
    @Test
    func mixedAttributionKeepsAgentSliceOverAllEvents() {
        let events = [
            event(agent: .claudeCode, model: "sonnet", output: 40),
            event(agent: .claudeCode, output: 60),
        ]
        let slices = RateDrilldown.makeSlices(events: events, asOf: referenceDate)

        #expect(slices.count == 2)
        #expect(slices.map(\.modelName) == [nil, "sonnet"])
        #expect(slices[0].eventCount == 2)
        #expect(slices[0].burn.totalTokens == 100)
        #expect(slices[1].eventCount == 1)
        #expect(slices[1].burn.totalTokens == 40)
    }

    // (e) Cursor remote-account events are excluded entirely.
    @Test
    func cursorRemoteEventsProduceNoSlices() {
        let remote = UsageRepository.cursorRemoteSourcePath
        let onlyRemote = [
            event(agent: .cursor, model: "remote-model", output: 500, sourcePath: remote),
        ]
        #expect(RateDrilldown.makeSlices(events: onlyRemote, asOf: referenceDate).isEmpty)

        let mixed = [
            event(agent: .cursor, model: "remote-model", output: 500, sourcePath: remote),
            event(agent: .cursor, model: "local-model", output: 100),
        ]
        let slices = RateDrilldown.makeSlices(events: mixed, asOf: referenceDate)
        #expect(slices.count == 2)
        #expect(slices.map(\.modelName) == [nil, "local-model"])
        #expect(slices[0].eventCount == 1)
        #expect(slices[0].burn.totalTokens == 100)
    }

    // (f) Out-of-window events produce no slice — unless generationEndMs
    // lands inside the window (rate membership is per-rate).
    @Test
    func eventsOutsideWindowProduceNoSlices() {
        let stale = [
            event(agent: .codex,
                  timestamp: referenceDate.addingTimeInterval(-3_600),
                  output: 1_000),
            event(agent: .codex,
                  timestamp: referenceDate.addingTimeInterval(-3_600),
                  output: 1_000,
                  startMs: ms(referenceDate, offset: -3_000_000),
                  endMs: ms(referenceDate, offset: -700_000)),
        ]
        #expect(RateDrilldown.makeSlices(events: stale, asOf: referenceDate).isEmpty)
    }

    @Test
    func generationEndInsideWindowMakesEventRelevant() {
        // Timestamp predates the window but the response ended 10s ago:
        // burn ignores it, generation counts it — exactly what makes the
        // drilldown differ from a timestamp-only filter.
        let events = [
            event(agent: .codex,
                  timestamp: referenceDate.addingTimeInterval(-3_600),
                  output: 90,
                  startMs: ms(referenceDate, offset: -13_000),
                  endMs: ms(referenceDate, offset: -10_000)),
        ]
        let slices = RateDrilldown.makeSlices(events: events, asOf: referenceDate)
        #expect(slices.count == 1)
        #expect(slices[0].eventCount == 1)
        #expect(slices[0].burn.totalTokens == 0)
        #expect(slices[0].generation.sampleCount == 1)
        #expect(slices[0].generation.tokensPerSecond == 30)
    }

    // (g) Deterministic ordering: agents by rawValue, agent slice before
    // model slices, models by name ascending.
    @Test
    func sliceOrderingIsDeterministic() {
        let events = [
            event(agent: .warp, model: "zeta", output: 1),
            event(agent: .codex, model: "b-model", output: 1),
            event(agent: .warp, output: 1),
            event(agent: .claudeCode, output: 1),
            event(agent: .codex, model: "a-model", output: 1),
            event(agent: .warp, model: "alpha", output: 1),
            event(agent: .codex, output: 1),
        ]
        let slices = RateDrilldown.makeSlices(events: events, asOf: referenceDate)

        #expect(slices.map { "\($0.agent.rawValue):\($0.modelName ?? "*")" } == [
            "claudeCode:*",
            "codex:*",
            "codex:a-model",
            "codex:b-model",
            "warp:*",
            "warp:alpha",
            "warp:zeta",
        ])
    }

    // (h) Generation slices exclude untimed events while eventCount and
    // burn still cover them.
    @Test
    func untimedEventsCountedInSliceButNotInGeneration() {
        let events = [
            event(agent: .codex, output: 100,
                  startMs: ms(referenceDate, offset: -2_000), endMs: ms(referenceDate, offset: -1_000)),
            event(agent: .codex, output: 300),
        ]
        let slices = RateDrilldown.makeSlices(events: events, asOf: referenceDate)
        #expect(slices.count == 1)
        let slice = slices[0]
        #expect(slice.eventCount == 2)
        #expect(slice.burn.totalTokens == 400)
        #expect(slice.generation.sampleCount == 1)
        #expect(slice.generation.outputTokens == 100)
        #expect(slice.generation.tokensPerSecond == 100)
    }

    @Test
    func futureAndBoundaryEventsAreNotRelevant() {
        let events = [
            event(agent: .codex, timestamp: referenceDate, output: 1_000),
            event(agent: .codex, timestamp: referenceDate.addingTimeInterval(60), output: 1_000),
        ]
        #expect(RateDrilldown.makeSlices(events: events, asOf: referenceDate).isEmpty)
    }

    private func ms(_ date: Date, offset: Int64) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded()) + offset
    }

    private func event(
        agent: AgentKind = .codex,
        model: String? = nil,
        timestamp: Date? = nil,
        input: Int = 0,
        output: Int = 0,
        startMs: Int64? = nil,
        endMs: Int64? = nil,
        sourcePath: String = "/tmp/source.jsonl"
    ) -> UsageEvent {
        UsageEvent(
            id: "drill-\(UUID().uuidString)",
            agent: agent,
            projectPath: "/tmp/proj",
            projectName: "proj",
            sessionId: "s1",
            timestamp: timestamp ?? referenceDate.addingTimeInterval(-60),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            modelName: model,
            sourcePath: sourcePath,
            parser: .codex,
            confidence: 1,
            generationStartMs: startMs,
            generationEndMs: endMs
        )
    }
}
