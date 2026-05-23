import Foundation
import TokenBarCore

enum GroupByDimension: String, CaseIterable, Hashable {
    case project
    case agent
    case model
    case day
    case hourOfDay = "hour-of-day"
    case session
}

enum TimeBucket: String, CaseIterable, Hashable {
    case day
    case hour
    case hourOfDay = "hour-of-day"
}

/// Stable ordering of sort fields a command may accept. Each command
/// declares which subset it supports; SortSpec.parse only validates the
/// field name format, command code rejects unsupported fields.
struct SortSpec {
    var field: String
    var direction: Direction

    enum Direction: String {
        case asc
        case desc
    }

    static func parse(_ raw: String) throws -> SortSpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, !first.isEmpty else {
            throw CLIError.invalidArgument("--sort field is empty")
        }
        let direction: Direction
        if parts.count == 2 {
            guard let parsed = Direction(rawValue: parts[1].lowercased()) else {
                throw CLIError.invalidArgument("--sort direction must be asc or desc")
            }
            direction = parsed
        } else {
            direction = .desc
        }
        return SortSpec(field: first, direction: direction)
    }

    func require(allowed: [String]) throws {
        if !allowed.contains(field) {
            throw CLIError.invalidArgument("--sort field '\(field)' not allowed here. Allowed: \(allowed.joined(separator: ", "))")
        }
    }
}

struct TokenBucket {
    var inputTokens = 0
    var outputTokens = 0
    var cacheTokens = 0
    var eventCount = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheTokens }

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheTokens += event.cacheTokens
        eventCount += 1
    }
}

enum CostEstimator {
    /// Compute an approximate cost for a token bucket using the per-agent
    /// default rate table. Does NOT honor user pricing overrides (those live
    /// in the app's UserDefaults and are out of scope for this CLI version).
    /// Use `costSource: "defaults"` in the JSON payload.
    static func estimate(events: [UsageEvent]) -> Double {
        var cost = 0.0
        for event in events {
            let tokens = event.inputTokens + event.outputTokens + event.cacheTokens
            cost += Double(tokens) * event.agent.defaultCostPerMillionTokens / 1_000_000
        }
        return cost
    }
}

/// Aggregates events into rows keyed by a tuple of group-by dimensions.
/// Returns an array suitable for JSON emit. Sort + limit applied last.
enum Aggregation {
    struct GroupRow: Encodable {
        let keys: [String: GroupKeyValue]
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalTokens: Int
        let eventCount: Int
        let promptCount: Int
        let estimatedCostUSD: Double
        let costSource: String

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in keys {
                try value.encode(into: &container, key: key)
            }
            try container.encode(inputTokens, forKey: DynamicCodingKey("inputTokens"))
            try container.encode(outputTokens, forKey: DynamicCodingKey("outputTokens"))
            try container.encode(cacheTokens, forKey: DynamicCodingKey("cacheTokens"))
            try container.encode(totalTokens, forKey: DynamicCodingKey("totalTokens"))
            try container.encode(eventCount, forKey: DynamicCodingKey("eventCount"))
            try container.encode(promptCount, forKey: DynamicCodingKey("promptCount"))
            try container.encode(estimatedCostUSD, forKey: DynamicCodingKey("estimatedCostUSD"))
            try container.encode(costSource, forKey: DynamicCodingKey("costSource"))
        }
    }

    enum GroupKeyValue {
        case string(String)
        case int(Int)

        func encode(into container: inout KeyedEncodingContainer<DynamicCodingKey>, key: String) throws {
            switch self {
            case .string(let value):
                try container.encode(value, forKey: DynamicCodingKey(key))
            case .int(let value):
                try container.encode(value, forKey: DynamicCodingKey(key))
            }
        }

        var asString: String {
            switch self {
            case .string(let value): return value
            case .int(let value): return String(value)
            }
        }
    }

    static func aggregate(
        events: [UsageEvent],
        prompts: [PromptRecord],
        groupBy: [GroupByDimension],
        calendar: Calendar
    ) -> [GroupRow] {
        guard !groupBy.isEmpty else {
            var bucket = TokenBucket()
            for event in events { bucket.add(event) }
            return [
                GroupRow(
                    keys: [:],
                    inputTokens: bucket.inputTokens,
                    outputTokens: bucket.outputTokens,
                    cacheTokens: bucket.cacheTokens,
                    totalTokens: bucket.totalTokens,
                    eventCount: bucket.eventCount,
                    promptCount: prompts.count,
                    estimatedCostUSD: CostEstimator.estimate(events: events),
                    costSource: "defaults"
                ),
            ]
        }

        var groupedEvents: [GroupKeyTuple: [UsageEvent]] = [:]
        for event in events {
            let key = makeKey(for: event, dimensions: groupBy, calendar: calendar)
            groupedEvents[key, default: []].append(event)
        }

        var groupedPromptCounts: [GroupKeyTuple: Int] = [:]
        for prompt in prompts {
            let key = makeKey(for: prompt, dimensions: groupBy, calendar: calendar)
            groupedPromptCounts[key, default: 0] += 1
        }

        return groupedEvents.map { tuple, eventList in
            var bucket = TokenBucket()
            for event in eventList { bucket.add(event) }
            let promptCount = groupedPromptCounts[tuple] ?? 0
            return GroupRow(
                keys: tuple.toEncodable(),
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheTokens: bucket.cacheTokens,
                totalTokens: bucket.totalTokens,
                eventCount: bucket.eventCount,
                promptCount: promptCount,
                estimatedCostUSD: CostEstimator.estimate(events: eventList),
                costSource: "defaults"
            )
        }
    }

    /// Aggregate into time buckets, optionally further grouped by --group-by
    /// dimensions inside each bucket. Returns ordered list of buckets with
    /// bucket-relative rows.
    struct Bucket: Encodable {
        let bucketStart: String?
        let hourOfDay: Int?
        let label: String
        let rows: [GroupRow]
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalTokens: Int
        let eventCount: Int
        let promptCount: Int
    }

    static func aggregateTimeline(
        events: [UsageEvent],
        prompts: [PromptRecord],
        bucket bucketKind: TimeBucket,
        groupBy: [GroupByDimension],
        calendar: Calendar
    ) -> [Bucket] {
        var bucketEvents: [TimelineKey: [UsageEvent]] = [:]
        var order: [TimelineKey] = []
        for event in events {
            let key = TimelineKey.from(event: event, bucket: bucketKind, calendar: calendar)
            if bucketEvents[key] == nil {
                order.append(key)
            }
            bucketEvents[key, default: []].append(event)
        }

        var bucketPrompts: [TimelineKey: [PromptRecord]] = [:]
        for prompt in prompts {
            let key = TimelineKey.from(prompt: prompt, bucket: bucketKind, calendar: calendar)
            bucketPrompts[key, default: []].append(prompt)
        }

        let sortedKeys = order.sorted { lhs, rhs in
            lhs.sortKey < rhs.sortKey
        }

        return sortedKeys.map { key -> Bucket in
            let evs = bucketEvents[key] ?? []
            let prs = bucketPrompts[key] ?? []
            let rows = aggregate(events: evs, prompts: prs, groupBy: groupBy, calendar: calendar)
            var bucket = TokenBucket()
            for event in evs { bucket.add(event) }
            return Bucket(
                bucketStart: key.bucketStartISO,
                hourOfDay: key.hourOfDay,
                label: key.label,
                rows: rows,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheTokens: bucket.cacheTokens,
                totalTokens: bucket.totalTokens,
                eventCount: bucket.eventCount,
                promptCount: prs.count
            )
        }
    }

    private static func makeKey(
        for event: UsageEvent,
        dimensions: [GroupByDimension],
        calendar: Calendar
    ) -> GroupKeyTuple {
        var pairs: [(String, GroupKeyValue)] = []
        for dim in dimensions {
            pairs.append((dim.rawValue, value(for: dim, eventOrPrompt: .event(event), calendar: calendar)))
        }
        return GroupKeyTuple(pairs)
    }

    private static func makeKey(
        for prompt: PromptRecord,
        dimensions: [GroupByDimension],
        calendar: Calendar
    ) -> GroupKeyTuple {
        var pairs: [(String, GroupKeyValue)] = []
        for dim in dimensions {
            pairs.append((dim.rawValue, value(for: dim, eventOrPrompt: .prompt(prompt), calendar: calendar)))
        }
        return GroupKeyTuple(pairs)
    }

    private enum EventOrPrompt {
        case event(UsageEvent)
        case prompt(PromptRecord)
    }

    private static func value(
        for dim: GroupByDimension,
        eventOrPrompt: EventOrPrompt,
        calendar: Calendar
    ) -> GroupKeyValue {
        switch dim {
        case .project:
            switch eventOrPrompt {
            case .event(let e): return .string(e.projectName)
            case .prompt(let p): return .string(p.projectName)
            }
        case .agent:
            switch eventOrPrompt {
            case .event(let e): return .string(e.agent.rawValue)
            case .prompt(let p): return .string(p.agent.rawValue)
            }
        case .model:
            switch eventOrPrompt {
            case .event(let e):
                let name = (e.modelName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return .string(name.isEmpty ? e.agent.displayName : name)
            case .prompt(let p): return .string(p.agent.displayName)
            }
        case .day:
            let date: Date
            switch eventOrPrompt {
            case .event(let e): date = calendar.startOfDay(for: e.timestamp)
            case .prompt(let p): date = calendar.startOfDay(for: p.timestamp)
            }
            return .string(CLIOutput.formatDay(date))
        case .hourOfDay:
            switch eventOrPrompt {
            case .event(let e): return .int(calendar.component(.hour, from: e.timestamp))
            case .prompt(let p): return .int(calendar.component(.hour, from: p.timestamp))
            }
        case .session:
            switch eventOrPrompt {
            case .event(let e): return .string(e.sessionId)
            case .prompt(let p): return .string(p.sessionId)
            }
        }
    }
}

struct GroupKeyTuple: Hashable {
    let entries: [(String, String)]

    init(_ pairs: [(String, Aggregation.GroupKeyValue)]) {
        self.entries = pairs.map { ($0.0, $0.1.asString) }
    }

    func hash(into hasher: inout Hasher) {
        for (key, value) in entries {
            hasher.combine(key)
            hasher.combine(value)
        }
    }

    static func == (lhs: GroupKeyTuple, rhs: GroupKeyTuple) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        for index in 0..<lhs.entries.count {
            if lhs.entries[index] != rhs.entries[index] { return false }
        }
        return true
    }

    func toEncodable() -> [String: Aggregation.GroupKeyValue] {
        var out: [String: Aggregation.GroupKeyValue] = [:]
        for (key, value) in entries {
            if let intValue = Int(value), key == "hour-of-day" {
                out[key] = .int(intValue)
            } else {
                out[key] = .string(value)
            }
        }
        return out
    }
}

private struct TimelineKey: Hashable {
    let kind: TimeBucket
    let date: Date?       // for .day / .hour
    let hourOfDay: Int?   // for .hour-of-day

    var sortKey: String {
        if let date {
            return CLIOutput.iso(date)
        }
        if let hourOfDay {
            return String(format: "%02d", hourOfDay)
        }
        return ""
    }

    var bucketStartISO: String? {
        date.map(CLIOutput.iso)
    }

    var label: String {
        switch kind {
        case .day:
            return CLIOutput.formatDay(date ?? Date(timeIntervalSince1970: 0))
        case .hour:
            return CLIOutput.formatHourRange(start: date ?? Date(timeIntervalSince1970: 0))
        case .hourOfDay:
            return CLIOutput.formatHourOfDay(hourOfDay ?? 0)
        }
    }

    static func from(event: UsageEvent, bucket: TimeBucket, calendar: Calendar) -> TimelineKey {
        from(timestamp: event.timestamp, bucket: bucket, calendar: calendar)
    }

    static func from(prompt: PromptRecord, bucket: TimeBucket, calendar: Calendar) -> TimelineKey {
        from(timestamp: prompt.timestamp, bucket: bucket, calendar: calendar)
    }

    private static func from(timestamp: Date, bucket: TimeBucket, calendar: Calendar) -> TimelineKey {
        switch bucket {
        case .day:
            return TimelineKey(kind: .day, date: calendar.startOfDay(for: timestamp), hourOfDay: nil)
        case .hour:
            var components = calendar.dateComponents([.year, .month, .day, .hour], from: timestamp)
            components.minute = 0
            components.second = 0
            let start = calendar.date(from: components) ?? timestamp
            return TimelineKey(kind: .hour, date: start, hourOfDay: nil)
        case .hourOfDay:
            return TimelineKey(kind: .hourOfDay, date: nil, hourOfDay: calendar.component(.hour, from: timestamp))
        }
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) {
        self.stringValue = name
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

enum CLISort {
    /// Sort GroupRow array per --sort spec or fall back to total tokens desc.
    static func sort(_ rows: [Aggregation.GroupRow], spec: SortSpec?) -> [Aggregation.GroupRow] {
        let s = spec ?? SortSpec(field: "tokens", direction: .desc)
        let direction = s.direction
        return rows.sorted { lhs, rhs in
            let (a, b) = compareValues(field: s.field, lhs: lhs, rhs: rhs)
            switch direction {
            case .asc: return a < b
            case .desc: return a > b
            }
        }
    }

    private static func compareValues(
        field: String,
        lhs: Aggregation.GroupRow,
        rhs: Aggregation.GroupRow
    ) -> (Double, Double) {
        switch field {
        case "tokens", "total":
            return (Double(lhs.totalTokens), Double(rhs.totalTokens))
        case "input":
            return (Double(lhs.inputTokens), Double(rhs.inputTokens))
        case "output":
            return (Double(lhs.outputTokens), Double(rhs.outputTokens))
        case "cache":
            return (Double(lhs.cacheTokens), Double(rhs.cacheTokens))
        case "count", "eventCount":
            return (Double(lhs.eventCount), Double(rhs.eventCount))
        case "promptCount":
            return (Double(lhs.promptCount), Double(rhs.promptCount))
        case "cost":
            return (lhs.estimatedCostUSD, rhs.estimatedCostUSD)
        default:
            return (Double(lhs.totalTokens), Double(rhs.totalTokens))
        }
    }
}
