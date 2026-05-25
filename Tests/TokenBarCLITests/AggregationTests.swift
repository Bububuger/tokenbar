import Foundation
import Testing
@testable import TokenBarCLI
import TokenBarCore

struct AggregationTests {
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static let dayA: Date = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-05-20T10:00:00Z")!
    }()

    private static let dayB: Date = {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: "2026-05-21T15:00:00Z")!
    }()

    private func makeEvent(
        id: String,
        agent: AgentKind,
        project: String,
        model: String?,
        input: Int,
        output: Int,
        cache: Int,
        date: Date,
        session: String = "s1"
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            agent: agent,
            projectPath: "/tmp/\(project)",
            projectName: project,
            sessionId: session,
            timestamp: date,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cache,
            cacheCreationTokens: 0,
            reasoningTokens: nil,
            modelName: model,
            sourcePath: "/tmp/\(project)/source",
            parser: .sample,
            confidence: 1.0
        )
    }

    @Test
    func emptyGroupByYieldsSingleGlobalRow() throws {
        let events = [
            makeEvent(id: "1", agent: .codex, project: "p1", model: "m1", input: 100, output: 50, cache: 20, date: Self.dayA),
            makeEvent(id: "2", agent: .claudeCode, project: "p2", model: "m2", input: 200, output: 100, cache: 40, date: Self.dayA),
        ]
        let rows = Aggregation.aggregate(events: events, prompts: [], groupBy: [], calendar: Self.calendar)
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.inputTokens == 300)
        #expect(row.outputTokens == 150)
        #expect(row.cacheTokens == 60)
        #expect(row.totalTokens == 510)
        #expect(row.eventCount == 2)
        #expect(row.keys.isEmpty)
    }

    @Test
    func groupByProjectSumsCorrectly() throws {
        let events = [
            makeEvent(id: "1", agent: .codex, project: "alpha", model: "m1", input: 100, output: 0, cache: 0, date: Self.dayA),
            makeEvent(id: "2", agent: .codex, project: "alpha", model: "m1", input: 50, output: 0, cache: 0, date: Self.dayA),
            makeEvent(id: "3", agent: .codex, project: "beta", model: "m1", input: 200, output: 0, cache: 0, date: Self.dayA),
        ]
        let rows = Aggregation.aggregate(events: events, prompts: [], groupBy: [.project], calendar: Self.calendar)
        #expect(rows.count == 2)
        let alpha = rows.first(where: { $0.keys["project"]?.asString == "alpha" })
        let beta = rows.first(where: { $0.keys["project"]?.asString == "beta" })
        #expect(alpha?.inputTokens == 150)
        #expect(alpha?.eventCount == 2)
        #expect(beta?.inputTokens == 200)
        #expect(beta?.eventCount == 1)
    }

    @Test
    func groupByProjectAgentProducesTupleKeys() throws {
        let events = [
            makeEvent(id: "1", agent: .codex, project: "alpha", model: nil, input: 100, output: 0, cache: 0, date: Self.dayA),
            makeEvent(id: "2", agent: .claudeCode, project: "alpha", model: nil, input: 50, output: 0, cache: 0, date: Self.dayA),
            makeEvent(id: "3", agent: .codex, project: "beta", model: nil, input: 200, output: 0, cache: 0, date: Self.dayA),
        ]
        let rows = Aggregation.aggregate(events: events, prompts: [], groupBy: [.project, .agent], calendar: Self.calendar)
        #expect(rows.count == 3)
        let alphaCodex = rows.first {
            $0.keys["project"]?.asString == "alpha" && $0.keys["agent"]?.asString == "codex"
        }
        #expect(alphaCodex?.inputTokens == 100)
        let alphaClaude = rows.first {
            $0.keys["project"]?.asString == "alpha" && $0.keys["agent"]?.asString == "claudeCode"
        }
        #expect(alphaClaude?.inputTokens == 50)
    }

    @Test
    func groupByDayProducesPerDayRows() throws {
        let events = [
            makeEvent(id: "1", agent: .codex, project: "p", model: nil, input: 100, output: 0, cache: 0, date: Self.dayA),
            makeEvent(id: "2", agent: .codex, project: "p", model: nil, input: 200, output: 0, cache: 0, date: Self.dayB),
        ]
        let rows = Aggregation.aggregate(events: events, prompts: [], groupBy: [.day], calendar: Self.calendar)
        #expect(rows.count == 2)
        let dayKeys = Set(rows.compactMap { $0.keys["day"]?.asString })
        #expect(dayKeys == ["2026-05-20", "2026-05-21"])
    }

    @Test
    func aggregateTimelineDayBuckets() throws {
        let events = [
            makeEvent(id: "1", agent: .codex, project: "p", model: nil, input: 100, output: 0, cache: 0, date: Self.dayA),
            makeEvent(id: "2", agent: .codex, project: "p", model: nil, input: 200, output: 0, cache: 0, date: Self.dayB),
        ]
        let buckets = Aggregation.aggregateTimeline(
            events: events, prompts: [], bucket: .day, groupBy: [], calendar: Self.calendar
        )
        #expect(buckets.count == 2)
        #expect(buckets[0].label < buckets[1].label) // chronological order
        #expect(buckets.map(\.totalTokens) == [100, 200])
    }

    @Test
    func aggregateTimelineHourOfDayCollapsesAcrossDays() throws {
        // Two events at 10:00 on different days collapse into one bucket
        let formatter = ISO8601DateFormatter()
        let dayATenAm = formatter.date(from: "2026-05-20T10:00:00Z")!
        let dayBTenAm = formatter.date(from: "2026-05-21T10:00:00Z")!
        let events = [
            makeEvent(id: "1", agent: .codex, project: "p", model: nil, input: 100, output: 0, cache: 0, date: dayATenAm),
            makeEvent(id: "2", agent: .codex, project: "p", model: nil, input: 200, output: 0, cache: 0, date: dayBTenAm),
        ]
        let buckets = Aggregation.aggregateTimeline(
            events: events, prompts: [], bucket: .hourOfDay, groupBy: [], calendar: Self.calendar
        )
        #expect(buckets.count == 1)
        #expect(buckets[0].totalTokens == 300)
        #expect(buckets[0].hourOfDay == 10)
    }

    @Test
    func costEstimatorMultipliesByAgentDefaultRate() throws {
        // codex default = $4.46 per million tokens
        let events = [
            makeEvent(id: "1", agent: .codex, project: "p", model: nil, input: 1_000_000, output: 0, cache: 0, date: Self.dayA),
        ]
        let cost = CostEstimator.estimate(events: events)
        #expect(abs(cost - 4.46) < 0.0001)
    }
}
