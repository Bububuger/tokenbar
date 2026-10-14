# `tbar` CLI reference

`tbar` reads the same local SQLite database as the TokenBar app. Homebrew
installs the CLI at `$(brew --prefix)/bin/tbar`; a source checkout provides
`script/tbar`, which invokes `swift run --quiet tbar` and requires the Swift
toolchain. Pass `--db <path>` to select another database.
Opening a database can initialize or migrate its schema, even for a read
query; use a copy if the original file must remain byte-for-byte unchanged.

## Commands

There are 17 top-level commands (excluding `help`):

| Purpose | Commands |
| --- | --- |
| Usage rows | `events`, `prompts` |
| Usage aggregations | `projects`, `sessions`, `models`, `agents`, `summary`, `timeline` |
| Index introspection | `sources`, `checkpoints`, `warnings`, `schema` |
| Library snapshots | `skills`, `mcp`, `plugins` |
| Saved templates | `prompt list`, `prompt get <slug>` |
| Rebuild usage history | `rebuild` |

Use `tbar help`, `tbar <command> --help`, and `tbar schema --json` to inspect
the command registry. Options are command-specific, not universal:

- Usage queries default to a rolling 30-day window. Use `--days 0` for all
  indexed history, `--days N` for a rolling window, or `--since`/`--until`
  for explicit bounds. Do not combine `--days` with `--since`/`--until`.
- `--since` is inclusive and `--until` is exclusive. Bare `YYYY-MM-DD`
  dates mean local midnight; ISO 8601 timestamps are also accepted.
  `now` is not a supported date value. Omit `--until` for no upper bound.
  `--day YYYY-MM-DD` selects one local calendar day and overrides other
  window options.
- `projects` accepts window, limit, and sort options, but rejects
  `--project`, `--agent`, `--model`, and `--session`. `agents` accepts
  `--project` and `--model`, but rejects `--agent` and `--session`.
- `prompts` supports case-insensitive `--query SUBSTR` and exact `--id`.
  Its current implementation does not apply `--model`, even though the
  shared help lists it; inspect the returned `modelName` when needed.
- `summary` has no grouping by default. Use `--group-by` with comma-separated
  dimensions: `project`, `agent`, `model`, `day`, `hour-of-day`, `session`.
  `timeline` supports `--bucket day|hour|hour-of-day` and subgroup dimensions
  listed in its help.
- `sources`, `checkpoints`, `warnings`, `skills`, `mcp`, and `plugins` do
  not apply usage-window or project/agent/model/session filters. Library
  commands read the latest stored scan, not historical inventories.
- Row limits default to 100 for most usage and Library lists, 50 for
  `agents` and `warnings`, and 20 for `checkpoints`; `timeline` is unlimited
  by default. `--limit 0` removes the requested row limit, although
  `checkpoints` still caps results at 1,000. Sort fields vary by command.

## Output and examples

The 15 read-query commands support `--json`. All of those except `schema`
also support `--ndjson`; the two flags are mutually exclusive. `schema`
always emits JSON. `rebuild` supports text or `--json`, while `prompt`
supports neither output flag: `list` prints tab-separated slug/title pairs
and `get` prints the saved body.

JSON query results use a command-keyed envelope, not a top-level row array.
NDJSON emits one row per line without the envelope.

```bash
tbar summary --days 30 --group-by project,agent,model --limit 0
tbar projects --since 2026-04-01
tbar prompts --agent "Claude Code" --limit 20
tbar timeline --bucket hour --days 7
tbar sessions --project tokenbar --json | jq '.sessions.sessions[] | select(.totalTokens > 1e6)'
tbar summary --days 0 --json | jq '.summary.totals'
tbar schema --json | jq '.schema.dataWindow'
tbar skills --limit 0 --json | jq '.skills'
tbar mcp --limit 0 --json | jq '.mcp'
tbar plugins --limit 0 --json | jq '.plugins'
tbar prompt list
tbar prompt get my-template
```

`schema.dataWindow` describes the entire database. For a selected time
window, use `summary.totals` and the query envelope's `window`. Usage-list and
grouped-summary JSON includes `count` and `totalCount`; check them before
treating a limited result as complete.

Token fields use these semantics:

- `inputTokens` and `uncachedInputTokens` both mean uncached input.
- `totalInputTokens` = uncached input + cache-read + cache-creation tokens.
- `totalTokens` = total input + output tokens.
- Cache read and creation are separate JSON fields: `cacheReadTokens` and
  `cacheCreationTokens`. Do not assume a combined `cacheTokens` field.

CLI costs prefer source-reported values and otherwise use per-agent
defaults. `costSource` is `actual`, `defaults`, or `mixed`. App pricing
overrides are not loaded by the CLI. Cursor events without reported costs
contribute zero to CLI cost totals; that means unavailable cost, not free
usage.

## What `tbar mcp` shows

`tbar mcp` lists MCP configuration inventory stored by the app's Library
scanner. It does not start an MCP server, connect to those servers, or
expose TokenBar queries over MCP.

The app scans user servers from `~/.claude.json` and project servers from
`.mcp.json` in existing projects listed by `~/.claude.json`. Project disabled
state comes from each project's `disabledMcpjsonServers` list. Rows include
scope, source file, name, command, arguments, estimated tokens, disabled
state, and optional project root. Token estimates are static heuristics,
not measured tool-schema usage.

`skills`, `mcp`, and `plugins` read persisted `library_*` tables. Refresh
the Library in the app if they are empty or stale. `tbar rebuild` reparses
usage history; it does not run the Library scanners.

## Rebuilding

`rebuild` is the CLI's explicit index-writing command. It clears and
reparses local usage history without editing upstream logs, while retaining
the stored Cursor account snapshot. It does not fetch fresh Cursor account
data. See the [history rebuild runbook](runbooks/history-rebuild.md) before
using it.

`--background` lowers priority and enables throttling; it does not detach
the process. `--cpu-percent N` accepts 1–100 and also enables throttling.
The command remains in the foreground until it finishes. Check
`rebuildError`, warnings, and source readability in its JSON output rather
than relying only on the exit status.
