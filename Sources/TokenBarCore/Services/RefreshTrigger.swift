import Foundation

/// What caused a refresh / checkpoint run. The runtime model and CheckpointEngine
/// switch on this. Previously this flowed through the codebase as raw
/// `String`, with prefix-checks like `hasPrefix("custom-source-")` sprinkled
/// across the runtime. The enum collapses ~17 callsites onto a single
/// canonical value and confines the raw-string form to the telemetry /
/// checkpoint-serialization boundary (via `.rawValue`).
public enum RefreshTrigger: Sendable, Equatable, Hashable {
    /// App just launched. One-shot catch-up at user-visible budget.
    case bootstrapBackground
    /// FSEvents fired on a watched root.
    case fileChange
    /// User asked to wipe + reindex everything.
    case reparseAll
    /// User asked to wipe + reindex a single source.
    case reparseSource
    /// macOS wake-from-sleep notification.
    case wake
    /// Periodic timer.
    case interval
    /// User pulled-to-refresh from popover.
    case manual
    /// Date-changed local notification (00:00 rollover).
    case midnightRollover
    /// CRUD on a custom source.
    case customSource(action: CustomSourceAction)
    /// `tbar rebuild` from the CLI.
    case cliRebuild
    /// Cold-start initial indexing.
    case coldStart
    /// User wiped prompts from Diagnostics; refresh state after the table
    /// drops to zero.
    case wipePrompts

    public enum CustomSourceAction: String, Sendable {
        case add
        case update
        case deduplicate
        case toggle
        case remove
    }

    /// Stable raw-string used for telemetry metadata, checkpoint `.trigger`
    /// rows, and any other persistence boundary that needs a single name.
    public var rawValue: String {
        switch self {
        case .bootstrapBackground: return "bootstrap-background"
        case .fileChange:          return "file-change"
        case .reparseAll:          return "reparse-all"
        case .reparseSource:       return "reparse-source"
        case .wake:                return "wake"
        case .interval:            return "interval"
        case .manual:              return "manual"
        case .midnightRollover:    return "midnight-rollover"
        case .customSource(let a): return "custom-source-\(a.rawValue)"
        case .cliRebuild:          return "cli-rebuild-all-history"
        case .coldStart:           return "cold-start"
        case .wipePrompts:         return "wipe-prompts"
        }
    }

    /// True if this is any `customSource(...)` variant. Replaces the
    /// `trigger.hasPrefix("custom-source-")` checks that were scattered
    /// across the runtime model.
    public var isCustomSource: Bool {
        if case .customSource = self { return true }
        return false
    }
}

extension RefreshTrigger: CustomStringConvertible {
    /// Lets `"\(trigger)"` interpolation give the canonical raw form so
    /// telemetry metadata doesn't have to write `.rawValue` everywhere.
    public var description: String { rawValue }
}
