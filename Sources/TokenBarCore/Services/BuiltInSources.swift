import Foundation

/// Canonical list of TokenBar's built-in agent sources.
///
/// The app's `TokenBarRuntimeModel.live()`, `tbar rebuild`, and the probe
/// binary all need the same "default agents" list. Routing them through this
/// single factory makes adding a 7th agent a one-line change instead of a
/// three-place sync that has historically drifted (CLI shipped only 3/6
/// agents through v1.2.1).
public enum BuiltInSources {
    /// All built-in sources in display/scan order.
    ///
    /// OpenClaw is intentionally first so initial indexing surfaces quickly
    /// while Codex (~5k files on heavy users) is queued behind it.
    ///
    /// `daysBack` is honored by the two JSONL-walking sources (Claude, Codex);
    /// other sources have natural bounds (`hermes.state.db` is a SQLite file,
    /// `gemini`/`openclaw`/`opencode` discover everything every time) and
    /// ignore it.
    public static func all(daysBack: Int? = nil) -> [any InspectableUsageEventSource] {
        [
            OpenClawUsageEventSource(),
            CodexUsageEventSource(daysBack: daysBack),
            ClaudeUsageEventSource(daysBack: daysBack),
            HermesUsageEventSource(),
            GeminiUsageEventSource(),
            OpenCodeUsageEventSource(),
            WarpUsageEventSource(),
            PiUsageEventSource(),
            QoderUsageEventSource(),
            KiroUsageEventSource(),
            KimiUsageEventSource(),
            AntigravityUsageEventSource(),
        ]
    }

    /// One catalog entry per built-in source. The Settings (Built-in Plugins /
    /// Custom Sources tiles) and Diagnostics (Sources fallback) screens render
    /// from this single list so they can no longer drift from each other or
    /// from `all()`. Names and paths are pulled straight off the live sources,
    /// keeping the catalog honest by construction.
    public struct CatalogEntry: Identifiable, Sendable, Hashable {
        public let id: String          // AgentKind.rawValue
        public let name: String        // source's display name
        public let defaultPath: String // canonical root path
        public let agent: AgentKind
    }

    /// Built-in sources in display/scan order, paired with their canonical
    /// metadata. Derived from `all()` so adding a source stays a one-line change.
    public static func catalog() -> [CatalogEntry] {
        all().map { source in
            CatalogEntry(
                id: source.agent.rawValue,
                name: source.sourceName,
                defaultPath: source.rootPath,
                agent: source.agent
            )
        }
    }
}
