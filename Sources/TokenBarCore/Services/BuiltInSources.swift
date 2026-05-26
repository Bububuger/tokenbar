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
        ]
    }
}
