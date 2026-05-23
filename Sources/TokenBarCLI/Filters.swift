import Foundation
import TokenBarCore

/// Shared filter vocabulary parsed across every read command. Each command
/// then applies its own subset (e.g. `events` honors --query; `projects`
/// does not).
struct FilterOptions {
    var databasePath: String?

    /// `--days N`. `0` means all-time. Mutually exclusive with `--since`/`--until`.
    var days: Int = 30
    var daysExplicit: Bool = false

    /// `--since ISO`. Mutually exclusive with `--days`.
    var since: Date?
    /// `--until ISO`. Mutually exclusive with `--days`.
    var until: Date?
    /// `--day YYYY-MM-DD`. Overrides --since/--until/--days when set.
    var day: String?

    var project: String?
    var agent: AgentKind?
    var model: String?
    var session: String?
    var query: String?
    var promptId: String?

    var limit: Int = 100
    var sort: SortSpec?
    var groupBy: [GroupByDimension] = []
    var bucket: TimeBucket = .day
    var output: OutputFormat = .text

    /// Resolved start (inclusive) after applying day/since/until/days precedence.
    var resolvedStart: Date?
    /// Resolved end (exclusive). nil = open-ended through now.
    var resolvedEnd: Date?

    /// Default sort field for commands that don't accept --sort changes.
    static let defaultLimit = 100
}

enum FilterParser {
    /// Parse a single shared flag. Returns `true` if the flag was consumed.
    /// Commands call this for every unknown arg and then handle the rest
    /// themselves; this keeps the filter vocabulary uniform without making
    /// every command repeat the same switch statement.
    static func consume(
        flag: String,
        cursor: inout ArgumentCursor,
        options: inout FilterOptions
    ) throws -> Bool {
        switch flag {
        case "--db":
            options.databasePath = try cursor.nextValue(for: "--db")
        case "--days":
            options.days = try parseDays(try cursor.nextValue(for: "--days"))
            options.daysExplicit = true
        case "--since":
            let raw = try cursor.nextValue(for: "--since")
            options.since = try parseISODate(raw, optionName: "--since")
        case "--until":
            let raw = try cursor.nextValue(for: "--until")
            options.until = try parseISODate(raw, optionName: "--until")
        case "--day":
            let raw = try cursor.nextValue(for: "--day")
            options.day = try validateDay(raw)
        case "--project":
            options.project = try cursor.nextValue(for: "--project")
        case "--agent":
            options.agent = try parseAgent(try cursor.nextValue(for: "--agent"))
        case "--model":
            options.model = try cursor.nextValue(for: "--model")
        case "--session":
            options.session = try cursor.nextValue(for: "--session")
        case "--query":
            options.query = try cursor.nextValue(for: "--query")
        case "--id":
            options.promptId = try cursor.nextValue(for: "--id")
        case "--limit":
            options.limit = try parseNonNegativeInt(try cursor.nextValue(for: "--limit"), name: "--limit")
        case "--sort":
            options.sort = try SortSpec.parse(try cursor.nextValue(for: "--sort"))
        case "--group-by":
            options.groupBy = try parseGroupBy(try cursor.nextValue(for: "--group-by"))
        case "--bucket":
            options.bucket = try parseBucket(try cursor.nextValue(for: "--bucket"))
        case "--json":
            if options.output == .ndjson {
                throw CLIError.invalidArgument("--json and --ndjson are mutually exclusive")
            }
            options.output = .json
        case "--ndjson":
            if options.output == .json {
                throw CLIError.invalidArgument("--json and --ndjson are mutually exclusive")
            }
            options.output = .ndjson
        default:
            return false
        }
        return true
    }

    /// Apply --day / --since/--until / --days precedence to populate
    /// `resolvedStart` and `resolvedEnd`. Call after argument parsing finishes.
    static func resolveWindow(_ options: inout FilterOptions, now: Date = Date()) throws {
        let calendar = Calendar.current

        if let day = options.day {
            guard let start = parseLocalDay(day) else {
                throw CLIError.invalidArgument("--day must be YYYY-MM-DD: \(day)")
            }
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            options.resolvedStart = start
            options.resolvedEnd = end
            return
        }

        let hasSinceOrUntil = options.since != nil || options.until != nil
        if hasSinceOrUntil {
            if options.daysExplicit {
                throw CLIError.invalidArgument("--days cannot be combined with --since/--until")
            }
            options.resolvedStart = options.since
            options.resolvedEnd = options.until
            if let start = options.since, let end = options.until, end <= start {
                throw CLIError.invalidArgument("--until must be later than --since")
            }
            return
        }

        if options.days == 0 {
            options.resolvedStart = nil
            options.resolvedEnd = nil
            return
        }

        let cutoff = calendar.date(byAdding: .day, value: -options.days, to: now) ?? now
        options.resolvedStart = cutoff
        options.resolvedEnd = nil
    }

    static func parseAgent(_ raw: String) throws -> AgentKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = AgentKind.allCases.first(where: { $0.rawValue == trimmed }) {
            return exact
        }
        let normalized = trimmed.lowercased()
        if let fuzzy = AgentKind.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
            return fuzzy
        }
        if let byDisplay = AgentKind.allCases.first(where: {
            $0.displayName.lowercased() == normalized
        }) {
            return byDisplay
        }
        let candidates = AgentKind.allCases.map(\.rawValue).joined(separator: ", ")
        throw CLIError.invalidArgument("Unknown agent '\(raw)'. Allowed: \(candidates)")
    }

    static func parseNonNegativeInt(_ raw: String, name: String) throws -> Int {
        guard let value = Int(raw), value >= 0 else {
            throw CLIError.invalidArgument("\(name) must be a non-negative integer")
        }
        return value
    }

    static func parseDays(_ raw: String) throws -> Int {
        try parseNonNegativeInt(raw, name: "--days")
    }

    static func parseISODate(_ raw: String, optionName: String) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withTime = ISO8601DateFormatter()
        withTime.formatOptions = [.withInternetDateTime]
        if let date = withTime.date(from: trimmed) {
            return date
        }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: trimmed) {
            return date
        }
        // Accept bare YYYY-MM-DD as local midnight.
        if let date = parseLocalDay(trimmed) {
            return date
        }
        // Accept "YYYY-MM-DDTHH:MM:SS" without timezone as local time.
        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = TimeZone.current
        if let date = localFormatter.date(from: trimmed) {
            return date
        }
        throw CLIError.invalidArgument("\(optionName) is not a valid ISO 8601 date: \(raw)")
    }

    static func validateDay(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parseLocalDay(trimmed) != nil else {
            throw CLIError.invalidArgument("--day must be YYYY-MM-DD: \(raw)")
        }
        return trimmed
    }

    static func parseLocalDay(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        guard let date = formatter.date(from: raw) else {
            return nil
        }
        return Calendar.current.startOfDay(for: date)
    }

    static func parseGroupBy(_ raw: String) throws -> [GroupByDimension] {
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if tokens.isEmpty {
            return []
        }
        var dims: [GroupByDimension] = []
        var seen = Set<GroupByDimension>()
        for token in tokens where !token.isEmpty {
            guard let dim = GroupByDimension(rawValue: token) else {
                let allowed = GroupByDimension.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError.invalidArgument("Unknown --group-by dimension '\(token)'. Allowed: \(allowed)")
            }
            if seen.insert(dim).inserted {
                dims.append(dim)
            }
        }
        return dims
    }

    static func parseBucket(_ raw: String) throws -> TimeBucket {
        guard let bucket = TimeBucket(rawValue: raw) else {
            let allowed = TimeBucket.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIError.invalidArgument("Unknown --bucket '\(raw)'. Allowed: \(allowed)")
        }
        return bucket
    }
}

/// Pure-Swift event filter. Repository APIs already return events for the
/// whole DB; the CLI applies window/project/agent/model/session in Swift to
/// match what `main.swift` did historically. SQL pushdown is a follow-up.
enum CLIFilters {
    static func filterEvents(_ events: [UsageEvent], options: FilterOptions) -> [UsageEvent] {
        let start = options.resolvedStart
        let end = options.resolvedEnd
        return events.filter { event in
            if let start, event.timestamp < start { return false }
            if let end, event.timestamp >= end { return false }
            if let projectName = options.project, event.projectName != projectName { return false }
            if let agent = options.agent, event.agent != agent { return false }
            if let model = options.model {
                let eventModel = (event.modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if eventModel != model { return false }
            }
            if let session = options.session, event.sessionId != session { return false }
            return true
        }
    }

    static func filterPrompts(_ prompts: [PromptRecord], options: FilterOptions) -> [PromptRecord] {
        let start = options.resolvedStart
        let end = options.resolvedEnd
        return prompts.filter { prompt in
            if let id = options.promptId, prompt.id != id { return false }
            if let start, prompt.timestamp < start { return false }
            if let end, prompt.timestamp >= end { return false }
            if let projectName = options.project, prompt.projectName != projectName { return false }
            if let agent = options.agent, prompt.agent != agent { return false }
            if let session = options.session, prompt.sessionId != session { return false }
            if let query = options.query, !query.isEmpty {
                if prompt.content.range(of: query, options: .caseInsensitive) == nil {
                    return false
                }
            }
            return true
        }
    }
}
