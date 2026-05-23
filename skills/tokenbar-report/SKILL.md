---
name: tokenbar-report
description: Generate a Spotify-Wrapped-style multi-persona HTML report summarizing the user's TokenBar / `tbar` AI usage data. Use this skill whenever the user asks for a token usage report, annual recap, "year-in-review" of their AI coding, a personal AI portrait, prompt analysis, agent usage breakdown, or any phrasing along the lines of "tbar wrapped", "tokenbar 报告", "做个年度总结", "看看我都用 AI 干了什么", "I used Claude/Codex a lot — summarize my usage". Trigger even when the user mentions only "token report", "show me my usage", "做个我的 prompt 画像", or anything that wants a presentable HTML view over their TokenBar data. The skill produces one folder on the Desktop containing six HTML reports — one per narrative persona (humorous, brutally honest, data nerd, philosophical, financial-analyst, JoJo-style psyche x-ray with prompt-content quotes) — each paired with a uniquely styled visual theme, plus an interactive card-draw landing `index.html` that randomizes the deck order on every load. Do not invoke for live "what's my token count right now" queries — that is `tbar` itself, not this skill.
---

# tokenbar-report — what this skill does

Run end-to-end, the skill produces a folder at
`~/Desktop/tokenbar-report-YYYY-MM-DD/` containing:

- `index.html` — **card-draw landing page**. Six face-down cards, fanned. The
  user clicks "DRAW" (or any card / "RESHUFFLE"), a card flips, and the page
  navigates to the chosen persona. The deck shuffles on every load — each
  refresh feels different.
- `01-comic.html` … `06-jojo.html` — six HTML reports, one per persona, each
  in its own visual style (Wrapped-comic, brutalist, terminal, essay,
  Financial Times, JoJo manga-panel)
- `data.json` — the aggregated source payload (for debugging / future
  re-renders)

Every report shows the same underlying data; what changes is the **lens** —
each persona has 2-3 metrics it owns exclusively and a vocabulary the others
are forbidden to touch. The goal is six genuinely different reads of the
same dataset, not six wrappers around the same observation.

## The 6 personas at a glance

| Idx | Key | Chinese | Lens (what *only* this persona sees) |
|---|---|---|---|
| 01 | `comic`     | 幽默风趣 | Pop-culture conversions, hall of shame (silly questions), trivia |
| 02 | `brutalist` | 忠言逆耳 | Stale-debt ledger, dependence ratings, repeat-offender verdicts |
| 03 | `terminal`  | 数据极客 | p50/p90/p99/σ, 7×24 heatmap, |z| ≥ 3 anomaly log |
| 04 | `essay`     | 哲学反思 | Inactive days, abandoned projects, "unread conversation" long prompts |
| 05 | `ft`        | 财经评论员 | Capital allocation, HHI concentration, monthly P&L |
| 06 | `jojo`      | 人性透视 | **6-axis A-E stand stats**, psyche traits with **quoted prompt fragments**, stand-name + fatalistic verdict |

`references/personas.md` is the human-readable overview.
`references/personas/_contract.md` is the **shared contract** every subagent
must load. `references/personas/<key>.md` is the per-persona spec — number
whitelist, vocabulary blacklist, and the structure of the 3 signature sections.

# Workflow

Execute these steps in order. Steps 1-2 are interactive (confirm with the
user before continuing). Steps 3-8 are mechanical and don't need check-ins
unless something fails.

## Step 1 — locate the TokenBar repo

The skill assumes you can resolve a `tbar` binary. Try in this order:

1. `$TOKENBAR_REPO/script/tbar`
2. `~/Documents/workspace/projects/tokenbar/script/tbar`
3. `tbar` on `$PATH`

If none resolve, ask the user where the TokenBar repo lives and proceed
once they tell you. `scripts/collect.sh` handles the actual lookup; you
only need to pass `--tbar /path` if the default resolution fails.

## Step 2 — confirm the time window with the user

Read the data window first:

```bash
$TBAR schema --json | jq '.schema.dataWindow'
```

Then tell the user what's available and ask for confirmation:

> 你的数据覆盖 `<earliest>` → `<latest>` (`N` 天，`M` events)。
> 默认我会把整个区间都纳入报告。要不要换：(a) 最近 30 天 / (b) 最近一年 /
> (c) 某个具体年月 / (d) 自定义 since-until？

Lock the window before continuing. Translate the user's reply into one of:
- `--days 0` (all-time, default)
- `--days N`
- `--since YYYY-MM-DD --until YYYY-MM-DD`
- `--since YYYY-01-01 --until YYYY-12-31` (full year)

If the user used a vague phrase, map it BEFORE running collect.sh:

| User phrase | Flag |
|---|---|
| "年度" / "year" / "annual" / "wrapped" (no further qualifier) | `--days 0` (all-time) |
| "本年" / "this year" / "今年" / "<current year>" | `--since YYYY-01-01 --until <today>` |
| "本季度" / "this quarter" / "Q1/Q2/..." (no specific year) | `--days 90` |
| "本月" / "this month" / "最近一个月" / "last month" | `--days 30` |
| "本周" / "this week" / "最近一周" / "last week" | `--days 7` |
| "今天" / "today" | `--days 1` |

Sanity-check the resulting payload's `dataWindow.eventCount` / `byDay.length`
against the phrase you mapped — if "最近一个月" returned 109 days of data,
you mis-mapped and need to re-collect.

## Step 3 — gather data

```bash
scripts/collect.sh [WINDOW_FLAGS] | scripts/apply_pricing.py > /tmp/payload.json
```

`collect.sh` runs 12 `tbar` queries in parallel, reads the user's
`tokenbar.pricingOverrides` plist, and emits one aggregated JSON document.
`apply_pricing.py` recomputes costs using any per-model overrides the user
has set in TokenBar Settings.

Verify the payload before continuing:

```bash
jq '{
  events: .dataWindow.eventCount,
  days: (.timeline.byDay | length),
  agents: (.agents | length),
  models: (.models | length),
  cost: .cost.totalUSD,
  overrides: .pricingOverrideCount,
  prompts_sampled: (.prompts | length)
}' /tmp/payload.json
```

If any field is 0/null where you expect data, stop and surface the issue to
the user — don't write a report on empty data.

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

Combine cluster distribution + payload-level cadence stats (night-owl ratio,
weekend share, longest streak, project concentration) into a 4-8 character
Chinese label or 1-3 word English label. Examples in
`references/dimensions.md §15`. You may invent a new label if none fit —
keep it pithy and self-consistent across all six personas.

## Step 5b — derive the **deep personality profile**

The short tag is the headline; the **profile** is the dossier under it. It
is rendered identically across all six reports (each persona only adds a
1-2 sentence `profile_narrative` blurb in its own voice). Spec lives in
`references/dimensions.md §16`. Short version:

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
read `python_derived.<key>` for their lens-specific data. The `jojo` bundle
includes the 6-axis stand-stats grades, prompt-content intel
(verb frequencies, near-duplicate clusters, ultra-long prompt excerpts),
and behavioral extremes — none of which are available to the other 5.

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

## Step 7 — dispatch SIX persona subagents in PARALLEL

**The architectural heart of v4.** Each persona reads the data from its own
lens AND is **constrained by a number/vocabulary contract** so the reports
don't bleed into each other. The contract files are at:

- `<skill-dir>/references/personas/_contract.md` — shared rules + ownership matrix
- `<skill-dir>/references/personas/<key>.md` — per-persona spec

Use the Agent tool with `subagent_type: "claude"` for each persona. Launch
all six in a single message (parallel) with `run_in_background: true`.

Each subagent prompt should be self-contained:

```
You are the **{{persona-key}}** subagent for the tokenbar-report skill (v4).

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
     (§2 of _contract.md) — your persona owns 2-3 metric categories; the
     others are forbidden.
  2. Read the vocabulary blacklist (§3) — banned shared phrases like 深夜,
     重构, 里程碑, 连续N天, 效率, 推荐. Don't use them outside your owned
     framing.
  3. Read /tmp/shared.json.python_derived["{{persona-key}}"] for the
     Python-side base data.
  4. Do the LLM-side analyses your spec calls for — for jojo this includes
     reading payload.prompts[] directly to quote actual content; for essay
     it includes selecting evocative inactive dates; etc.
  5. Author the universal narrative fields (title, hero_subtitle,
     narrative_open, profile_narrative, <section>_intro, closing_line) AND
     the 3 signature-section data structures your spec defines.
  6. Emit ONE JSON file at: /tmp/tokenbar-report-personas/{{persona-key}}.json

Output shape (strict):
  {
    "persona": "{{persona-key}}",
    "narrative": { ...string fields per your spec... },
    "data":      { ...structured signature data per your spec... }
  }

Constraints:
  - Language: match the user's prompt language ({{detected-language}}).
  - Stay in your lens. If your contract says "no σ", do not write σ even if
    Python gives you the distribution stats — that's terminal's.
  - Never write {{placeholder}} syntax in any field. The renderer only
    substitutes inside the *template* HTML, not in narrative strings.
  - Cite real numbers from the payload. Generic claims fail the quality bar.

Confirm completion by writing the JSON file. Reply with a 1-2 sentence
summary of what you produced.
```

Make sure `/tmp/tokenbar-report-personas/` exists before dispatching.

## Step 8 — merge and render

Once all 6 subagents complete, combine the outputs:

```bash
mkdir -p /tmp/tokenbar-report-personas
python3 -c "
import json, pathlib
shared = json.load(open('/tmp/shared.json'))
narratives = {'_shared': shared}
for k in ['comic','brutalist','terminal','essay','ft','jojo']:
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

### Anti-patterns to avoid

- **Don't merge personas' work into a single Claude pass**. The whole
  premise of v3/v4 is that each persona sees the data differently. If you
  write all 6 yourself, they collapse back to "same data, different wording".
- **Don't skip subagent dispatch even when the user wants 'just one persona'**.
  Always emit all 6. The card-draw index makes browsing trivial.
- **Don't let any persona violate its lens contract.** If essay starts
  citing σ, kill it and re-dispatch.
- **Don't write `{{placeholder}}` literally in any field.** The renderer
  substitutes only in the *template* HTML, not in narrative strings.

# What the skill does NOT do

- It does NOT modify the TokenBar database, app preferences, or any source
  file. Read-only on TokenBar's side.
- It does NOT call any external LLM API. The narrative authoring happens in
  this Claude session.
- It does NOT use external CDNs or web fonts that require network access.
  All HTML reports must open offline.

# Files in this skill

| Path | Purpose |
|---|---|
| `SKILL.md` | This file. Workflow + dispatch contract. |
| `references/personas.md` | Overview of the 6 personas. |
| `references/personas/_contract.md` | **Shared rules: number ownership, vocabulary blacklist, output shape.** |
| `references/personas/<key>.md` | Per-persona lens spec (1 file per persona). |
| `references/dimensions.md` | Each report dimension → tbar query + derivation algorithm. |
| `scripts/collect.sh` | Parallel `tbar` queries + plist read → aggregated JSON. |
| `scripts/apply_pricing.py` | Honor `tokenbar.pricingOverrides` for cost computation. |
| `scripts/compute_python_derived.py` | Per-persona Python-side base data (including jojo's stand-stats + prompt intel). |
| `scripts/render.py` | Substitute placeholders, emit 6 HTML + interactive card-draw index. |
| `assets/themes/<key>.html` | One template per persona. Paired with `references/personas/<key>.md`. |
| `evals/evals.json` | Test prompts for skill-creator eval workflow. |

# Failure modes and how to recover

- **`collect.sh: cannot locate tbar`** — pass `--tbar /path/to/tbar` or set
  `TOKENBAR_REPO`. Ask the user.
- **Empty payload (`eventCount: 0`)** — the user's window is too narrow or
  the TokenBar DB hasn't been rebuilt. Suggest `tbar rebuild` first.
- **`apply_pricing.py` errors on pricing overrides** — the user's plist has
  malformed JSON. Fall back to default-flat pricing and warn in the report.
- **A theme template has a leftover `{{placeholder}}` in output** — the
  template asked for a key that `render.py` doesn't provide. Add the key to
  `derive()` or remove the placeholder.
- **A subagent wrote `{{xxx}}` literally** — those tokens appear in the
  rendered HTML. Re-edit the narratives JSON and re-render.
- **A persona violates its contract (e.g., essay cites HHI)** — the contract
  failed silently. Re-dispatch *that one* subagent with a stricter prompt
  that explicitly names the forbidden metric.

# When NOT to invoke this skill

- "How many tokens did I burn today?" → use `tbar summary` directly.
- "Open the TokenBar app" → not this skill's concern.
- "Reset my pricing overrides" → also not this skill's concern.
- "Generate the report but only one persona" → still use this skill; it
  always emits all six, and the card-draw index makes navigation trivial.
