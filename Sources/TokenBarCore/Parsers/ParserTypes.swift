import Foundation

/// Shared parser-side warning shape. Claude / Codex / OpenClaw used to each
/// declare their own copy of this struct — `(sourcePath, lineNumber, message)`
/// in all three. Consolidated here so a fourth JSONL agent does not get a
/// fourth copy. Gemini's parser produces `UsageSourceWarning` directly (no
/// intermediate stage), so it does not need this type.
public struct ParseWarning: Sendable, Hashable {
    public let sourcePath: String
    public let lineNumber: Int
    public let message: String

    public init(sourcePath: String, lineNumber: Int, message: String) {
        self.sourcePath = sourcePath
        self.lineNumber = lineNumber
        self.message = message
    }
}

/// Shared parser-side result shape. `(events, prompts, warnings)`. Same
/// rationale as `ParseWarning`: Claude / Codex / OpenClaw each declared
/// this struct verbatim. Now they alias to this one type.
public struct ParseResult: Sendable, Hashable {
    public let events: [UsageEvent]
    public let prompts: [PromptRecord]
    public let warnings: [ParseWarning]

    public init(events: [UsageEvent], prompts: [PromptRecord] = [], warnings: [ParseWarning]) {
        self.events = events
        self.prompts = prompts
        self.warnings = warnings
    }
}
