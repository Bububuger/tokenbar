import Foundation
import Testing
@testable import TokenBarCore

/// End-to-end seam coverage: real-record fixture lines run through the
/// parsers, and the emitted events feed `GenerationRate`. The two timing
/// mechanisms (same-record duration vs dispatch pairing) each get one
/// pass so a regression that leaves events untimed — or leaves the rate
/// unable to read them — fails here rather than in the menu bar.
struct RatePipelineTests {

    @Test
    func grokSameRecordTimingFeedsGenerationRate() {
        let record = """
        {"timestamp":1788449900,"params":{"sessionId":"sess-e2e","update":{"sessionUpdate":"turn_completed","prompt_id":"t1","elapsed_ms":9000,"usage":{"inputTokens":800,"outputTokens":40,"apiDurationMs":2000,"cachedReadTokens":0,"cacheCreationTokens":0,"primaryModelId":"grok-4.7-high"}}}}
        """
        let fileURL = URL(fileURLWithPath: "/tmp/grok-e2e/updates.jsonl")
        let parsed = GrokUsageParser.parse(lines: jsonlLines([record]), fileURL: fileURL)
        #expect(parsed.events.count == 1)

        let asOf = Date(timeIntervalSince1970: 1_788_449_900 + 60)
        let rate = GenerationRate(events: parsed.events, asOf: asOf)
        #expect(rate.sampleCount == 1)
        #expect(rate.tokensPerSecond == 20)
    }

    @Test
    func codexDispatchPairingFeedsGenerationRate() {
        let records = [
            #"{"timestamp":"2026-07-24T00:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp/tokenbar"}}"#,
            #"{"timestamp":"2026-07-24T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}}"#,
            #"{"timestamp":"2026-07-24T00:00:03.500Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":0}}}}"#,
        ]
        let parsed = CodexUsageParser.parse(
            lines: jsonlLines(records),
            fileURL: URL(fileURLWithPath: "/tmp/codex-e2e/session.jsonl")
        )
        #expect(parsed.events.count == 1)

        let endMs = parsed.events[0].generationEndMs
        #expect(endMs != nil)
        let asOf = Date(timeIntervalSince1970: TimeInterval((endMs ?? 0) + 60_000) / 1_000)
        let rate = GenerationRate(events: parsed.events, asOf: asOf)
        #expect(rate.sampleCount == 1)
        #expect(rate.tokensPerSecond == 2)
    }

    private func jsonlLines(_ lines: [String]) -> [JSONLLineRecord] {
        lines.enumerated().map {
            JSONLLineRecord(
                text: $0.element,
                lineNumber: $0.offset + 1,
                startOffset: 0,
                endOffset: 0
            )
        }
    }
}
