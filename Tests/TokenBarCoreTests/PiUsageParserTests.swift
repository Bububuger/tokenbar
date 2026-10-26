import Foundation
import Testing
@testable import TokenBarCore

struct PiUsageParserTests {
    private func lines(_ raw: [String]) -> [JSONLLineRecord] {
        raw.enumerated().map { idx, text in
            JSONLLineRecord(text: text, lineNumber: idx + 1, startOffset: 0, endOffset: 0)
        }
    }

    @Test
    func parsesAssistantUsageWithHeaderCwdAndModel() throws {
        let records = lines([
            #"{"type":"session","version":3,"id":"sess-1","timestamp":"2026-05-30T10:00:00.000Z","cwd":"/Users/me/work/myproject"}"#,
            #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-05-30T10:00:01.000Z","message":{"role":"assistant","model":"gpt-5","usage":{"input":120,"output":40,"cacheRead":300,"cacheWrite":50,"totalTokens":510},"stopReason":"endTurn","timestamp":1780178401000}}"#,
        ])

        let result = PiUsageParser.parse(
            lines: records,
            fileURL: URL(fileURLWithPath: "/tmp/pi/sessions/--Users-me-work-myproject--/ts_sess-1.jsonl")
        )

        #expect(result.warnings.isEmpty)
        #expect(result.events.count == 1)
        let e = result.events[0]
        #expect(e.agent == .pi)
        #expect(e.parser == .pi)
        #expect(e.projectPath == "/Users/me/work/myproject")
        #expect(e.projectName == "myproject")
        #expect(e.sessionId == "sess-1")
        #expect(e.inputTokens == 120)
        #expect(e.outputTokens == 40)
        #expect(e.cacheReadTokens == 300)
        #expect(e.cacheCreationTokens == 50)
        #expect(e.cacheTokens == 350)
        #expect(e.modelName == "gpt-5")
        // message.timestamp is unix-ms → 1780178401.0s
        #expect(abs(e.timestamp.timeIntervalSince1970 - 1780178401.0) < 0.001)
    }

    @Test
    func skipsAbortedAndErroredAndNonAssistantTurns() throws {
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-05-30T10:00:00Z","cwd":"/p"}"#,
            #"{"type":"message","id":"u1","timestamp":1780178400000,"message":{"role":"user","content":"hi"}}"#,
            #"{"type":"message","id":"a1","timestamp":1780178401000,"message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0},"stopReason":"aborted"}}"#,
            #"{"type":"message","id":"a2","timestamp":1780178402000,"message":{"role":"assistant","model":"m","usage":{"input":7,"output":3,"cacheRead":0,"cacheWrite":0},"stopReason":"error"}}"#,
        ])

        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/pi/s.jsonl"))
        #expect(result.events.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test
    func skipsZeroUsageAndWarnsOnMissingTimestamp() throws {
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-05-30T10:00:00Z","cwd":"/p"}"#,
            // zero usage → skipped silently
            #"{"type":"message","id":"a1","timestamp":1780178401000,"message":{"role":"assistant","model":"m","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}}"#,
            // non-zero usage but no timestamp anywhere → warning
            #"{"type":"message","id":"a2","message":{"role":"assistant","model":"m","usage":{"input":5,"output":5,"cacheRead":0,"cacheWrite":0}}}"#,
        ])

        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/pi/s.jsonl"))
        #expect(result.events.isEmpty)
        #expect(result.warnings.count == 1)
    }

    @Test
    func surfacesReasoningField() throws {
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-05-30T10:00:00Z","cwd":"/p"}"#,
            #"{"type":"message","id":"a1","timestamp":1780178401000,"message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"reasoning":7,"totalTokens":15,"cost":0}}}"#,
        ])

        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/pi/s.jsonl"))
        #expect(result.events.count == 1)
        #expect(result.events[0].reasoningTokens == 7)
    }

    @Test
    func multipleAssistantTurnsAccumulate() throws {
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-05-30T10:00:00Z","cwd":"/Users/me/proj"}"#,
            #"{"type":"message","id":"a1","timestamp":1780178401000,"message":{"role":"assistant","model":"m","usage":{"input":10,"output":1,"cacheRead":0,"cacheWrite":0}}}"#,
            #"{"type":"message","id":"a2","timestamp":1780178402000,"message":{"role":"assistant","model":"m","usage":{"input":20,"output":2,"cacheRead":0,"cacheWrite":0}}}"#,
        ])

        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/pi/s.jsonl"))
        #expect(result.events.count == 2)
        #expect(result.events.map(\.inputTokens) == [10, 20])
        #expect(result.events.allSatisfy { $0.projectName == "proj" })
    }

    @Test
    func generationTimingPairsUserAndToolResultDispatches() throws {
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-05-30T10:00:00Z","cwd":"/p"}"#,
            #"{"type":"message","id":"u1","timestamp":1780178400000,"message":{"role":"user","content":"go"}}"#,
            #"{"type":"message","id":"a1","timestamp":1780178402000,"message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0}}}"#,
            // A tool result re-dispatches the model: it is the boundary for
            // the assistant message that follows it.
            #"{"type":"message","id":"t1","timestamp":1780178405000,"message":{"role":"toolResult","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"message","id":"a2","timestamp":1780178407000,"message":{"role":"assistant","model":"m","usage":{"input":20,"output":6,"cacheRead":0,"cacheWrite":0}}}"#,
        ])

        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/pi/s.jsonl"))
        #expect(result.events.count == 2)
        #expect(result.events[0].generationStartMs == 1_780_178_400_000)
        #expect(result.events[0].generationEndMs == 1_780_178_402_000)
        #expect(result.events[0].generationDurationMs == 2_000)
        #expect(result.events[1].generationStartMs == 1_780_178_405_000)
        #expect(result.events[1].generationDurationMs == 2_000)
    }

    @Test
    func generationTimingConsumesTriggerPerAssistant() throws {
        // One dispatch pairs with exactly one assistant turn; a second
        // assistant with no fresh user/toolResult trigger reports no timing.
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-05-30T10:00:00Z","cwd":"/p"}"#,
            #"{"type":"message","id":"u1","timestamp":1780178400000,"message":{"role":"user","content":"go"}}"#,
            #"{"type":"message","id":"a1","timestamp":1780178402000,"message":{"role":"assistant","model":"m","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0}}}"#,
            #"{"type":"message","id":"a2","timestamp":1780178409000,"message":{"role":"assistant","model":"m","usage":{"input":20,"output":6,"cacheRead":0,"cacheWrite":0}}}"#,
        ])

        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/pi/s.jsonl"))
        #expect(result.events.count == 2)
        #expect(result.events[0].generationDurationMs == 2_000)
        #expect(result.events[1].generationStartMs == nil)
        #expect(result.events[1].generationEndMs == nil)
    }

    @Test
    func generationTimingPrefersSameRecordStreamInterval() throws {
        // Real entries always carry message.timestamp (stamped when the
        // provider stream opens) plus an outer entry timestamp written at
        // message_end — together they bound the generation interval without
        // needing a trigger.
        let records = lines([
            #"{"type":"session","version":3,"id":"s","timestamp":"2026-05-30T10:00:00Z","cwd":"/p"}"#,
            #"{"type":"message","id":"a1","timestamp":1780178430000,"message":{"role":"assistant","model":"m","timestamp":1780178402500,"usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0}}}"#,
        ])

        let result = PiUsageParser.parse(lines: records, fileURL: URL(fileURLWithPath: "/tmp/pi/s.jsonl"))
        #expect(result.events.count == 1)
        #expect(result.events[0].generationStartMs == 1_780_178_402_500)
        #expect(result.events[0].generationEndMs == 1_780_178_430_000)
        #expect(result.events[0].generationDurationMs == 27_500)
    }
}
