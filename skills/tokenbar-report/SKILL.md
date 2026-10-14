---
name: tokenbar-report
description: Generate a Spotify-Wrapped-style multi-persona HTML report summarizing the user's TokenBar / `tbar` AI usage data. Use this skill whenever the user asks for a token usage report, annual recap, "year-in-review" of their AI coding, a personal AI portrait, prompt analysis, agent usage breakdown, or any phrasing along the lines of "tbar wrapped", "tokenbar 报告", "做个年度总结", "看看我都用 AI 干了什么", "I used Claude/Codex a lot — summarize my usage". Trigger even when the user mentions only "token report", "show me my usage", "做个我的 prompt 画像", or anything that wants a presentable HTML view over their TokenBar data. The skill produces one folder on the Desktop containing three HTML reports — one per anime power-system persona (JOJO stand-stats / BLEACH 斩魄刀档案 / HxH 念能力档案) — each paired with a uniquely styled visual theme, plus an interactive card-draw landing `index.html` that randomizes the deck order on every load. Do not invoke for live "what's my token count right now" queries — that is `tbar` itself, not this skill.
---

# tokenbar-report — what this skill does

Run end-to-end, the skill produces a folder at
`~/Desktop/tokenbar-report-YYYY-MM-DD/` containing:

- `index.html` — **card-draw landing page**. Three face-down cards, fanned.
  The user clicks "DRAW" (or any card / "RESHUFFLE"), a card flips, and the
  page navigates to the chosen persona. The deck shuffles on every load —
  each refresh feels different.
- `01-jojo.html` / `02-bleach.html` / `03-hxh.html` — three HTML reports,
  one per persona, each in its own visual style (JOJO manga panel / 死神
  护廷十三队公文 / 猎人念能力档案）
- `data.json` — the aggregated source payload (for debugging / future
  re-renders)

Every report shows the same underlying data; what changes is the **lens** —
each persona owns 2-3 metric categories with a vocabulary the others are
forbidden to touch. The goal is three genuinely different reads of the same
dataset, not three wrappers around the same observation.

## The 3 personas at a glance (v6)

| Idx | Key | 显示名 | Lens (what *only* this persona owns) |
|---|---|---|---|
| 01 | `jojo`   | JOJO   | A-E 六维 / prompt 原文片段引用 / 替身命名（真实 S 级白名单） |
| 02 | `bleach` | 死神   | 灵压 / 始解 / 卍解 / 护廷十三队 / 真实斩魄刀白名单 |
| 03 | `hxh`    | 猎人   | 念能力六系 / 自创 named ability / 制约与誓约 |

All three share the same architecture: **a 6-axis grading derived from the
user's data picks an iconic asset from the persona's universe** (a real S-tier
JoJo Stand, a real captain-level Zanpakuto, or a primary nen type + an
original named ability). The flattering baseline is the point — every
persona maps the user to a respected named asset, never the weakest tier.

`references/personas.md` — human-readable overview.
`references/personas/_contract.md` — **shared contract** every subagent must
load (number ownership matrix, vocabulary blacklist, output shape).
`references/personas/<key>.md` — per-persona spec (owned vocabulary, the 3
signature sections, headline-stat renaming).

**v6 lens-isolation gate**: after rendering, run
`scripts/measure_overlap.py <output_dir>` and verify max pairwise overlap is
strictly < **0.30** (Jaccard on 3-char n-grams, chrome stripped). With three
files there are only 3 pairs (vs. 15 in v5), so a single leaking term moves
the max meaningfully — keep persona vocabularies clean.

# Workflow

Execute these steps in order. Steps 0-2 are interactive (confirm with the
user before continuing). Steps 3-9 are mechanical and don't need check-ins
unless something fails.

## Step 0 — preflight: check the local index before installing or rebuilding

This skill reads the local TokenBar SQLite index. A source-built CLI can
read an existing index without `/Applications/TokenBar.app`, so a missing
app alone does not prove there is no data. If a usable `tbar` already exists
(see Step 1), inspect `tbar schema --json` first and use that index. Do not
rebuild merely to generate a report.

1. Test whether the app is on disk:

   ```bash
   test -e /Applications/TokenBar.app
   ```

2. If it exists, skip to Step 1.

3. If neither the app nor a usable CLI exists, ask the user:

   > TokenBar.app 还没装。要我帮你装吗？
   >
   > 我会执行 `brew install --cask Bububuger/tap/tokenbar`，然后跑一次
   > `tbar rebuild --background --json` 把本地 Claude / Codex / Gemini 等
   > agent 的历史 token 数据扫进 DB。耗时取决于历史量和文件可读性，
   > 扫完先检查结果，再生成报告。

4. If the user agrees, install and rebuild:

   ```bash
   brew tap Bububuger/tap 2>/dev/null || true
   brew install --cask Bububuger/tap/tokenbar
   tbar rebuild --background --json > /tmp/tokenbar-report-rebuild.json
   ```

   Verify `/Applications/TokenBar.app` and `$(brew --prefix)/bin/tbar`;
   the Homebrew prefix differs between Apple Silicon and Intel Macs.
   `--background` enables lower-priority, throttled indexing; it still
   blocks until completion. Inspect `rebuildError`, warnings, and source
   readability in the saved JSON. A zero exit status alone does not prove
   the history was indexed successfully. See
   `../../docs/runbooks/history-rebuild.md` for the full rebuild checks.

5. Confirm the DB picked something up:

   ```bash
   tbar schema --json | jq '.schema.dataWindow.eventCount'
   ```

   A positive integer confirms indexed events exist. If it is `0`, inspect
   `tbar sources --json`, `tbar checkpoints --json`, and `tbar warnings --json`
   for an empty index, unreadable sources, or parsing failures. Do not infer
   that the user has no local agent history solely from an empty index.
   Stop report generation until there is data in the requested window.

6. If the user declines installation, stop the skill politely — without
   usable local index there is no data to summarize. Do not fabricate.

## Step 1 — locate the CLI

`scripts/collect.sh` accepts an explicit `--tbar /path/to/tbar`. Otherwise
it resolves the CLI in this order:

1. Select `$TOKENBAR_REPO`, or the existing
   `~/Documents/workspace/projects/tokenbar` checkout.
2. In that checkout, prefer `.build/release/tbar`, then `.build/debug/tbar`.
   If neither exists and Swift is available, build once with
   `swift build --product tbar`; if no binary is produced, it tries
   `script/tbar` (which also requires Swift). A failed build can stop the
   script; pass `--tbar` explicitly to use an installed CLI instead.
3. Fall back to `tbar` on `$PATH`.

Set `TBAR` to the resolved executable for the manual checks below, and pass
`--tbar "$TBAR"` to collection so all checks use the same binary. Homebrew
users do not need a source checkout. If nothing resolves, ask for the CLI
or checkout location, or return to the installation choice in Step 0.

## Step 2 — confirm the time window with the user

Read the data window first:

```bash
"$TBAR" schema --json | jq '.schema.dataWindow'
```

Then tell the user what's available and ask for confirmation:

> 你的数据覆盖 `<earliest>` → `<latest>` (`N` 天，`M` events)。
> 默认我会把整个区间都纳入报告。要不要换：(a) 最近 30 天 / (b) 最近一年 /
> (c) 某个具体年月 / (d) 自定义 since-until？

Lock the window before continuing. Translate the user's reply into one of:
- `--days 0` (all-time, default)
- `--days N`
- `--since YYYY-MM-DD --until YYYY-MM-DD` (end date is exclusive)
- `--since 2026-01-01 --until 2027-01-01` (example: the full 2026 calendar year)

Bare dates use local midnight. To include an entire end date, use the
following day as `--until`. `--days N` starts N days before the query time,
not at local midnight. `now` is not a valid `--until` value;
omit the upper bound or supply an ISO 8601 timestamp.

If the user used a vague phrase, map it BEFORE running collect.sh:

| User phrase | Flag |
|---|---|
| "wrapped" / "recap" with no period | Offer `--days 0` and confirm; label the report **all-time** if chosen |
| "年度" / "year" / "annual" with no named year | Ask which calendar year, then use its exact start and exclusive end |
| "本年" / "this year" / "今年" | `--since <January 1 this year>` (through the latest indexed event) |
| A named year or quarter | `--since <first day> --until <first day of the following period>` |
| "本季度" / "this quarter" | `--since <first day of this quarter>` |
| "本月" / "this month" | `--since <first day of this month>` |
| "last month" | `--since <first day of previous month> --until <first day of this month>` |
| "最近一个月" / "last 30 days" | `--days 30` |
| "本周" / "this week" | `--since <start of this week in the user's locale>` |
| "last week" | `--since <start of previous week> --until <start of this week>` |
| "最近一周" / "last 7 days" | `--days 7` |
| "今天" / "today" | `--since <today> --until <tomorrow>` |

Replace every placeholder with an actual local date and confirm ambiguous
periods with the user. Never label a multi-year all-time report as one
calendar year's recap. Sanity-check `queryWindow` and `.timeline.byDay`
against the agreed period. `dataWindow` comes from the unfiltered schema
query and always describes the full database, even for a filtered report.

## Step 3 — gather data

```bash
scripts/collect.sh --tbar "$TBAR" [WINDOW_FLAGS] > /tmp/collected.json
scripts/apply_pricing.py < /tmp/collected.json > /tmp/payload.json
```

`collect.sh` runs `tbar` queries in parallel, reads the user's
`tokenbar.pricingOverrides` plist, and emits one aggregated JSON document.
`apply_pricing.py` attempts to apply per-model overrides. The current helper
uses legacy combined `cache` rates and `cacheTokens`; current app overrides
use separate `cacheRead`/`cacheCreation` rates and the CLI emits separate
cache-read/cache-creation counts. Do not claim its override totals match
Settings without reconciling these fields. The helper also labels unchanged
CLI costs `default-flat`, although CLI `costSource` can be `actual` or `mixed`.
Preserve that provenance and disclose unavailable costs, especially Cursor
events with no reported cost. Pause cost claims when they cannot be verified.

Verify the payload before continuing:

```bash
jq '{
  indexed_events_all_time: .dataWindow.eventCount,
  selected_events: ([.timeline.byDay[].eventCount] | add // 0),
  query_window: .queryWindow,
  days: (.timeline.byDay | length),
  agents: (.agents | length),
  models: (.models | length),
  cost: .cost.totalUSD,
  overrides: .pricingOverrideCount,
  prompts_sampled: (.prompts | length)
}' /tmp/payload.json
```

If selected events are zero or required fields are unexpectedly null, stop
and surface the issue. Zero cost or zero captured prompts alone does not
prove token data is missing; explain unavailable dimensions rather than
inventing values.

**Completeness checks.** `collect.sh` leaves the default row limits on
grouped summaries, projects, and models. For a complete report, compare
the collected arrays with equivalent `tbar ... --json --limit 0` queries
using the same window and reconcile truncated arrays before analysis.
In particular, day/hour summaries can exceed the default 100 rows.

**Window checks.** Some current render/derivation helpers still read
all-time `dataWindow` values for counts and dates. For a filtered report,
verify every displayed count, span, and activity-age calculation against
the selected-window timeline/summary. Do not present global metadata as
selected-window results; resolve any mismatch before delivering the report.

## Step 4 — cluster the prompt sample

Read `.prompts[]` from the payload (default 500 most-recent prompts; each
has `content`, `agent`, `modelName`, `projectName`, `timestamp`,
`contentLength`).

Classify each prompt into one of these clusters (or invent a more fitting
name if the data clearly calls for it):

- **bug-fix**, **refactor**, **new-feature**, **explore-explain**,
  **learn-research**, **design-architecture**, **ops-deploy**, **data-query**

See `references/dimensions.md §14` for the full cluster vocabulary and naming
rules. Output a `clusters` array — one entry per cluster name with a count.

## Step 5 — derive the personality tag (short label)

Combine cluster distribution + payload-level cadence stats (peak-hour ratio,
weekend share, longest streak, project concentration) into a 4-8 character
Chinese label or 1-3 word English label. Examples in
`references/dimensions.md §15`. You may invent a new label if none fit —
keep it pithy and self-consistent across all three personas.

## Step 5b — derive the **deep personality profile** (raw data only)

The short tag is the headline; the **profile** is the raw data each persona
uses to author its own `identity_card` narrative. v5 killed the shared
`profile_card` HTML slot — each persona renders this data in its own
题材 language (JOJO writes "「ザ・ワールド」型替身使者档案 #...",
BLEACH writes "▍護廷十三隊档案 · 隊員番号 ...",
HxH writes "▍念能力者の証 · ハンター協会登録 #...").

Spec lives in `references/dimensions.md §16`. Short version:

```jsonc
"personality_profile": {
  "mastery_level":           { "rating": "junior|mid|senior|expert|hard-to-tell",
                               "confidence": "low|medium|high",
                               "evidence": ["specific stat cite", ...] },
  "intensity":               { "rating": "light|moderate|heavy|extreme", ... },
  "work_style": {
    "tempo":      "sprint|steady|marathon|mixed",
    "preference": "builder|maintainer|explorer|mixed",
    "focus":      "deep-diver|broad-grazer|multi-track",
    "scheduling": "morning-lark|night-owl|balanced|split-shift",
    "evidence":   ["..."]
  },
  "personality_traits":      [ { "trait": "...", "evidence": "..." }, ... 3-5 items ],
  "tooling_sophistication":  { "rating": "novice|specialist|polyglot|hybrid", "evidence": ["..."] },
  "quirks":                  [ "specific repeating pattern with timestamps/numbers", ... 2-4 items ]
}
```

**Quality bar.** Every field must cite real numbers from the payload. "Heavy
intensity, user works a lot" is useless. "Heavy intensity: 13B tokens over
109 days (avg $450/day equivalent), 47-day streak, weekend share 58%" is the
target.

## Step 5c — compute Python-derived per-persona data

```bash
scripts/compute_python_derived.py < /tmp/payload.json > /tmp/python_derived.json
```

Each persona has its own pre-computed bundle inside this file. Subagents
read `python_derived.<key>` for their lens-specific data.

Bundle contents per persona:
- `jojo`   — 6-axis A-E stand-stats grades, prompt intel (verb freq /
  near-dup / quoted excerpts / session stats), behavioral extremes,
  AND a `stand_suggestion` (pre-picked from the S-tier whitelist matching
  composite_rank + axis distribution).
- `bleach` — same 6-axis grades reframed as `reiatsu_stats`, plus a
  `zanpakuto_suggestion` (pre-picked from the captain-level whitelist).
  Includes 番队 routing signals and 始解/卍解 staging hints.
- `hxh`    — `nen_assessment` (primary + secondary 系 derived from the
  6-axis distribution via a "水占い" mapping), ability-design slots
  (the subagent invents a named ability + 制约と誓约), and a nen
  progression timeline.

## Step 6 — build the shared bundle

```jsonc
// /tmp/shared.json
{
  "personality_tag":     "深夜重构师",
  "personality_profile": { ...full Step-5b structure... },
  "clusters":            [ {"name": "bug-fix", "count": 142}, ... ],
  "python_derived":      { ...from /tmp/python_derived.json... }
}
```

## Step 7 — dispatch THREE persona subagents in PARALLEL

**The architectural heart of v6.** Each persona reads the data through its
own lens AND is **constrained by a number/vocabulary contract** so the
reports don't bleed into each other. The contract files are at:

- `<skill-dir>/references/personas/_contract.md` — shared rules + ownership matrix
- `<skill-dir>/references/personas/<key>.md` — per-persona spec

Use the Agent tool with `subagent_type: "claude"` for each persona. Launch
all three in a single message (parallel) with `run_in_background: true`.

The three persona keys are: `jojo`, `bleach`, `hxh`.

Each subagent prompt should be self-contained:

```
You are the **{{persona-key}}** subagent for the tokenbar-report skill (v6).

MANDATORY first reads:
  <skill-dir>/references/personas/_contract.md       — the shared rules
  <skill-dir>/references/personas/{{persona-key}}.md — your lens spec

Inputs you have:
  - Full payload:     /tmp/payload.json
  - Shared bundle:    /tmp/shared.json
                      (includes personality_tag, personality_profile, clusters,
                       and python_derived.{{persona-key}} — your pre-computed data)

Your job (per the contract):
  1. Read the two reference files. Internalize the "number ownership matrix"
     (§3 of _contract.md) — your persona owns 2-3 metric categories; the
     others are forbidden.
  2. Read the vocabulary blacklist (§4) — banned shared phrases like 深夜,
     重构, 里程碑, 效率, 推荐, 大佬. Don't use them outside your owned framing.
  3. Read /tmp/shared.json.python_derived["{{persona-key}}"] for the
     Python-side base data.
  4. Do the LLM-side analyses your spec calls for —
     - jojo: read payload.prompts[] directly to quote actual content + pick
       a stand from the S-tier whitelist (defaulting to python_derived's
       stand_suggestion).
     - bleach: pick a 斩魄刀 from the captain-level whitelist (default in
       python_derived.bleach.zanpakuto_suggestion); author the 始解/卍解
       narrative.
     - hxh: invent a named ability that matches the user's primary 系,
       attach 制约と誓约 with concrete payload-grounded conditions.
  5. Author the universal narrative fields (title, hero_subtitle,
     narrative_open, identity_card, <section>_intro, closing_line) AND
     the 3 signature-section data structures your spec defines.
  6. **题材化身世**: author the `identity_card` field as 80-200 chars of
     pure 题材 narrative. NEVER copy `personality_profile` raw field names
     (mastery: senior). Translate every field into your 题材 vocabulary.
  7. Emit ONE JSON file at: /tmp/tokenbar-report-personas/{{persona-key}}.json

Output shape (strict):
  {
    "persona": "{{persona-key}}",
    "narrative": { ...string fields per your spec... },
    "data":      { ...structured signature data per your spec... }
  }

Constraints:
  - Language: match the user's prompt language ({{detected-language}}).
  - Stay in your lens. JOJO doesn't say 斩魄刀; BLEACH doesn't say 替身/念;
    HxH doesn't say 替身/斩魄刀.
  - Never write {{placeholder}} syntax in any field. The renderer only
    substitutes inside the *template* HTML, not in narrative strings.
  - Cite real numbers from the payload. Generic claims fail the quality bar.

Confirm completion by writing the JSON file. Reply with a 1-2 sentence
summary of what you produced.
```

Make sure `/tmp/tokenbar-report-personas/` exists before dispatching.

## Step 8 — merge and render

Once all 3 subagents complete, combine the outputs:

```bash
mkdir -p /tmp/tokenbar-report-personas
python3 -c "
import json, pathlib
shared = json.load(open('/tmp/shared.json'))
narratives = {'_shared': shared}
for k in ['jojo','bleach','hxh']:
    p = pathlib.Path(f'/tmp/tokenbar-report-personas/{k}.json')
    narratives[k] = json.loads(p.read_text()) if p.exists() else {}
json.dump(narratives, open('/tmp/narratives.json', 'w'), indent=2, ensure_ascii=False)
"
```

Then render:

```bash
scripts/render.py \
  --payload     /tmp/payload.json \
  --narratives  /tmp/narratives.json \
  --output-dir  ~/Desktop/tokenbar-report-YYYY-MM-DD/ \
  --themes-dir  <skill-dir>/assets/themes \
  --open
```

`--open` triggers `open <output>/index.html` on macOS. The renderer logs the
number of unmatched placeholders per file to stderr — anything non-zero
means a subagent didn't fill a required field, or a theme references a
placeholder no subagent emits.

## Step 9 — VERIFY lens isolation (v6 hard gate)

After rendering, run:

```bash
scripts/measure_overlap.py ~/Desktop/tokenbar-report-YYYY-MM-DD/
```

This computes pairwise Jaccard similarity across the 3 rendered HTML files
(chrome stripped, 3-char n-grams) and prints the matrix + the max pair.
**Pass condition: max < 0.30.** With only 3 pairs, a single leaking term
moves the max noticeably — be strict. If the script exits non-zero:

1. Identify the offending pair (highest Jaccard).
2. Re-read both persona spec files and inspect for vocabulary leak —
   common cause is a persona borrowing another's owned phrase
   (`替身` is jojo-only, `斩魄刀/灵压` is bleach-only, `念/系` is hxh-only).
3. Re-dispatch *those two* subagents with a stricter prompt that names
   the specific shared phrases to avoid.
4. Re-render + re-measure.

### Anti-patterns to avoid

- **Don't merge personas' work into a single Claude pass.** The whole
  premise is that each persona sees the data differently. If you write all
  three yourself, they collapse back to "same data, different wording".
- **Don't skip subagent dispatch even when the user wants 'just one persona'**.
  Always emit all three. The card-draw index makes browsing trivial.
- **Don't let any persona violate its lens contract.** If BLEACH starts
  citing A-E grades (jojo's), kill it and re-dispatch.
- **Don't write `{{placeholder}}` literally in any field.** The renderer
  substitutes only in the *template* HTML, not in narrative strings.
- **For JOJO `stand_card`: NEVER invent a stand name.** Pick from the
  S-tier whitelist in `references/personas/jojo.md §3`. The
  `python_derived.jojo.stand_suggestion` already picks a default — the
  subagent can override but must stay inside the whitelist.
- **For BLEACH `zanpakuto_card`: NEVER invent a zanpakuto.** Pick from the
  captain-level whitelist in `references/personas/bleach.md`. Default is
  `python_derived.bleach.zanpakuto_suggestion`.
- **For HxH `ability_design`: the named ability is invented by the subagent**,
  but the 系 (primary type) must match `python_derived.hxh.nen_assessment.primary_type`.

# What the skill does NOT do

- Report collection does NOT rebuild usage history, change app preferences,
  or edit upstream agent logs. Opening the database can initialize or migrate
  its schema. The optional, user-approved install/rebuild in Step 0 is a
  separate setup operation and does write the local index.
- It does NOT call any external LLM API. The narrative authoring happens in
  this Claude session.
- It does NOT use external CDNs or web fonts that require network access.
  All HTML reports must open offline.

# Files in this skill

| Path | Purpose |
|---|---|
| `SKILL.md` | This file. Workflow + dispatch contract. |
| `references/personas.md` | Overview of the 3 personas (v6). |
| `references/personas/_contract.md` | **Shared rules: number ownership, vocabulary blacklist, output shape, identity_card spec.** |
| `references/personas/<key>.md` | Per-persona lens spec — one each for `jojo` / `bleach` / `hxh`. |
| `references/dimensions.md` | Each report dimension → tbar query + derivation algorithm. |
| `scripts/collect.sh` | Parallel `tbar` queries + plist read → aggregated JSON. |
| `scripts/apply_pricing.py` | Honor `tokenbar.pricingOverrides` for cost computation. |
| `scripts/compute_python_derived.py` | Per-persona Python-side base data (6-axis grades, stand/zanpakuto pickers, nen affinity, prompt intel). |
| `scripts/render.py` | Substitute placeholders, emit 3 HTML + interactive card-draw index. |
| `scripts/measure_overlap.py` | **v6 lens-isolation gate.** Computes max pairwise Jaccard across the 3 rendered HTML files. Must be < 0.30. |
| `assets/themes/<key>.html` | One template per persona. Paired with `references/personas/<key>.md`. |
| `assets/stands/` | JOJO stand portraits (PNG/WEBP), keyed by stand id. |
| `assets/zanpakuto/` | BLEACH 斩魄刀 wielder portraits, keyed by zanpakuto id. |
| `assets/nen/` | HxH nen-type portraits, keyed by `enhancement` / `transmutation` / etc. |
| `evals/evals.json` | Test prompts for skill-creator eval workflow. |

# Failure modes and how to recover

- **`collect.sh: cannot locate tbar`** — pass `--tbar /path/to/tbar` or set
  `TOKENBAR_REPO`. Ask the user.
- **No events in the selected window** — compare the query window with
  `schema.dataWindow`, then inspect sources, checkpoints, and warnings.
  Rebuild only when the index needs it and the user approves; an empty
  window alone is not a reason to rebuild all history.
- **Pricing mismatch or helper error** — inspect the actual error and rate
  fields; do not assume malformed preferences. Current split-cache rates
  require reconciliation with the legacy helper. Use verified CLI costs
  with their `costSource`, or mark cost unavailable and explain the gap.
- **A theme template has a leftover `{{placeholder}}` in output** — the
  template asked for a key that `render.py` doesn't provide. Add the key to
  `derive()` or remove the placeholder.
- **A subagent wrote `{{xxx}}` literally** — those tokens appear in the
  rendered HTML. Re-edit the narratives JSON and re-render.
- **A persona violates its contract (e.g., bleach cites A-E grades)** — the
  contract failed silently. Re-dispatch *that one* subagent with a stricter
  prompt that explicitly names the forbidden metric / vocabulary.
- **`measure_overlap.py` fails (max ≥ 0.30)** — identify the highest-Jaccard
  pair, inspect both HTML files for vocabulary leak, re-dispatch the two
  offending subagents with explicit forbid-list.
- **JOJO stand_name not on whitelist** — re-dispatch jojo subagent with the
  whitelist explicitly inlined. Whitelist is in `personas/jojo.md §3`.
- **BLEACH zanpakuto_name not on whitelist** — same fix; whitelist in
  `personas/bleach.md`.
- **HxH primary 系 doesn't match the python-derived primary type** — that's
  a contract violation; re-dispatch with the python_derived value pinned.

# When NOT to invoke this skill

- "How many tokens did I burn today?" → use `tbar summary --day YYYY-MM-DD`
  with today's local date; bare `summary` defaults to a rolling 30 days.
- "Open the TokenBar app" → not this skill's concern.
- "Reset my pricing overrides" → also not this skill's concern.
- "Generate the report but only one persona" → still use this skill; it
  always emits all three, and the card-draw index makes navigation trivial.
