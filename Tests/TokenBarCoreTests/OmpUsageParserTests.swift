import Foundation
import Testing
@testable import TokenBarCore

struct OmpUsageParserTests {
    private func lines(_ raw: [String]) -> [JSONLLineRecord] {
        raw.enumerated().map { idx, text in
            JSONLLineRecord(text: text, lineNumber: idx + 1, startOffset: 0, endOffset: 0)
        }
    }

    @Test
    func parsesAssistantUsageWithReasoningTokensAndHeaderOnSecondLine() throws {
        let records = lines([
            // omp prepends a title entry before the version-3 session header
            #"{"type":"title","v":1,"title":"t","source":"auto","updatedAt":"2026-10-01T07:21:34.502Z"}"#,
            #"{"type":"session","version":3,"id":"sess-omp-1","timestamp":"2026-10-01T07:16:45.518Z","cwd":"/Users/me/work/observ"}"#,
            #"{"type":"model_change","timestamp":"2026-10-01T07:16:46.000Z","model":"swe-2"}"#,
            #"{"type":"message","id":"u1","timestamp":"2026-10-01T07:16:47.000Z","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"message","id":"m1","parentId":"u1","timestamp":"2026-10-01T07:16:48.937Z","message":{"role":"assistant","model":"swe-2","usage":{"input":120,"output":40,"cacheRead":300,"cacheWrite":0,"reasoningTokens":25,"totalTokens":460,"cost":{"input":0.0012,"output":0.0004,"cacheRead":0.0003,"cacheWrite":0,"total":0.0019}},"stopReason":"stop"}}"#,
        ])

        let result = PiUsageParser.parse(
            lines: records,
            fileURL: URL(fileURLWithPath: "/tmp/omp/sessions/-Users-me-work-observ/ts_sess-omp-1.jsonl"),
            dialect: .omp
        )

        #expect(result.warnings.isEmpty)
        #expect(result.events.count == 1)
        let e = result.events[0]
        #expect(e.agent == .omp)
        #expect(e.parser == .omp)
        #expect(e.projectPath == "/Users/me/work/observ")
        #expect(e.projectName == "observ")
        #expect(e.sessionId == "sess-omp-1")
        #expect(e.inputTokens == 120)
        #expect(e.outputTokens == 40)
        #expect(e.cacheReadTokens == 300)
        #expect(e.cacheCreationTokens == 0)
        #expect(e.reasoningTokens == 25)
        #expect(e.modelName == "swe-2")
        #expect(e.actualCostUSD == 0.0019)
        #expect(e.inputTokens + e.outputTokens + e.cacheTokens == 460)
    }

    @Test
    func preservesReportedZeroAndFallsBackOnlyWhenCostIsMissing() {
        let records = lines([
            #"{"type":"message","id":"zero","timestamp":"2026-10-01T07:16:48Z","message":{"role":"assistant","usage":{"input":10,"output":5,"cost":{"total":0}}}}"#,
            #"{"type":"message","id":"numeric","timestamp":"2026-10-01T07:16:49Z","message":{"role":"assistant","usage":{"input":10,"output":5,"cost":0.002}}}"#,
            #"{"type":"message","id":"missing","timestamp":"2026-10-01T07:16:50Z","message":{"role":"assistant","usage":{"input":10,"output":5}}}"#,
        ])
        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/omp/cost.jsonl"), dialect: .omp)
        #expect(result.events.map(\.actualCostUSD) == [0, 0.002, nil])
    }

    @Test
    func sessionContextFindsHeaderAfterTitleLine() throws {
        let records = lines([
            #"{"type":"title","v":1,"title":"t"}"#,
            #"{"type":"session","version":3,"id":"sess-ctx","timestamp":"2026-10-01T07:16:45.518Z","cwd":"/Users/me/proj"}"#,
            #"{"type":"message","id":"m1","timestamp":"2026-10-01T07:16:48.000Z","message":{"role":"assistant","model":"m","usage":{"input":5,"output":5,"cacheRead":0,"cacheWrite":0,"reasoningTokens":0,"totalTokens":10,"cost":0}}}"#,
        ])

        // No initial context passed: the parser must recover session/cwd from the
        // header on line 2, exactly like omp files laid out on disk.
        let result = PiUsageParser.parse(
            lines: records,
            fileURL: URL(fileURLWithPath: "/tmp/omp/sessions/-Users-me-proj/ts_x.jsonl"),
            dialect: .omp
        )
        #expect(result.events.count == 1)
        #expect(result.events[0].sessionId == "sess-ctx")
        #expect(result.events[0].projectName == "proj")
    }

    @Test
    func skipsOmpSpecificEntryTypesAndFailedTurns() throws {
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-10-01T07:16:45Z","cwd":"/p"}"#,
            // omp-only entry types never carry usage and must not produce events
            #"{"type":"custom","customType":"autoqa","timestamp":"2026-10-01T07:16:46Z"}"#,
            #"{"type":"custom_message","customType":"hook","timestamp":"2026-10-01T07:16:47Z","content":"x"}"#,
            #"{"type":"mode_change","mode":"code","timestamp":"2026-10-01T07:16:48Z"}"#,
            #"{"type":"message","id":"a1","timestamp":"2026-10-01T07:16:49Z","message":{"role":"developer","content":"sys"}}"#,
            // failed / aborted turns are skipped like pi's
            #"{"type":"message","id":"a2","timestamp":"2026-10-01T07:16:50Z","message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoningTokens":0,"totalTokens":15,"cost":0},"stopReason":"error"}}"#,
            #"{"type":"message","id":"a3","timestamp":"2026-10-01T07:16:51Z","message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoningTokens":0,"totalTokens":15,"cost":0},"stopReason":"aborted"}}"#,
        ])

        let result = PiUsageParser.parse(
            lines: records,
            fileURL: URL(fileURLWithPath: "/tmp/omp/s.jsonl"),
            dialect: .omp
        )
        #expect(result.events.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test
    func ompDialectDoesNotReadPiReasoningKey() throws {
        // A pi-shaped line (reasoning, no reasoningTokens) parsed as omp must
        // report zero reasoning rather than borrowing the pi field.
        let records = lines([
            #"{"type":"message","id":"m1","timestamp":"2026-10-01T07:16:48Z","message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":9,"totalTokens":15,"cost":0}}}"#,
        ])
        let result = PiUsageParser.parse(
            lines: records,
            fileURL: URL(fileURLWithPath: "/tmp/omp/s.jsonl"),
            dialect: .omp
        )
        #expect(result.events.count == 1)
        #expect(result.events[0].reasoningTokens == 0)
        #expect(result.events[0].projectName == "omp")
    }
}
