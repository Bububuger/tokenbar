import Foundation
import Testing
@testable import TokenBarCore

struct ProviderCostIntegrationTests {
    @Test
    func storedCostsMatchAggregationWithReportedZeroAndMissingCosts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try UsageRepository(databaseURL: directory.appendingPathComponent("usage.sqlite"))
        let reference = Date(timeIntervalSince1970: 1_791_800_000)
        let calendar = Calendar(identifier: .gregorian)
        let values: [(AgentKind, Double?)] = [(.grok, 1), (.grok, nil), (.grok, 0), (.omp, 2), (.omp, nil), (.cursor, nil)]
        let events = values.enumerated().map { index, value in
            UsageEvent(
                id: "cost-\(index)", agent: value.0, projectPath: "/test", projectName: "test",
                sessionId: "session", timestamp: reference, inputTokens: 1_000_000,
                outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, reasoningTokens: nil,
                modelName: "model", actualCostUSD: value.1, sourcePath: "/test/session",
                parser: .sample, confidence: 1
            )
        }
        _ = try repository.insertCheckpoint(
            trigger: "cost-integration", startedAt: reference, endedAt: reference,
            events: events, prompts: [], nextWatermarks: [], warnings: [], error: nil
        )
        let snapshot = try repository.makeSnapshot(referenceDate: reference, calendar: calendar)
        let aggregated = UsageAggregator.makeSnapshot(from: events, referenceDate: reference, calendar: calendar)
        #expect(snapshot.estimatedCostToday.totalCost == 6)
        #expect(snapshot.estimatedCostToday == aggregated.estimatedCostToday)
        #expect(snapshot.estimatedCostLast30 == aggregated.estimatedCostLast30)
        #expect(try repository.allEvents().sorted { $0.id < $1.id }.map(\.actualCostUSD) == events.map(\.actualCostUSD))
        let range = try repository.rangeAggregate(
            start: reference.addingTimeInterval(-1), end: reference.addingTimeInterval(1), calendar: calendar
        )
        let rangeCost = range.rows.reduce(0.0) { total, row in
            total + (row.actualCostUSD ?? Double(row.summary.totalTokens) * row.agent.defaultCostPerMillionTokens / 1_000_000)
        }
        #expect(rangeCost == snapshot.estimatedCostToday.totalCost)
        #expect(range.rows.reduce(0) { $0 + $1.summary.totalTokens } == 6_000_000)
    }
}
