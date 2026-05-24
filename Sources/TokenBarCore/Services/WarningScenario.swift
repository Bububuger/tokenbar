import Foundation

/// Severity classifier for source-side warnings. We compute this at display
/// time from the message prefix so we don't have to migrate the on-disk
/// `source_warnings` table just to surface a UX split. `.error` means the
/// parser failed to read/process a whole file (data loss); `.warning` means
/// a per-line recoverable issue (file is being actively appended to, etc.).
public enum SourceWarningSeverity: String, Sendable, Hashable {
    case error
    case warning
}

extension UsageSourceWarning {
    /// Heuristic — true source-of-truth would be a `severity` column on the
    /// row. Defer that migration; for now anything starting with "failed to"
    /// is a hard failure, the rest are recoverable line-level issues.
    public var severity: SourceWarningSeverity {
        let lowered = message.lowercased()
        if lowered.hasPrefix("failed to ") { return .error }
        return .warning
    }

    /// Normalized "kind" — strips variable details (line numbers, byte
    /// offsets, error-cause suffix) so 247 warnings that are really the same
    /// parser scenario collapse to one row in the UI.
    public var scenarioKey: String {
        var trimmed = message
        if let cut = trimmed.firstIndex(where: { $0 == ";" || $0 == ":" }) {
            trimmed = String(trimmed[..<cut])
        }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }
}

/// One aggregated bucket — a unique (source, scenario-kind) pair. Carries the
/// occurrence count and which files were affected so the UI can answer "what
/// kind of issue is this and how many events did it touch?".
public struct WarningScenario: Sendable, Hashable, Identifiable {
    public let id: String
    public let sourceName: String
    public let severity: SourceWarningSeverity
    public let kind: String
    public let exampleMessage: String
    public let occurrenceCount: Int
    public let affectedPaths: [String]
    public let firstLineNumber: Int?

    public init(
        id: String,
        sourceName: String,
        severity: SourceWarningSeverity,
        kind: String,
        exampleMessage: String,
        occurrenceCount: Int,
        affectedPaths: [String],
        firstLineNumber: Int?
    ) {
        self.id = id
        self.sourceName = sourceName
        self.severity = severity
        self.kind = kind
        self.exampleMessage = exampleMessage
        self.occurrenceCount = occurrenceCount
        self.affectedPaths = affectedPaths
        self.firstLineNumber = firstLineNumber
    }
}

extension Array where Element == UsageSourceWarning {
    /// Collapse a raw warning list into `WarningScenario` buckets — sorted
    /// errors-first, then by occurrence count descending. Each bucket caps
    /// `affectedPaths` at 10 to keep the UI tight; the full path list lives
    /// in the original warnings if a future drawer wants to expand.
    public func groupedByScenario(pathLimit: Int = 10) -> [WarningScenario] {
        let groups = Dictionary(grouping: self) { warning in
            "\(warning.sourceName)|\(warning.severity.rawValue)|\(warning.scenarioKey)"
        }
        return groups.values
            .compactMap { (group: [UsageSourceWarning]) -> WarningScenario? in
                guard let first = group.first else { return nil }
                var seen = Set<String>()
                var uniquePaths: [String] = []
                for w in group where !seen.contains(w.sourcePath) {
                    seen.insert(w.sourcePath)
                    uniquePaths.append(w.sourcePath)
                    if uniquePaths.count >= pathLimit { break }
                }
                return WarningScenario(
                    id: "\(first.sourceName)|\(first.severity.rawValue)|\(first.scenarioKey)",
                    sourceName: first.sourceName,
                    severity: first.severity,
                    kind: first.scenarioKey,
                    exampleMessage: first.message,
                    occurrenceCount: group.count,
                    affectedPaths: uniquePaths,
                    firstLineNumber: first.lineNumber
                )
            }
            .sorted { a, b in
                if a.severity != b.severity {
                    return a.severity == .error
                }
                return a.occurrenceCount > b.occurrenceCount
            }
    }
}
