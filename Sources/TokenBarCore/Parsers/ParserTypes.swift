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

/// Fast ISO8601 timestamp parsing shared by every JSONL parser.
///
/// All agents (Claude Code, Codex, Gemini, …) write UTC ISO8601 timestamps in
/// a fixed layout: `YYYY-MM-DDTHH:MM:SS[.fff]Z`. The Foundation
/// `ISO8601DateFormatter` parses these via ICU's `DecimalFormat` number
/// parser, which rebuilds parser state on the hot path and dominated indexing
/// time on large sources (hundreds of thousands of lines — it could stall the
/// progress bar near completion for many seconds). Parsing the fixed layout by
/// hand is ~10-50x faster and allocation-free.
///
/// Returns nil for anything that doesn't match the canonical UTC layout
/// exactly (including non-`Z` zones), so callers fall back to a shared
/// `ISO8601DateFormatter` and correctness is never traded for speed.
public enum ISO8601Fast {
    /// Gregorian calendar pinned to UTC, reused across calls.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    public static func parseUTC(_ s: String) -> Date? {
        let bytes = Array(s.utf8)
        // Minimum "YYYY-MM-DDTHH:MM:SSZ" = 20 bytes.
        guard bytes.count >= 20 else { return nil }
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":"), bytes[bytes.count - 1] == UInt8(ascii: "Z")
        else { return nil }

        func num(_ lo: Int, _ hi: Int) -> Int? {
            var acc = 0
            var i = lo
            while i < hi {
                let d = bytes[i]
                guard d >= zero, d <= nine else { return nil }
                acc = acc * 10 + Int(d - zero)
                i += 1
            }
            return acc
        }
        guard let year = num(0, 4), let month = num(5, 7), let day = num(8, 10),
              let hour = num(11, 13), let minute = num(14, 16), let second = num(17, 19)
        else { return nil }

        var millis = 0
        if bytes[19] == UInt8(ascii: ".") {
            let fracStart = 20
            let fracEnd = bytes.count - 1 // exclusive of trailing Z
            guard fracEnd > fracStart else { return nil }
            var acc = 0, digits = 0, i = fracStart
            while i < fracEnd {
                let d = bytes[i]
                guard d >= zero, d <= nine else { return nil }
                if digits < 3 { acc = acc * 10 + Int(d - zero) }
                digits += 1
                i += 1
            }
            while digits < 3 { acc *= 10; digits += 1 } // ".1" → 100ms
            millis = acc
        } else if bytes[19] != UInt8(ascii: "Z") {
            return nil
        }

        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = hour; c.minute = minute; c.second = second
        c.nanosecond = millis * 1_000_000
        return utcCalendar.date(from: c)
    }
}

