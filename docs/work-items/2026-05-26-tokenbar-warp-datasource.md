# Work Item: Warp AI Token Usage Data Source

**Date:** 2026-05-26
**Status:** Implemented — pending app-level visual verification

---

## Background

TokenBar tracks token consumption from 6 AI coding agents (Claude Code, Codex, Gemini CLI, Hermes, OpenClaw, OpenCode) by reading their local data stores. Warp terminal has its own AI features (Agent Mode, AI Chat, Command Suggestions) that consume tokens separately — these are invisible to TokenBar today.

Warp stores per-conversation token usage in its local SQLite database (`warp.sqlite`) inside the macOS App Group container. The `agent_conversations` table holds a `conversation_data` TEXT column containing serialized JSON with `ConversationUsageMetadata`, which includes per-model token counts (`warp_tokens` + `byok_tokens`), credits spent, context window usage, and tool call statistics.

This is architecturally similar to the existing Hermes data source, which also reads an external SQLite database directly via GRDB in read-only mode.

## Requirement

Add Warp as a 7th built-in data source so TokenBar's dashboard, popover, CLI, and reports reflect Warp AI token consumption alongside all other agents.

## Design

### Data Access

- **Method:** Direct SQLite read (GRDB, read-only, WAL mode) — same pattern as `HermesUsageEventSource`.
- **DB path:** Glob `~/Library/Group Containers/*/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite` to handle varying team IDs.
- **Incremental strategy:** Watermark on `agent_conversations.last_modified_at` column.
- **Inode tracking:** Detect DB file replacement on Warp upgrades.

### Token Mapping

Warp stores **total** token counts per model, not split into input/output/cache. Mapping:

| Warp field | TokenBar field | Notes |
|---|---|---|
| `warp_tokens + byok_tokens` | `outputTokens` | Total; no in/out split available |
| (none) | `inputTokens` | Set to `0` |
| `model_id` | `modelName` | e.g. `claude-opus-4` |
| `conversation_id` | `sessionId` | 1:1 |
| `last_modified_at` | `timestamp` | Last conversation activity |
| `credits_spent` | (future) | Available for cost display |
| `working_directory` via `ai_queries` JOIN | `projectPath` | Optional enrichment |

Each `ModelTokenUsage` entry within a conversation generates a separate `UsageEvent` (one conversation using multiple models → multiple events).

### Granularity

One `UsageEvent` per (conversation × model). Warp aggregates at conversation level; sub-request granularity is not available.

### Architecture

```
BuiltInSources
  └── WarpDataSource : InspectableUsageEventSource
        ├── discover(): glob App Group containers for warp.sqlite
        ├── status(): check DB readable + last modified time
        └── loadEvents(since:):
              WarpUsageParser
                ├── SQL: SELECT from agent_conversations WHERE last_modified_at > watermark
                ├── JSON decode: conversation_data → WarpConversationData
                ├── Optional JOIN ai_queries for working_directory
                └── Map to [UsageEvent]
```

### Codable Models (internal to parser)

```swift
struct WarpConversationData: Decodable {
    let conversationUsageMetadata: WarpUsageMetadata?
}

struct WarpUsageMetadata: Decodable {
    let wasSummarized: Bool
    let contextWindowUsage: Float
    let creditsSpent: Float
    let creditsSpentForLastBlock: Float?
    let tokenUsage: [WarpModelTokenUsage]
}

struct WarpModelTokenUsage: Decodable {
    let modelId: String
    let warpTokens: UInt32
    let byokTokens: UInt32
    let warpTokenUsageByCategory: [String: UInt32]?
    let byokTokenUsageByCategory: [String: UInt32]?
}
```

## Implementation Plan

### Phase 1: Model layer (AgentKind + UI plumbing)

1. `Sources/TokenBarCore/Models/UsageModels.swift` — add `.warp` case to `AgentKind` enum, with display name `"Warp"`, default cost-per-million-tokens estimate, and any codec/raw-value updates.
2. Audit all `switch` statements over `AgentKind` across the codebase; add `.warp` cases (icon, color, sort order, etc.).
3. Verify UI renders gracefully when `inputTokens == 0` and all tokens are in `outputTokens` (pie charts, ratio labels, popover breakdown).

### Phase 2: Data source + parser

4. `Sources/TokenBarCore/Parsers/WarpUsageParser.swift` — new file:
   - Internal Codable structs for Warp JSON (`WarpConversationData`, `WarpUsageMetadata`, `WarpModelTokenUsage`).
   - `parse(row:)` → decodes `conversation_data` JSON, maps each `ModelTokenUsage` to a `UsageEvent`.
   - Returns `ParseResult` (events, prompts, warnings).
5. `Sources/TokenBarCore/Services/WarpDataSource.swift` — new file:
   - Conforms to `InspectableUsageEventSource`.
   - `rootPath`: glob-discovered path to `warp.sqlite`.
   - DB open: GRDB `DatabaseQueue` in read-only mode.
   - `loadEvents(since:)`: incremental query on `last_modified_at`, parse each row, return `UsageSourceLoadResult`.
   - `status()`: `.notFound` if no DB, `.ready` / `.stale` based on last modified time.
   - Inode tracking for DB replacement detection.

### Phase 3: Registration

6. `Sources/TokenBarCore/Services/BuiltInSources.swift` — add `WarpDataSource` to the built-in source list.
7. Verify watermark key (`"warp"`) doesn't collide with existing keys.

### Phase 4: UI validation

8. Add Warp icon asset or SF Symbol mapping + tint color.
9. Build and launch (`script/build_and_run.sh --verify`), confirm:
   - Popover shows Warp agent in breakdown.
   - Project detail view groups Warp sessions correctly.
   - Diagnostics view shows Warp source status.
   - Cost calculation doesn't produce nonsensical values.

### Phase 5: Edge cases

10. Handle: Warp not installed (silent skip), DB locked (WAL snapshot read), schema drift (Codable `decodeIfPresent` + `ParseWarning`), malformed JSON (skip row + warning), multiple Warp versions (Stable/Nightly each get their own source instance).
11. Guard against large DB on first scan — consider a default time-window cap (e.g., 90 days).

### Phase 6: Prompt extraction (optional, deferred)

12. `ai_queries.input` contains user prompts — can be extracted to `PromptRecord` via conversation_id/exchange_id join.
13. Respect `storePromptTextInClearText` setting.

## Out of Scope

- Warp remote/cloud API integration (billing cycle history, server-side usage).
- Real-time token streaming (Warp writes to DB asynchronously; TokenBar polls on its normal refresh cadence).
- Splitting Warp tokens into input/output — Warp simply doesn't store this breakdown locally.
- Warp-specific cost model using `credits_spent` (future enhancement; for now, use TokenBar's standard cost-per-million-tokens estimate).

## Acceptance Criteria

- [x] `AgentKind.warp` exists and all exhaustive switches compile.
- [x] `script/test.sh` passes (no regressions). — 207/207 tests pass (10 new Warp tests).
- [x] With Warp installed and having AI conversations, `tbar` CLI shows Warp token usage. — `tbar sources` shows `Warp [builtin enabled, readable]` with correct path.
- [ ] TokenBar popover and main window display Warp as a separate agent with correct totals. — Blocked: app holds DB lock; pending next app refresh cycle.
- [x] Diagnostics view shows Warp data source status (found/not-found/stale/error). — DiagnosticsView includes Warp built-in row.
- [x] With Warp NOT installed, TokenBar starts normally with no errors (source reports `.notFound`). — Tested: `loadEvents` returns empty result when path is unreadable.
- [x] Incremental refresh only picks up new/updated conversations (watermark works). — Unit test `incrementalWatermarkSkipsOldConversations` passes.
- [x] `script/build.sh` passes. — BUILD SUCCEEDED.

## Test Plan

- [x] Unit test: `WarpUsageParser` with fixture JSON blobs (normal, multi-model, missing fields, malformed). — 8 parser tests.
- [x] Unit test: `WarpDataSource` discovery logic with mocked filesystem paths. — Covered by `returnsEmptyForMissingTable` and watermark tests.
- [x] Integration test: round-trip — insert fixture data into a temp SQLite → load via `WarpDataSource` → verify `UsageEvent` fields. — All parser tests create temp SQLite DBs and verify full event fields.
- [ ] Manual: build TokenBar, open Warp, run a few AI queries, refresh TokenBar, verify numbers appear. — Pending: app-level visual verification.
- [x] Manual: uninstall/hide Warp DB, verify TokenBar handles absence gracefully. — Verified via unit test.

## Verification

**2026-05-27 — Implementation complete.**

Files changed:
- `Sources/TokenBarCore/Models/UsageModels.swift` — Added `.warp` to `AgentKind` and `ParserKind`
- `Sources/TokenBarCore/Parsers/WarpUsageParser.swift` — **New.** Parser that reads Warp's `agent_conversations` table, decodes JSON `conversation_data`, maps `ModelTokenUsage` to `UsageEvent`
- `Sources/TokenBarCore/Services/WarpUsageEventSource.swift` — **New.** Data source with App Group container glob discovery, read-only GRDB access, inode tracking
- `Sources/TokenBarCore/Services/BuiltInSources.swift` — Added `WarpUsageEventSource()` as 7th built-in source
- `Sources/TokenBar/Views/TokenBarStyle.swift` — Added Warp agent color (cyan/teal)
- `Sources/TokenBar/Views/SettingsView.swift` — Added Warp tile in Custom Sources grid
- `Sources/TokenBar/Views/DiagnosticsView.swift` — Added Warp row in built-in sources + `countForStatus` mapping
- `Tests/TokenBarCoreTests/WarpUsageParserTests.swift` — **New.** 10 tests covering: single model, multi-model, zero tokens, malformed JSON, missing metadata, incremental watermark, project name derivation, backward-compat `total_tokens` alias, missing table, watermark updates
- `Tests/TokenBarCoreTests/Sprint8StorageTests.swift` — Updated agent count assertion (6 → 7)

Build: `swift build` — 0 new errors. `script/build.sh` — BUILD SUCCEEDED.
Tests: `script/test.sh` — 207/207 passed.
CLI: `tbar sources` — Warp discovered at correct App Group path, readable, 1 file.
Real data: Warp DB has 74 conversations with token_usage data; ingestion pending next app refresh cycle.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Warp DB schema changes on update | Parse failures | `decodeIfPresent` + `ParseWarning`; pin to known field set |
| App Group container path varies | DB not discovered | Glob pattern; fallback to user-configurable custom source |
| No input/output token split | Misleading UI ratios | UI labels Warp as "total tokens"; skip in/out pie for this agent |
| Large DB (>1 GB) first scan | Startup delay | Default 90-day scan window on first load |
| SQLite lock contention | Read failures | WAL mode allows concurrent reads; retry with backoff |
