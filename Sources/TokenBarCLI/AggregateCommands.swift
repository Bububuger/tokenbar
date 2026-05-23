import Foundation
import TokenBarCore

// MARK: - summary

enum SummaryCommand {
    static let name = "summary"
    static let allowedSort = ["tokens", "input", "output", "cache", "count", "cost"]

    struct Result: Encodable {
        let groupBy: [String]
        let rows: [Aggregation.GroupRow]
        let count: Int
        let totalCount: Int
        let totals: Totals
    }

    struct Totals: Encodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheTokens: Int
        let totalTokens: Int
        let eventCount: Int
        let promptCount: Int
        let estimatedCostUSD: Double
        let costSource: String
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        options.limit = CommandRegistry.descriptor(named: name)?.defaultLimit ?? 100
        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h": throw HelpRequested.command(name)
            default:
                if try !FilterParser.consume(flag: arg, cursor: &cursor, options: &options) {
                    throw CLIError.invalidArgument("Unexpected argument: \(arg)")
                }
            }
        }
        if let sort = options.sort { try sort.require(allowed: allowedSort) }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let events = CLIFilters.filterEvents(try repository.allEvents(), options: options)
        let prompts = CLIFilters.filterPrompts(try repository.allPrompts(), options: options)
        let calendar = Calendar.current

        let rows = Aggregation.aggregate(
            events: events,
            prompts: prompts,
            groupBy: options.groupBy,
            calendar: calendar
        )
        let sortedRows = CLISort.sort(rows, spec: options.sort)
        let total = sortedRows.count
        let limited = options.limit == 0 ? sortedRows : Array(sortedRows.prefix(options.limit))

        let totals = Totals(
            inputTokens: events.reduce(0) { $0 + $1.inputTokens },
            outputTokens: events.reduce(0) { $0 + $1.outputTokens },
            cacheTokens: events.reduce(0) { $0 + $1.cacheTokens },
            totalTokens: events.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheTokens },
            eventCount: events.count,
            promptCount: prompts.count,
            estimatedCostUSD: CostEstimator.estimate(events: events),
            costSource: "defaults"
        )

        let result = Result(
            groupBy: options.groupBy.map(\.rawValue),
            rows: limited,
            count: limited.count,
            totalCount: total,
            totals: totals
        )

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(limited)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "summary",
                result: result
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) summary")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            let groupByText = options.groupBy.isEmpty ? "(none)" : options.groupBy.map(\.rawValue).joined(separator: ",")
            let costText = String(format: "%.4f", totals.estimatedCostUSD)
            print("  Group-by: \(groupByText)")
            print("  Totals: total=\(totals.totalTokens) (in=\(totals.inputTokens) out=\(totals.outputTokens) cache=\(totals.cacheTokens)) events=\(totals.eventCount) prompts=\(totals.promptCount) cost~$\(costText)")
            print("  Rows: \(limited.count) (of \(total))")
            for row in limited {
                let keyText = options.groupBy.map { dim -> String in
                    let key = dim.rawValue
                    if let value = row.keys[key] {
                        return "\(key)=\(value.asString)"
                    }
                    return "\(key)=?"
                }.joined(separator: " ")
                print("  \(keyText) total=\(row.totalTokens) in=\(row.inputTokens) out=\(row.outputTokens) cache=\(row.cacheTokens) events=\(row.eventCount) prompts=\(row.promptCount)")
            }
        }
    }
}

// MARK: - timeline

enum TimelineCommand {
    static let name = "timeline"

    struct Result: Encodable {
        let bucket: String
        let groupBy: [String]
        let buckets: [Aggregation.Bucket]
        let count: Int
    }

    static func parse(cursor: inout ArgumentCursor, options: inout FilterOptions) throws {
        options.limit = CommandRegistry.descriptor(named: name)?.defaultLimit ?? 0
        while let arg = cursor.next() {
            switch arg {
            case "--help", "-h": throw HelpRequested.command(name)
            default:
                if try !FilterParser.consume(flag: arg, cursor: &cursor, options: &options) {
                    throw CLIError.invalidArgument("Unexpected argument: \(arg)")
                }
            }
        }
        try FilterParser.resolveWindow(&options)
    }

    static func run(_ options: FilterOptions) throws {
        let databaseURL = CLIPath.resolve(options.databasePath)
        let repository = try UsageRepository(databaseURL: databaseURL)
        let events = CLIFilters.filterEvents(try repository.allEvents(), options: options)
        let prompts = CLIFilters.filterPrompts(try repository.allPrompts(), options: options)
        let calendar = Calendar.current

        var buckets = Aggregation.aggregateTimeline(
            events: events,
            prompts: prompts,
            bucket: options.bucket,
            groupBy: options.groupBy,
            calendar: calendar
        )
        if options.limit > 0, buckets.count > options.limit {
            buckets = Array(buckets.prefix(options.limit))
        }

        let result = Result(
            bucket: options.bucket.rawValue,
            groupBy: options.groupBy.map(\.rawValue),
            buckets: buckets,
            count: buckets.count
        )

        switch options.output {
        case .ndjson:
            CLIOutput.writeNDJSON(buckets)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: CLIOutput.schemaVersion,
                command: name,
                generatedAt: CLIOutput.iso(Date()),
                databasePath: databaseURL.path,
                window: options.toEnvelopeWindow(),
                filters: options.toEnvelopeFilters(),
                resultKey: "timeline",
                result: result
            )
            CLIOutput.writeJSON(envelope)
        case .text:
            let program = CLIProgramName.current()
            print("\(program) timeline")
            printWindowSummary(options: options, databasePath: databaseURL.path)
            print("  Bucket: \(options.bucket.rawValue)")
            print("  Group-by: \(options.groupBy.isEmpty ? "(none)" : options.groupBy.map(\.rawValue).joined(separator: ","))")
            print("  Buckets: \(buckets.count)")
            for bucket in buckets {
                print("  - \(bucket.label) total=\(bucket.totalTokens) events=\(bucket.eventCount) prompts=\(bucket.promptCount)")
                for row in bucket.rows where !options.groupBy.isEmpty {
                    let keyText = options.groupBy.map { dim -> String in
                        let key = dim.rawValue
                        if let value = row.keys[key] {
                            return "\(key)=\(value.asString)"
                        }
                        return "\(key)=?"
                    }.joined(separator: " ")
                    print("      \(keyText) total=\(row.totalTokens) events=\(row.eventCount) prompts=\(row.promptCount)")
                }
            }
        }
    }
}
