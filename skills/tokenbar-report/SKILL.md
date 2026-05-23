---
name: tokenbar-report
description: Generate a Spotify-Wrapped-style multi-persona HTML report summarizing the user's TokenBar / `tbar` AI usage data. Use this skill whenever the user asks for a token usage report, annual recap, "year-in-review" of their AI coding, a personal AI portrait, prompt analysis, agent usage breakdown, or any phrasing along the lines of "tbar wrapped", "tokenbar 报告", "做个年度总结", "看看我都用 AI 干了什么", "I used Claude/Codex a lot — summarize my usage". Trigger even when the user mentions only "token report", "show me my usage", "做个我的 prompt 画像", or anything that wants a presentable HTML view over their TokenBar data. The skill produces one folder on the Desktop containing seven HTML reports — one per narrative persona (humorous, brutally honest, data nerd, philosophical, motivational, casual best-friend, financial-analyst) — each paired with a uniquely styled visual theme, plus a landing `index.html` linking them. Do not invoke for live "what's my token count right now" queries — that is `tbar` itself, not this skill.
---

# tokenbar-report — what this skill does

Run end-to-end, the skill produces a folder at
`~/Desktop/tokenbar-report-YYYY-MM-DD/` containing:

- `index.html` — landing page with seven persona cards
- `01-comic.html` … `07-ft.html` — seven HTML reports, one per persona, each
  in its own visual style (Wrapped, brutalist, terminal, essay, sunrise,
  notebook, Financial Times)
- `data.json` — the aggregated source payload (for debugging / future
  re-renders)

Every report shows the same underlying data; what changes is the voice and
visual identity. The user gets to flip between seven framings of the same
quarter / month / year.

# Workflow

Execute these steps in order. Steps 1-2 are interactive (confirm with the
user before continuing). Steps 3-7 are mechanical and don't need check-ins
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

If the user used a vague phrase, map it BEFORE running collect.sh. Trust this
table — don't second-guess and end up with the wrong number of days:

| User phrase | Flag |
|---|---|
| "年度" / "year" / "annual" / "wrapped" (no further qualifier) | `--days 0` (all-time) |
| "本年" / "this year" / "今年" / "2026" (current year) | `--since YYYY-01-01 --until <today>` |
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
Chinese label or 1-3 word English label. Example labels in
`references/dimensions.md §15`. You may invent a new label if none fit —
keep it pithy and self-consistent across all seven personas.

## Step 5b — derive the **deep personality profile** (THE main inference)

The short tag is the headline; the **profile** is the dossier under it. This
is the most analytically valuable section of the report — invest real thought
here. Re-read `prompts[].content` actively while inferring.

Output a `personality_profile` object under `_shared` with **all six**
sub-objects below. Spec lives in `references/dimensions.md §16` (read it
before authoring) — the short version:

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
target. Quirks should be specific enough that the user can mentally verify
them ("every Wednesday around 23:00") — not generic ("often works at night").

**Common failure mode**: leaving fields at defaults or stuffing the profile
with the same evidence used in earlier sections. Vary your citations.

## Step 6 — author seven narrative payloads

Read `references/personas.md` for the voice rules and example openers. For
each of the seven personas, write a JSON object with exactly these keys:

```jsonc
{
  "title": "...",
  "hero_subtitle": "...",
  "narrative_open": "...",
  "heaviest_day_blurb": "...",
  "hour_clock_blurb": "...",
  "model_blurb": "...",
  "agent_blurb": "...",
  "project_blurb": "...",
  "streak_blurb": "...",
  "cluster_blurb": "...",
  "personality_tag_blurb": "...",
  "profile_narrative": "...",
  "closing_line": "..."
}
```

Length budget per blurb: **30-90 Chinese characters** OR **1-2 short English
sentences**. The `profile_narrative` is allowed to be longer — **2-4 sentences**
or **80-200 Chinese characters** — because it's the persona's full take on the
structured dossier. The visuals carry the data; words add flavor.

Combine the seven into one narratives file along with the shared
clusters + personality_tag + **personality_profile**:

```jsonc
{
  "_shared": {
    "personality_tag":      "深夜重构师",
    "personality_profile":  { ...full Step-5b structure... },
    "clusters":             [ {"name": "bug-fix", "count": 142}, ... ]
  },
  "comic":     { ... },
  "brutalist": { ... },
  "terminal":  { ... },
  "essay":     { ... },
  "sunrise":   { ... },
  "notebook":  { ... },
  "ft":        { ... }
}
```

Write this to `/tmp/tokenbar-report-narratives.json` (or any path).

### Anti-patterns to avoid when authoring narratives

- **Don't use `{{placeholder}}` syntax inside blurb strings.** The renderer
  treats narrative fields as literal text and only substitutes `{{...}}`
  tokens in the *template* file. If you write `weekend-share={{weekend_pct}}%`
  it will appear verbatim in the output. Substitute the actual number when
  authoring.
- **Don't repeat the data verbatim.** The number is already in the visual
  card; the blurb's job is the *take*, not the *number*.
- **Don't mix languages within a persona** unless the persona description
  explicitly calls for it (only the data nerd is allowed to fold English
  technical terms into a Chinese narrative).
- **Don't drift across personas.** A user reading all seven should feel like
  reading seven different writers; reuse of the same metaphor or simile
  across two personas is a flag.

## Step 7 — render and open

```bash
scripts/render.py \
  --payload /tmp/payload.json \
  --narratives /tmp/tokenbar-report-narratives.json \
  --output-dir ~/Desktop/tokenbar-report-YYYY-MM-DD/ \
  --themes-dir <skill-dir>/assets/themes \
  --open
```

`--open` triggers `open <output>/index.html` on macOS. The renderer logs the
number of unmatched placeholders per file to stderr — anything non-zero
means a template authoring bug, not a narrative authoring bug. Surface it.

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
| `SKILL.md` | This file. Workflow + the JSON contract for narratives. |
| `references/personas.md` | Voice rules + example openers for all 7 personas. **Read before Step 6.** |
| `references/dimensions.md` | Each report dimension → tbar query + derivation algorithm. **Reference when computing values.** |
| `scripts/collect.sh` | Parallel `tbar` queries + plist read → aggregated JSON. |
| `scripts/apply_pricing.py` | Honor `tokenbar.pricingOverrides` for cost computation. |
| `scripts/render.py` | Substitute placeholders, emit 7 HTML + index.html. |
| `assets/themes/<key>.html` | One template per persona. Paired with `references/personas.md`. |
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
- **The narrative writer (you) wrote `{{xxx}}` literally** — those tokens
  appear in the rendered HTML. Re-edit the narratives JSON and re-render.

# When NOT to invoke this skill

- "How many tokens did I burn today?" → use `tbar summary` directly.
- "Open the TokenBar app" → not this skill's concern.
- "Reset my pricing overrides" → also not this skill's concern.
- "Generate the report but only one persona" → still use this skill; it
  always emits all seven, and the index makes navigation trivial.
