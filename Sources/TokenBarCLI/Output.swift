import Foundation

enum OutputFormat {
    case text
    case json
    case ndjson
}

enum CLIOutput {
    static let schemaVersion = "1"

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func iso(_ date: Date?) -> String? {
        date.map(iso)
    }

    static func writeJSON<T: Encodable>(_ value: T) {
        let encoder = makeEncoder()
        do {
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            fputs("Failed to encode JSON output: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func writeNDJSON<T: Encodable>(_ rows: [T]) {
        let encoder = makeEncoder(pretty: false)
        for row in rows {
            do {
                let data = try encoder.encode(row)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            } catch {
                fputs("Failed to encode NDJSON row: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }
    }

    static func formatHourRange(start: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:00"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let end = Calendar.current.date(byAdding: .minute, value: 59, to: start) ?? start
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "HH:59"
        endFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(formatter.string(from: start))-\(endFormatter.string(from: end))"
    }

    static func formatHourOfDay(_ hour: Int) -> String {
        let normalized = max(0, min(23, hour))
        return String(format: "%02d:00-%02d:59", normalized, normalized)
    }

    static func formatDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func truncate(_ value: String, _ maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let maxIndex = value.index(value.startIndex, offsetBy: max(0, maxLength))
        return "\(value[value.startIndex..<maxIndex])..."
    }

    private static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

struct EnvelopeWindow: Encodable {
    let days: Int?
    let since: String?
    let until: String?
    let day: String?
    let allTime: Bool
}

/// Generic top-level JSON envelope. `result` is encoded under the
/// command-specific key passed via `resultKey` (events, prompts, projects,
/// etc.) so each command's output stays self-describing.
struct JSONEnvelope<T: Encodable>: Encodable {
    let schemaVersion: String
    let command: String
    let generatedAt: String
    let databasePath: String
    let window: EnvelopeWindow?
    let filters: [String: String]?
    let resultKey: String
    let result: T

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case command
        case generatedAt
        case databasePath
        case window
        case filters
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(schemaVersion, forKey: DynamicKey("schemaVersion"))
        try container.encode(command, forKey: DynamicKey("command"))
        try container.encode(generatedAt, forKey: DynamicKey("generatedAt"))
        try container.encode(databasePath, forKey: DynamicKey("databasePath"))
        if let window {
            try container.encode(window, forKey: DynamicKey("window"))
        }
        if let filters, !filters.isEmpty {
            try container.encode(filters, forKey: DynamicKey("filters"))
        }
        try container.encode(result, forKey: DynamicKey(resultKey))
    }
}

private struct DynamicKey: CodingKey {
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

extension FilterOptions {
    func toEnvelopeWindow() -> EnvelopeWindow {
        let allTime = (resolvedStart == nil && resolvedEnd == nil && days == 0 && day == nil && since == nil && until == nil)
        return EnvelopeWindow(
            days: (day == nil && since == nil && until == nil) ? days : nil,
            since: CLIOutput.iso(resolvedStart),
            until: CLIOutput.iso(resolvedEnd),
            day: day,
            allTime: allTime
        )
    }

    func toEnvelopeFilters() -> [String: String] {
        var filters: [String: String] = [:]
        if let project { filters["project"] = project }
        if let agent { filters["agent"] = agent.rawValue }
        if let model { filters["model"] = model }
        if let session { filters["session"] = session }
        if let query, !query.isEmpty { filters["query"] = query }
        if let promptId { filters["id"] = promptId }
        return filters
    }
}
