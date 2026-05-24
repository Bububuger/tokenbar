import Foundation
import Testing
@testable import TokenBarCore

struct WarningScenarioTests {
    @Test
    func severityClassifierUsesFailedToPrefix() {
        let err = makeWarning(message: "failed to read source file: No such file")
        let warn = makeWarning(message: "partial trailing JSONL line; watermark rewound to byte 1234")
        #expect(err.severity == .error)
        #expect(warn.severity == .warning)
    }

    @Test
    func scenarioKeyStripsVariableSuffix() {
        let a = makeWarning(message: "partial trailing JSONL line; watermark rewound to byte 1234")
        let b = makeWarning(message: "partial trailing JSONL line; watermark rewound to byte 9999")
        #expect(a.scenarioKey == "partial trailing JSONL line")
        #expect(a.scenarioKey == b.scenarioKey)
    }

    @Test
    func scenarioKeyStripsColonDetail() {
        let w = makeWarning(message: "forced full reparse: schema migrated v9 → v11")
        #expect(w.scenarioKey == "forced full reparse")
    }

    @Test
    func sameKindAcrossManyEventsCollapsesToOneScenario() {
        let warnings: [UsageSourceWarning] = (0..<247).map { i in
            makeWarning(
                sourceName: "Claude Code",
                sourcePath: "/file\(i).jsonl",
                lineNumber: i + 1,
                message: "partial trailing JSONL line; watermark rewound to byte \(i * 1000)"
            )
        }
        let scenarios = warnings.groupedByScenario()
        #expect(scenarios.count == 1)
        #expect(scenarios[0].occurrenceCount == 247)
        #expect(scenarios[0].severity == .warning)
        // path list is capped (default 10)
        #expect(scenarios[0].affectedPaths.count == 10)
    }

    @Test
    func differentSourcesProduceSeparateScenariosForSameKind() {
        let a = makeWarning(sourceName: "Claude Code", message: "partial trailing JSONL line; X")
        let b = makeWarning(sourceName: "Codex",       message: "partial trailing JSONL line; Y")
        let scenarios = [a, b].groupedByScenario()
        #expect(scenarios.count == 2)
    }

    @Test
    func errorsSortAheadOfWarnings() {
        let warn = makeWarning(message: "partial trailing JSONL line; x")
        let err = makeWarning(message: "failed to read source file: no perms")
        let scenarios = [warn, warn, err].groupedByScenario()
        // error first, warning second
        #expect(scenarios.first?.severity == .error)
        #expect(scenarios.last?.severity == .warning)
    }

    @Test
    func emptyInputReturnsEmpty() {
        let scenarios: [WarningScenario] = [].groupedByScenario()
        #expect(scenarios.isEmpty)
    }

    @Test
    func uniquePathsAreDeduped() {
        let warnings: [UsageSourceWarning] = [
            makeWarning(sourcePath: "/same.jsonl", message: "partial trailing JSONL line; A"),
            makeWarning(sourcePath: "/same.jsonl", message: "partial trailing JSONL line; B"),
            makeWarning(sourcePath: "/other.jsonl", message: "partial trailing JSONL line; C"),
        ]
        let scenarios = warnings.groupedByScenario()
        #expect(scenarios.count == 1)
        #expect(scenarios[0].affectedPaths.count == 2)
    }

    private func makeWarning(
        sourceName: String = "Claude Code",
        sourcePath: String = "/tmp/file.jsonl",
        lineNumber: Int? = 42,
        message: String
    ) -> UsageSourceWarning {
        UsageSourceWarning(
            sourceName: sourceName,
            sourcePath: sourcePath,
            lineNumber: lineNumber,
            message: message
        )
    }
}
