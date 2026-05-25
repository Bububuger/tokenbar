import Foundation
import Testing
@testable import TokenBarCore

/// CHECKLIST §2 P0 batch — data-layer guarantees.
/// Each test name is prefixed with the corresponding CL-/UT- id so failures
/// trace straight back to the deliverable.
struct Sprint10P0Tests {
    // MARK: - CL-P0-028 staged token formatting

    @Test
    func stagedTokensFollowsStaircase_CL_P0_028() {
        #expect(TokenBarNumberFormatting.stagedTokens(0) == "0")
        #expect(TokenBarNumberFormatting.stagedTokens(1) == "1")
        #expect(TokenBarNumberFormatting.stagedTokens(999) == "999")
        #expect(TokenBarNumberFormatting.stagedTokens(1_000) == "1K")
        #expect(TokenBarNumberFormatting.stagedTokens(1_500) == "1.5K")
        #expect(TokenBarNumberFormatting.stagedTokens(15_000) == "15K")
        #expect(TokenBarNumberFormatting.stagedTokens(999_999) == "1000K") // rounds within the K band
        #expect(TokenBarNumberFormatting.stagedTokens(1_500_000) == "1.5M")
        #expect(TokenBarNumberFormatting.stagedTokens(33_400_000) == "33M")
        #expect(TokenBarNumberFormatting.stagedTokens(1_500_000_000) == "1.5B")
        // Anything ≥ 999.5B caps to the sentinel string so the UI never wraps.
        #expect(TokenBarNumberFormatting.stagedTokens(1_500_000_000_000) == ">999B")
    }

    @Test
    func stagedTokensClampsNegativeInputs_CL_P0_028() {
        #expect(TokenBarNumberFormatting.stagedTokens(-1) == "0")
        #expect(TokenBarNumberFormatting.stagedTokens(-1_000_000) == "0")
    }

    @Test
    func clampNonNegativeFlagsTheTransition_CL_P0_029() {
        let positive = TokenBarNumberFormatting.clampNonNegative(123)
        #expect(positive.value == 123)
        #expect(positive.wasNegative == false)

        let zero = TokenBarNumberFormatting.clampNonNegative(0)
        #expect(zero.value == 0)
        #expect(zero.wasNegative == false)

        let negative = TokenBarNumberFormatting.clampNonNegative(-42)
        #expect(negative.value == 0)
        #expect(negative.wasNegative == true)
    }

    // MARK: - CL-P0-029 parser defends against negative tokens

    @Test
    func claudeParserClampsNegativeTokens_CL_P0_029() throws {
        let jsonl = """
        {"sessionId":"s1","timestamp":"2026-05-18T10:00:00.000Z","cwd":"/tmp/proj","message":{"model":"claude-x","usage":{"input_tokens":-5,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let url = try writeTempJSONL(jsonl)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ClaudeUsageParser.parse(fileURL: url, fallbackProjectSlug: "proj")
        #expect(result.events.count == 1)
        #expect(result.events[0].inputTokens == 0)        // clamped
        #expect(result.events[0].outputTokens == 10)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message == "negative token count clamped to 0")
    }

    @Test
    func codexParserClampsNegativeTokens_CL_P0_029() throws {
        let jsonl = """
        {"type":"session_meta","timestamp":"2026-05-18T10:00:00.000Z","payload":{"id":"sess","cwd":"/tmp/proj","model":"gpt"}}
        {"type":"event_msg","timestamp":"2026-05-18T10:00:01.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":-7,"cached_input_tokens":0,"output_tokens":20}}}}
        """
        let url = try writeTempJSONL(jsonl)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try CodexUsageParser.parse(fileURL: url)
        #expect(result.events.count == 1)
        #expect(result.events[0].inputTokens == 0)
        #expect(result.events[0].outputTokens == 20)
        #expect(result.warnings.contains { $0.message == "negative token count clamped to 0" })
    }

    // MARK: - CL-P0-031 Int64 safety: very large single event aggregates without overflow

    @Test
    func aggregatorHandlesMillionTokenEventsWithoutOverflow_CL_P0_031() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 12))!
        let big = 1_000_000_000  // 1 B tokens
        let events: [UsageEvent] = (0..<5).map { idx in
            UsageEvent(
                id: "big-\(idx)",
                agent: .codex,
                projectPath: "/tmp/proj",
                projectName: "proj",
                sessionId: "s-\(idx)",
                timestamp: referenceDate,
                inputTokens: big,
                outputTokens: big,
                cacheReadTokens: big,
                cacheCreationTokens: 0,
                reasoningTokens: nil,
                sourcePath: "/tmp/\(idx).jsonl",
                parser: .codex,
                confidence: 1
            )
        }
        let snapshot = UsageAggregator.makeSnapshot(from: events, referenceDate: referenceDate, calendar: calendar)
        #expect(snapshot.today.inputTokens == big * 5)
        #expect(snapshot.today.totalTokens == big * 15)
    }

    // MARK: - CL-P0-024 cross-file sessionId merges into one recent session

    @Test
    func projectDetailMergesSessionAcrossFiles_CL_P0_024() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 12))!
        let shared = "shared-session"
        let events = [
            UsageEvent(
                id: "/tmp/file-a.jsonl#1",
                agent: .codex,
                projectPath: "/tmp/proj",
                projectName: "proj",
                sessionId: shared,
                timestamp: referenceDate.addingTimeInterval(-3600),
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: nil,
                sourcePath: "/tmp/file-a.jsonl",
                parser: .codex,
                confidence: 1
            ),
            UsageEvent(
                id: "/tmp/file-b.jsonl#1",
                agent: .codex,
                projectPath: "/tmp/proj",
                projectName: "proj",
                sessionId: shared,
                timestamp: referenceDate,
                inputTokens: 50,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                reasoningTokens: nil,
                sourcePath: "/tmp/file-b.jsonl",
                parser: .codex,
                confidence: 1
            ),
        ]

        let detail = UsageAggregator.makeProjectDetail(
            projectName: "proj",
            from: events,
            referenceDate: referenceDate,
            calendar: calendar
        )

        #expect(detail != nil)
        #expect(detail?.recentSessions.count == 1)
        #expect(detail?.recentSessions.first?.sessionId == shared)
        #expect(detail?.recentSessions.first?.summary.totalTokens == 150)
    }

    // MARK: - CL-P0-023 DST fall-back: both 1AM wall-clock events land in hourOfDay==1

    @Test
    func hourOfDayCollapsesAcrossDSTFallBack_CL_P0_023() {
        guard let tz = TimeZone(identifier: "America/Los_Angeles") else {
            // Skip silently when the zoneinfo is unavailable on the test host.
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        let referenceDate = calendar.date(from: DateComponents(timeZone: tz, year: 2026, month: 11, day: 1, hour: 23))!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let beforeFallBack = formatter.date(from: "2026-11-01T08:30:00.000Z")!
        let afterFallBack = formatter.date(from: "2026-11-01T09:30:00.000Z")!

        let events = [
            UsageEvent(
                id: "dst-1", agent: .codex, projectPath: nil, projectName: "proj", sessionId: "s1",
                timestamp: beforeFallBack, inputTokens: 100, outputTokens: 0, cacheReadTokens: 0,
                cacheCreationTokens: 0, reasoningTokens: nil, sourcePath: "/tmp/a.jsonl", parser: .codex, confidence: 1
            ),
            UsageEvent(
                id: "dst-2", agent: .codex, projectPath: nil, projectName: "proj", sessionId: "s2",
                timestamp: afterFallBack, inputTokens: 50, outputTokens: 0, cacheReadTokens: 0,
                cacheCreationTokens: 0, reasoningTokens: nil, sourcePath: "/tmp/b.jsonl", parser: .codex, confidence: 1
            ),
        ]

        let snapshot = UsageAggregator.makeHourlySnapshot(
            from: events,
            referenceDate: referenceDate,
            calendar: calendar,
            days: 1
        )

        // Both wall-clock 1AM events collapse into the same hour-of-day bucket.
        let hourOne = snapshot.hoursOfDay.first { $0.hourOfDay == 1 }
        #expect(hourOne?.summary.totalTokens == 150)
    }

    // MARK: - CL-P0-022 snapshot.warningCount is single source of truth (via UsageStore)

    @Test
    func snapshotCopyPreservesAllFieldsWithUpdatedWarningCount_CL_P0_022() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 18, hour: 9))!
        let base = UsageAggregator.makeSnapshot(from: [], referenceDate: referenceDate, calendar: calendar)
        #expect(base.warningCount == 0)
        let copy = base.with(warningCount: 7)
        #expect(copy.warningCount == 7)
        #expect(copy.generatedAt == base.generatedAt)
        #expect(copy.today == base.today)
        #expect(copy.last30Days == base.last30Days)
        #expect(copy.estimatedCostLast30 == base.estimatedCostLast30)
    }

    // MARK: - helpers

    private func writeTempJSONL(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprint10-\(UUID().uuidString).jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
