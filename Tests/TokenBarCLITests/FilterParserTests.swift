import Foundation
import Testing
@testable import TokenBarCLI
import TokenBarCore

struct FilterParserTests {
    @Test
    func parseAgentExactRawValue() throws {
        let agent = try FilterParser.parseAgent("codex")
        #expect(agent == .codex)
    }

    @Test
    func parseAgentFuzzyCase() throws {
        let agent = try FilterParser.parseAgent("ClaudeCode")
        #expect(agent == .claudeCode)
    }

    @Test
    func parseAgentByDisplayName() throws {
        let agent = try FilterParser.parseAgent("Claude Code")
        #expect(agent == .claudeCode)
    }

    @Test
    func parseAgentUnknownRejected() throws {
        do {
            _ = try FilterParser.parseAgent("bogus-agent")
            #expect(Bool(false), "expected error")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("Unknown agent"))
        }
    }

    @Test
    func parseGroupBySingle() throws {
        let dims = try FilterParser.parseGroupBy("project")
        #expect(dims == [.project])
    }

    @Test
    func parseGroupByMulti() throws {
        let dims = try FilterParser.parseGroupBy("project,agent,day")
        #expect(dims == [.project, .agent, .day])
    }

    @Test
    func parseGroupByDedupes() throws {
        let dims = try FilterParser.parseGroupBy("project,project,agent")
        #expect(dims == [.project, .agent])
    }

    @Test
    func parseGroupByUnknownRejected() throws {
        do {
            _ = try FilterParser.parseGroupBy("project,bogus")
            #expect(Bool(false), "expected error")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("Unknown --group-by dimension"))
        }
    }

    @Test
    func parseBucketKnown() throws {
        #expect((try FilterParser.parseBucket("day")) == .day)
        #expect((try FilterParser.parseBucket("hour")) == .hour)
        #expect((try FilterParser.parseBucket("hour-of-day")) == .hourOfDay)
    }

    @Test
    func parseBucketUnknownRejected() throws {
        do {
            _ = try FilterParser.parseBucket("week")
            #expect(Bool(false), "expected error")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("Unknown --bucket"))
        }
    }

    @Test
    func resolveWindowFromDays() throws {
        var options = FilterOptions()
        options.days = 7
        options.daysExplicit = true
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        try FilterParser.resolveWindow(&options, now: now)
        #expect(options.resolvedEnd == nil) // open-ended through now
        if let start = options.resolvedStart {
            let expected = Calendar.current.date(byAdding: .day, value: -7, to: now)!
            #expect(abs(start.timeIntervalSince(expected)) < 1)
        } else {
            #expect(Bool(false), "expected resolvedStart")
        }
    }

    @Test
    func resolveWindowAllTimeWhenDaysZero() throws {
        var options = FilterOptions()
        options.days = 0
        try FilterParser.resolveWindow(&options)
        #expect(options.resolvedStart == nil)
        #expect(options.resolvedEnd == nil)
    }

    @Test
    func resolveWindowFromDay() throws {
        var options = FilterOptions()
        options.day = "2026-05-20"
        try FilterParser.resolveWindow(&options)
        let start = options.resolvedStart
        let end = options.resolvedEnd
        #expect(start != nil)
        #expect(end != nil)
        if let s = start, let e = end {
            #expect(Calendar.current.date(byAdding: .day, value: 1, to: s) == e)
        }
    }

    @Test
    func resolveWindowFromSinceUntil() throws {
        var options = FilterOptions()
        let formatter = ISO8601DateFormatter()
        options.since = formatter.date(from: "2026-05-10T00:00:00Z")
        options.until = formatter.date(from: "2026-05-15T00:00:00Z")
        try FilterParser.resolveWindow(&options)
        #expect(options.resolvedStart == options.since)
        #expect(options.resolvedEnd == options.until)
    }

    @Test
    func resolveWindowRejectsDaysAndSinceCombo() throws {
        var options = FilterOptions()
        let formatter = ISO8601DateFormatter()
        options.since = formatter.date(from: "2026-05-10T00:00:00Z")
        options.daysExplicit = true
        options.days = 7
        do {
            try FilterParser.resolveWindow(&options)
            #expect(Bool(false), "expected error")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("--days cannot be combined"))
        }
    }

    @Test
    func resolveWindowRejectsUntilBeforeSince() throws {
        var options = FilterOptions()
        let formatter = ISO8601DateFormatter()
        options.since = formatter.date(from: "2026-05-15T00:00:00Z")
        options.until = formatter.date(from: "2026-05-10T00:00:00Z")
        do {
            try FilterParser.resolveWindow(&options)
            #expect(Bool(false), "expected error")
        } catch let error as CLIError {
            #expect(error.localizedDescription.contains("must be later than"))
        }
    }

    @Test
    func dayOverridesSinceAndDays() throws {
        var options = FilterOptions()
        options.day = "2026-05-20"
        options.daysExplicit = true
        options.days = 7
        let formatter = ISO8601DateFormatter()
        options.since = formatter.date(from: "2026-01-01T00:00:00Z")
        try FilterParser.resolveWindow(&options)
        // --day wins; we should not see the since value reflected
        guard let start = options.resolvedStart, let end = options.resolvedEnd else {
            #expect(Bool(false), "expected resolved window")
            return
        }
        let calendar = Calendar.current
        let day = formatter.string(from: start)
        // Start is at local midnight on 2026-05-20, end one day later
        #expect(day.hasPrefix("2026-05-"))
        #expect(calendar.date(byAdding: .day, value: 1, to: start) == end)
    }
}
