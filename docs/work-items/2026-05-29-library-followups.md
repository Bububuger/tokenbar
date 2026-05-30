# Goal: Library tab follow-ups (post real-data landing)

Working dir: `/Users/travis/Documents/TeamFile/claude-workspace/tokenbar`
Branch: `main` (all prior Library work still uncommitted — see Dependencies)
Source handoff: `HANDOFF.md` · driving plan: `docs/work-items/2026-05-28-library-real-data.md`

This is the goal/checklist for the remaining items the previous agent left after wiring real
disk scanning + DB persistence into the Library tab. **Item #1 (persist `ScannedClaudePlugin`)
is already DONE** (v16 migration + `upsertLibraryPlugins`/`loadLibraryPlugins` + runtime wiring +
`installedAt` fractional-seconds fix, verified end-to-end). The items below are #2–#7.

---

## Success criteria (the whole goal)

- `tbar skills` / `tbar mcp` / `tbar plugins` print real rows from the DB (#2).
- No remaining `ISO8601DateFormatter()`-per-event in the 4 cold parsers (#3).
- MCP-tab and Plugins-tab row buttons either do real work or are removed — no misleading
  empty `Button {}` (#4, #5).
- `LibraryMcpItem` / `LibraryPluginItem` use stable IDs; SwiftUI diffing survives a rescan (#6).
- Work committed on a branch with the suggested boundaries; the 6 untracked files are `git add`-ed (#7).
- `swift build` + `xcodebuild` green; app relaunches and Library tab still shows real data.

---

## Dependencies & operating notes

**Build / relaunch (verified working this session):**
- App bundle to launch: `build/Build/Products/Debug/TokenBar.app` (xcodebuild output).
  **Do NOT** use `build/DerivedData/...` — stale.
- Relaunch recipe (codesign step is mandatory or `open` silently refuses after pkill):
  ```
  APP=build/Build/Products/Debug/TokenBar.app
  pkill -f TokenBar.app; sleep 1
  codesign --force --deep --sign - "$APP"
  open "$APP"
  ```
- Build app target: `xcodebuild -project TokenBar.xcodeproj -scheme TokenBar -configuration Debug -derivedDataPath build build`
- Build core only (faster): `swift build --target TokenBarCore`
- DB lives at `~/Library/Application Support/TokenBar/tokenbar.sqlite` (currently at migration **v16**).
  - verify: `sqlite3 "$DB" "SELECT scope,scope_root,COUNT(*) FROM library_skills GROUP BY 1,2;"`
  - migrations: `sqlite3 "$DB" "SELECT identifier FROM grdb_migrations ORDER BY rowid;"`

**Hard-won rules (don't relearn these):**
- Migrations are **immutable once run anywhere** — GRDB tracks by `identifier`. Add a new vN, never edit.
- Never `Dictionary(uniqueKeysWithValues:)` on user data — same-named skills across roots crash it.
- `NSLog` inside an async `Task` doesn't surface in `log show` — verify via SQLite queries instead.
- The Library tab does NOT FSEvent-watch project roots (handle explosion); project scope is ≤60s
  stale via the fallback timer. Accepted trade.

**Untracked files that must be `git add`-ed before commit (#7):**
```
Sources/TokenBarCore/Models/LibraryModels.swift
Sources/TokenBarCore/Services/LibraryConflictDetector.swift
Sources/TokenBarCore/Services/LibraryWatcher.swift
Sources/TokenBarCore/Services/McpScanner.swift
Sources/TokenBarCore/Services/SkillScanner.swift
Sources/TokenBarCore/Services/ThrottledDelayer.swift
docs/work-items/2026-05-28-library-real-data.md
docs/work-items/2026-05-29-library-followups.md   (this file)
```

---

## Checklist

### [x] #2 — `tbar` CLI commands: `skills` / `mcp` / `plugins`
Working dir focus: `Sources/TokenBarCLI/`
Depends on: #1 (DONE — `library_plugins` table + `loadLibraryPlugins` exist).
Pattern to copy: `tbar projects` in `Sources/TokenBarCLI/ListCommands.swift`; register in
`CommandRegistry.swift`; render via `Output.swift`.
Data source: `UsageStore.loadLibrarySkills()` / `loadLibraryMcp()` / `loadLibraryPlugins()`
(all already public on the actor).
- [x] `skills` — rows of scope · scope_root · name · tokens · path
- [x] `mcp` — rows of scope · source_file · name · command
- [x] `plugins` — rows of full_id · version · scope · install_path (+ installed_at now populated)
- [x] register all three in `CommandRegistry`; confirm they appear in `tbar --help`
Done: new `Sources/TokenBarCLI/LibraryCommands.swift` (SkillsCommand/McpCommand/PluginsCommand),
dispatched in `Entry.swift`, descriptors in `CommandRegistry.swift`, registry test updated.
Verified: `tbar skills` 100/365, `tbar mcp` 5/5, `tbar plugins` 6/6 match SQLite; `--json`/`--ndjson` work.

### [x] #3 — Cache `ISO8601DateFormatter` in the 4 cold parsers
Pattern: the Claude/Codex fix already landed — use `nonisolated(unsafe) static let` shared
formatter(s). `ISO8601DateFormatter.date(from:)` is thread-safe on macOS 10.15+.
Exact sites (verified 2026-05-29):
- [x] `Sources/TokenBarCore/Parsers/GeminiUsageParser.swift` — shared static formatters
- [x] `Sources/TokenBarCore/Parsers/OpenClawUsageParser.swift` — dropped the redundant NSLock
  wrapper (`LockedOpenClawISO8601Parser`), now lock-free shared statics
- [x] `Sources/TokenBarCore/Services/PluginExecutableRunner.swift` — shared static (output formatter)
- [x] `Sources/TokenBarCore/Services/CustomSources.swift` — shared static formatters
Verify: `swift build --target TokenBarCore` green; full test suite (244) passes.

### [x] #4 — Wire MCP-tab row actions (or remove)
File: `Sources/TokenBar/Views/LibraryView.swift`
Decision (user, 2026-05-29): **reveal-only, remove the rest.**
Done: removed row "Check" + ellipsis no-ops, replaced the fake toggle switch (`loaded` was always
false) with a static `server.rack` icon, removed `toggleSwitch`; removed scope-card "Check all";
wired scope-card "Reveal" → `NSWorkspace.activateFileViewerSelecting(dir.path)`; removed ribbon
"Reload all"/"Unload all" and toolbar "Add server…".

### [x] #5 — Wire Plugins-tab row actions (or remove)
File: `Sources/TokenBar/Views/LibraryView.swift`
Decision (user, 2026-05-29): **read-only + Reveal, drop the fake state.**
Done: dropped `state` from `LibraryPluginItem` (was hardcoded `"active"`), added `path` (real
install path); removed Enable/Disable + ellipsis no-ops, added a Reveal-install-path folder button;
removed the Active/Disabled segmented filter (fiction) and wired the Plugins "Rescan" button to a
real `rebuildLibrarySnapshot(trigger: "manual.rescan")`; tab meta now reads "N installed".

### [x] #6 — Stable IDs for `LibraryMcpItem` / `LibraryPluginItem`
File: `Sources/TokenBar/Views/LibraryView.swift`
Done: `LibraryMcpItem.id` → `"\(scope):\(sourceFile):\(name)"` (matches DB PK), passed at the
construction site; `LibraryPluginItem.id` → `plugin.fullId`. Both no longer mint a new UUID per
render, so SwiftUI diffing survives a rescan.

### [ ] #7 — Commit + PR
65+ uncommitted files. User had not requested commit as of handoff — **confirm before committing.**
Suggested commit boundaries (loose, from handoff):
- [ ] `feat(library): real disk scanning + DB persistence` — LibraryModels, SkillScanner, McpScanner,
  LibraryWatcher, LibraryConflictDetector, ThrottledDelayer, v14/v15/**v16** migrations, repository
  methods, runtime integration, pbxproj
- [ ] `feat(library): collapsible per-root cards + real delete/reveal actions` — LibraryView.swift
- [ ] `refactor(library): remove graph view` — delete LibraryGraphViews.swift, simplify SkillsBody/MCPBody, drop pbxproj refs
- [ ] `perf(parsers): cache ISO8601DateFormatter` — Claude+Codex (landed) + the 4 from #3
- [ ] `fix(popover): restore Today KPI card frames`
- [ ] `fix(app): stop sidebar TextField from auto-focusing on launch`
- [ ] **don't forget** `git add` the untracked files listed in Dependencies above.

---

## Suggested order

#3 first (pure perf, no decisions, low risk) → #6 (mechanical, unblocks clean diffing) →
#2 (additive CLI, data already there) → #4 + #5 (need product decisions on real vs remove —
**ask user**) → #7 last (after user green-lights commit).
