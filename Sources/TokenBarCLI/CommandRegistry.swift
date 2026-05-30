import Foundation
import TokenBarCore

/// Static metadata for every CLI command. Powers `tbar help`, the per-command
/// `--help` output, and `tbar schema` introspection. Keep in sync when adding
/// new commands.
struct CommandDescriptor: Encodable {
    let name: String
    let summary: String
    let filters: [String]
    let sortFields: [String]
    let rowFields: [String]
    let extras: [String]
    let defaultLimit: Int?
}

enum CommandRegistry {
    static let commonFilters = [
        "--db <path>",
        "--days N (default 30, 0 = all-time)",
        "--since ISO",
        "--until ISO",
        "--day YYYY-MM-DD",
        "--project NAME",
        "--agent KIND",
        "--model NAME",
        "--session ID",
        "--limit N (0 = unlimited)",
        "--sort field[:asc|desc]",
        "--json",
        "--ndjson",
    ]

    static let all: [CommandDescriptor] = [
        CommandDescriptor(
            name: "events",
            summary: "List atomic token events (one row per assistant turn).",
            filters: commonFilters,
            sortFields: ["timestamp", "tokens", "input", "output", "cache"],
            rowFields: [
                "id", "timestamp", "agent", "agentDisplayName",
                "projectName", "projectPath", "sessionId", "modelName",
                "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "totalTokens",
                "reasoningTokens", "sourcePath", "parser",
            ],
            extras: [],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "prompts",
            summary: "List prompt history with content + agent + project + session.",
            filters: commonFilters + ["--query SUBSTR", "--id PROMPT_ID"],
            sortFields: ["timestamp", "contentLength"],
            rowFields: [
                "id", "timestamp", "agent", "agentDisplayName", "projectName",
                "sessionId", "modelName", "sourcePath", "content",
                "contentHash", "contentLength", "eventId",
            ],
            extras: [],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "projects",
            summary: "List distinct projects with aggregated token stats.",
            filters: [
                "--db <path>",
                "--days N", "--since ISO", "--until ISO", "--day YYYY-MM-DD",
                "--limit N", "--sort field[:asc|desc]",
                "--json", "--ndjson",
            ],
            sortFields: ["tokens", "name", "lastSeen", "eventCount"],
            rowFields: [
                "name", "eventCount", "promptCount",
                "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "totalTokens",
                "firstSeen", "lastSeen", "distinctAgents", "distinctModels",
            ],
            extras: [],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "sessions",
            summary: "List distinct sessions with aggregated token stats.",
            filters: commonFilters,
            sortFields: ["lastSeen", "tokens", "firstSeen", "eventCount", "promptCount"],
            rowFields: [
                "sessionId", "projectName", "agent", "agentDisplayName",
                "modelName", "firstSeen", "lastSeen",
                "eventCount", "promptCount",
                "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "totalTokens",
            ],
            extras: [],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "models",
            summary: "List distinct models with aggregated token stats + estimated cost.",
            filters: commonFilters,
            sortFields: ["tokens", "name", "eventCount", "cost"],
            rowFields: [
                "name", "distinctAgents", "eventCount",
                "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "totalTokens",
                "estimatedCostUSD", "costSource",
            ],
            extras: [],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "agents",
            summary: "List agents with non-zero events in the selected window.",
            filters: [
                "--db <path>",
                "--days N", "--since ISO", "--until ISO", "--day YYYY-MM-DD",
                "--project NAME", "--model NAME",
                "--limit N", "--sort field[:asc|desc]",
                "--json", "--ndjson",
            ],
            sortFields: ["tokens", "name", "eventCount"],
            rowFields: [
                "kind", "displayName", "eventCount", "promptCount",
                "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "totalTokens",
                "distinctProjects", "distinctModels",
            ],
            extras: [],
            defaultLimit: 50
        ),
        CommandDescriptor(
            name: "summary",
            summary: "Aggregated token stats with optional --group-by dimensions.",
            filters: commonFilters + [
                "--group-by project,agent,model,day,hour-of-day,session",
            ],
            sortFields: ["tokens", "input", "output", "cache", "count", "cost"],
            rowFields: [
                "groupBy", "rows",
                "(per-row) inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, totalTokens, eventCount, promptCount, estimatedCostUSD, costSource",
            ],
            extras: [
                "--group-by accepts a comma-separated list. Empty = single global row.",
            ],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "timeline",
            summary: "Time-bucketed aggregation. --bucket day|hour|hour-of-day.",
            filters: commonFilters + [
                "--bucket day|hour|hour-of-day (default day)",
                "--group-by project,agent,model,session (per-bucket subgroup)",
            ],
            sortFields: [],
            rowFields: [
                "bucket", "groupBy", "buckets",
                "(per-bucket) bucketStart, label, rows[], inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens, totalTokens, eventCount, promptCount",
            ],
            extras: [],
            defaultLimit: 0
        ),
        CommandDescriptor(
            name: "sources",
            summary: "List data sources (built-in + custom) with status.",
            filters: ["--db <path>", "--json", "--ndjson"],
            sortFields: [],
            rowFields: [
                "name", "type", "plugin", "rootPath", "globPattern",
                "enabled", "isReadable", "discoveredFileCount",
                "eventCount", "promptCount", "latestEventTimestamp",
            ],
            extras: [],
            defaultLimit: nil
        ),
        CommandDescriptor(
            name: "checkpoints",
            summary: "List recent checkpoint runs from the rebuild history.",
            filters: ["--db <path>", "--limit N (default 20)", "--json", "--ndjson"],
            sortFields: ["id"],
            rowFields: [
                "id", "startedAt", "endedAt", "trigger",
                "eventsAdded", "promptsAdded", "warnings", "durationMs", "error",
            ],
            extras: [],
            defaultLimit: 20
        ),
        CommandDescriptor(
            name: "warnings",
            summary: "List parser warnings from the latest checkpoint.",
            filters: ["--db <path>", "--limit N (default 50)", "--json", "--ndjson"],
            sortFields: [],
            rowFields: ["sourceName", "sourcePath", "lineNumber", "message"],
            extras: [],
            defaultLimit: 50
        ),
        CommandDescriptor(
            name: "skills",
            summary: "List scanned Library skills (scope, name, tokens, path).",
            filters: ["--db <path>", "--limit N", "--json", "--ndjson"],
            sortFields: [],
            rowFields: [
                "scope", "scopeRoot", "name", "estimatedTokens", "path", "isBroken", "pluginId",
            ],
            extras: ["Reads the library_skills table (populated on rebuild)."],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "mcp",
            summary: "List scanned MCP servers (scope, source_file, name, command).",
            filters: ["--db <path>", "--limit N", "--json", "--ndjson"],
            sortFields: [],
            rowFields: [
                "scope", "sourceFile", "name", "command", "args", "estimatedTokens", "isDisabled", "projectRoot",
            ],
            extras: ["Reads the library_mcp table (populated on rebuild)."],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "plugins",
            summary: "List installed Claude Code plugins (full_id, version, scope, path).",
            filters: ["--db <path>", "--limit N", "--json", "--ndjson"],
            sortFields: [],
            rowFields: [
                "fullId", "name", "marketplace", "version", "scope",
                "installPath", "projectPath", "installedAt",
            ],
            extras: ["Reads the library_plugins table (populated on rebuild)."],
            defaultLimit: 100
        ),
        CommandDescriptor(
            name: "schema",
            summary: "Self-describing introspection. Lists commands, dimensions, sources.",
            filters: ["--db <path>", "--json"],
            sortFields: [],
            rowFields: [
                "schemaVersion", "databasePath", "dataWindow",
                "distinctProjects", "distinctAgents", "distinctModels",
                "commands", "groupByDimensions", "bucketKinds",
            ],
            extras: [],
            defaultLimit: nil
        ),
        CommandDescriptor(
            name: "rebuild",
            summary: "Rescan all local agent history and rebuild the index (write).",
            filters: [
                "--db <path>", "--background",
                "--cpu-percent N (1-100)", "--json",
            ],
            sortFields: [],
            rowFields: [],
            extras: ["This is the only write command. Equivalent to the app's Reparse all."],
            defaultLimit: nil
        ),
        CommandDescriptor(
            name: "prompt",
            summary: "Saved-prompt templates. Subcommands: list, get <slug>.",
            filters: ["--db <path>"],
            sortFields: [],
            rowFields: ["slug", "title", "body"],
            extras: [],
            defaultLimit: nil
        ),
    ]

    static func descriptor(named name: String) -> CommandDescriptor? {
        all.first(where: { $0.name == name })
    }

    static func helpSummary(programName: String) -> String {
        var lines: [String] = []
        lines.append("Usage:")
        lines.append("  \(programName) [--db <path>] <command> [filters] [options]")
        lines.append("")
        lines.append("Commands:")
        for descriptor in all {
            let padded = descriptor.name.padding(toLength: 14, withPad: " ", startingAt: 0)
            lines.append("  \(padded) \(descriptor.summary)")
        }
        lines.append("")
        lines.append("Run `\(programName) <command> --help` for command-specific filters.")
        return lines.joined(separator: "\n")
    }

    static func helpDetail(_ descriptor: CommandDescriptor, programName: String) -> String {
        var lines: [String] = []
        lines.append("\(programName) \(descriptor.name)")
        lines.append("")
        lines.append(descriptor.summary)
        lines.append("")
        if let defaultLimit = descriptor.defaultLimit {
            lines.append("Default limit: \(defaultLimit) (use --limit 0 for unlimited)")
            lines.append("")
        }
        if !descriptor.filters.isEmpty {
            lines.append("Filters:")
            for filter in descriptor.filters {
                lines.append("  \(filter)")
            }
            lines.append("")
        }
        if !descriptor.sortFields.isEmpty {
            lines.append("Sort fields: \(descriptor.sortFields.joined(separator: ", "))")
            lines.append("")
        }
        if !descriptor.rowFields.isEmpty {
            lines.append("Row fields:")
            for field in descriptor.rowFields {
                lines.append("  \(field)")
            }
            lines.append("")
        }
        for extra in descriptor.extras {
            lines.append(extra)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
