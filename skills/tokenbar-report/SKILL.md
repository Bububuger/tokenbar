---
name: tokenbar-report
description: Generate a Spotify-Wrapped-style multi-persona HTML report summarizing the user's TokenBar / `tbar` AI usage data. Use this skill whenever the user asks for a token usage report, annual recap, "year-in-review" of their AI coding, a personal AI portrait, prompt analysis, agent usage breakdown, or any phrasing along the lines of "tbar wrapped", "tokenbar 报告", "做个年度总结", "看看我都用 AI 干了什么", "I used Claude/Codex a lot — summarize my usage". Trigger even when the user mentions only "token report", "show me my usage", "做个我的 prompt 画像", or anything that wants a presentable HTML view over their TokenBar data. The skill produces one folder on the Desktop containing six HTML reports — one per narrative persona (修仙/Cultivation, 武侠/Wuxia Chronicle, 三体/Dark Forest, 水浒/108 Outlaws, 脱口秀/Stand-up Special, JOJO/Stand-stats psyche x-ray with prompt-content quotes) — each paired with a uniquely styled visual theme, plus an interactive card-draw landing `index.html` that randomizes the deck order on every load. Do not invoke for live "what's my token count right now" queries — that is `tbar` itself, not this skill.
---

# tokenbar-report — what this skill does

Run end-to-end, the skill produces a folder at
`~/Desktop/tokenbar-report-YYYY-MM-DD/` containing:

- `index.html` — **card-draw landing page**. Six face-down cards, fanned. The
  user clicks "DRAW" (or any card / "RESHUFFLE"), a card flips, and the page
  navigates to the chosen persona. The deck shuffles on every load — each
  refresh feels different.
- `01-xiuxian.html` … `06-jojo.html` — six HTML reports, one per persona,
  each in its own visual style (修仙 scroll, 武侠 dark chronicle, 三体 sci-fi
  archive, 水浒 woodblock banner, 脱口秀 stand-up stage, JOJO manga panel)
- `data.json` — the aggregated source payload (for debugging / future
  re-renders)

Every report shows the same underlying data; what changes is the **lens** —
each persona has 2-3 metrics it owns exclusively and a vocabulary the others
are forbidden to touch. The goal is six genuinely different reads of the
same dataset, not six wrappers around the same observation.

## The 6 personas at a glance (v5)

| Idx | Key | 显示名 | Lens (what *only* this persona sees) |
|---|---|---|---|
| 01 | `xiuxian` | 修仙   | 境界 / 灵气 / 渡劫 / 周天循环 / 心魔劫 |
| 02 | `wuxia`   | 武侠   | 门派 / 内功 / 招式谱 / 闭关 / 江湖事件簿 |
| 03 | `santi`   | 三体   | Kardashev 文明等级 / 黑暗森林暴露与隐匿 / 思想钢印 |
| 04 | `shuihu`  | 水浒   | 108 排座次 (天罡正/副/地煞) / 绰号 / 聚义厅大事记 |
| 05 | `talk`    | 脱口秀 | 开场白 / callback 梗 / 翻车现场 |
| 06 | `jojo`    | JOJO   | **6-axis A-E stand stats**, psyche traits with **quoted prompt fragments**, **真实 JOJO S-tier 替身白名单 + stand cry + 宿命断言** |

`references/personas.md` is the human-readable overview.
`references/personas/_contract.md` is the **shared contract** every subagent
must load. `references/personas/<key>.md` is the per-persona spec — number
whitelist, vocabulary blacklist, and the structure of the 3 signature sections.

**v5 lens-isolation gate**: after rendering, run
`scripts/measure_overlap.py <output_dir>` and verify max pairwise overlap is
strictly < **0.30** (Jaccard on 3-char n-grams, chrome stripped). Lower than
30% is the v5 hard requirement.

# Workflow

Execute these steps in order. Steps 0-2 are interactive (confirm with the
user before continuing). Steps 3-8 are mechanical and don't need check-ins
unless something fails.

## Step 0 — preflight: ensure TokenBar is installed

This skill reads the local TokenBar SQLite index. If the user has never
installed TokenBar, there is no database to read and nothing to report on.
Check first, **before** any other step.

1. Test whether the app is on disk:

   ```bash
   test -e /Applications/TokenBar.app
   ```

2. If it exists, skip to Step 1.

3. If it does not exist, ask the user (single question, two choices):

   > TokenBar.app 还没装。要我帮你装吗？
   >
   > 我会执行 `brew install --cask Bububuger/tap/tokenbar`，然后跑一次
   > `tbar rebuild` 把本地 Claude / Codex / Gemini 等 agent 的历史 token
   > 数据扫进 DB（30 秒到几分钟，看历史多寡），扫完就可以出报告。

4. If the user agrees, install and rebuild:

   ```bash
   brew tap Bububuger/tap 2>/dev/null || true
   brew install --cask Bububuger/tap/tokenbar
   tbar rebuild         # foreground; blocks until full reindex returns
   ```

   `brew install` succeeds when `/Applications/TokenBar.app` exists and
   `/opt/homebrew/bin/tbar` is symlinked. `tbar rebuild` runs the full
   reparse (the CLI equivalent of the app's "Reparse all"), so the DB has
   data the moment it returns.

5. Confirm the DB picked something up:

   ```bash
   tbar schema --json | jq '.schema.dataWindow.eventCount'
   ```

   Expect a positive integer. If it's `0`, the user genuinely has no local
   agent history yet — stop the skill and tell them so; nothing to report on.

6. If the user declines installation, stop the skill politely — without
   the local DB there is no data to summarize. Do not fabricate.

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

## Step 5b — derive the **deep personality profile** (raw data only)

The short tag is the headline; the **profile** is the raw data each persona
uses to author its own `identity_card` narrative. v5 killed the shared
`profile_card` HTML slot —— each persona renders this data in its own
题材 language (修仙 writes "道友自……入道", 武侠 writes "江湖人称……",
三体 writes "档案 #PDC-……", 水浒 writes "梁山泊水寨头领档案……",
talk writes "大家好，我叫……", JOJO writes "「ザ・ワールド」型替身使者
档案……").

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
- `xiuxian` — 境界 ladder placement, peak/valley 时辰, tribulation outlier days
- `wuxia`   — schools ranked by 内功, verb-cluster move signals, big-day chronicle
- `santi`   — Kardashev civ-type, exposed/concealed coordinates, seal signals
- `shuihu`  — combined 108-rank list (project+model+agent), big-event days
- `talk`    — bombing list (abandoned projects), callback signals, near-dup clusters
- `jojo`    — 6-axis stand-stats grades, prompt intel (verb freq / near-dup / quoted excerpts / session stats), behavioral extremes, AND a `stand_suggestion` (pre-picked from the S-tier whitelist matching composite_rank + axis distribution)

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

**The architectural heart of v5.** Each persona reads the data from its own
lens AND is **constrained by a number/vocabulary contract** so the reports
don't bleed into each other. The contract files are at:

- `<skill-dir>/references/personas/_contract.md` — shared rules + ownership matrix
- `<skill-dir>/references/personas/<key>.md` — per-persona spec

Use the Agent tool with `subagent_type: "claude"` for each persona. Launch
all six in a single message (parallel) with `run_in_background: true`.

The six persona keys are: `xiuxian`, `wuxia`, `santi`, `shuihu`, `talk`, `jojo`.

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
     reading payload.prompts[] directly to quote actual content + picking a
     stand from the S-tier whitelist; for talk it includes authoring the
     stand-up opening bit with pause markers; for the rest it includes
     framing payload data in the persona's own题材 vocabulary.
  5. Author the universal narrative fields (title, hero_subtitle,
     narrative_open, identity_card, <section>_intro, closing_line) AND
     the 3 signature-section data structures your spec defines.
  6. **题材化身世**: author the `identity_card` field as 80-200 chars of pure
     题材 narrative. NEVER copy `personality_profile` raw field names
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
  - Stay in your lens. If your contract says you can't say 境界, do not
    write it even if Python gives you a 境界 ladder — that's xiuxian's.
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
for k in ['xiuxian','wuxia','santi','shuihu','talk','jojo']:
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

## Step 9 — VERIFY lens isolation (v5 hard gate)

After rendering, run:

```bash
scripts/measure_overlap.py ~/Desktop/tokenbar-report-YYYY-MM-DD/
```

This computes pairwise Jaccard similarity between the 6 rendered HTML files
(chrome stripped, 3-char n-grams) and prints a 6×6 matrix + the max pair.
**Pass condition: max < 0.30.** If the script exits non-zero:

1. Identify the offending pair (highest Jaccard).
2. Re-read both persona spec files and inspect for vocabulary leak —
   common cause is a persona borrowing another's owned phrase.
3. Re-dispatch *those two* subagents with a stricter prompt that names
   the specific shared phrases to avoid.
4. Re-render + re-measure.

### Anti-patterns to avoid

- **Don't merge personas' work into a single Claude pass**. The whole
  premise is that each persona sees the data differently. If you write all
  6 yourself, they collapse back to "same data, different wording".
- **Don't skip subagent dispatch even when the user wants 'just one persona'**.
  Always emit all 6. The card-draw index makes browsing trivial.
- **Don't let any persona violate its lens contract.** If wuxia starts
  citing 境界 (xiuxian's word), kill it and re-dispatch.
- **Don't write `{{placeholder}}` literally in any field.** The renderer
  substitutes only in the *template* HTML, not in narrative strings.
- **For JOJO `stand_card`: NEVER invent a stand name.** Pick from the
  S-tier whitelist in `references/personas/jojo.md §3`. The
  `python_derived.jojo.stand_suggestion` already picks a default — the
  subagent can override but must stay inside the whitelist.

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
| `references/personas.md` | Overview of the 6 personas (v5). |
| `references/personas/_contract.md` | **Shared rules: number ownership, vocabulary blacklist, output shape, identity_card spec.** |
| `references/personas/<key>.md` | Per-persona lens spec — one each for xiuxian / wuxia / santi / shuihu / talk / jojo. |
| `references/dimensions.md` | Each report dimension → tbar query + derivation algorithm. |
| `scripts/collect.sh` | Parallel `tbar` queries + plist read → aggregated JSON. |
| `scripts/apply_pricing.py` | Honor `tokenbar.pricingOverrides` for cost computation. |
| `scripts/compute_python_derived.py` | Per-persona Python-side base data (境界 / 门派 / 文明 / 108 / callback signals / jojo stand-stats + prompt intel + S-tier stand suggestion). |
| `scripts/render.py` | Substitute placeholders, emit 6 HTML + interactive card-draw index. |
| `scripts/measure_overlap.py` | **v5 lens-isolation gate.** Computes max pairwise Jaccard across the 6 rendered HTML files. Must be < 0.30. |
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
- **A persona violates its contract (e.g., wuxia cites 境界)** — the contract
  failed silently. Re-dispatch *that one* subagent with a stricter prompt
  that explicitly names the forbidden metric / vocabulary.
- **`measure_overlap.py` fails (max ≥ 0.30)** — identify the highest-Jaccard
  pair, inspect both HTML files for vocabulary leak, re-dispatch the two
  offending subagents with explicit forbid-list.
- **JOJO stand_name not on whitelist** — re-dispatch jojo subagent with the
  whitelist explicitly inlined. The whitelist is in `personas/jojo.md §3`.

# When NOT to invoke this skill

- "How many tokens did I burn today?" → use `tbar summary` directly.
- "Open the TokenBar app" → not this skill's concern.
- "Reset my pricing overrides" → also not this skill's concern.
- "Generate the report but only one persona" → still use this skill; it
  always emits all six, and the card-draw index makes navigation trivial.
