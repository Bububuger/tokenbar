#!/usr/bin/env bash
# collect.sh — runs every tbar query needed by tokenbar-report and emits one
# aggregated JSON document on stdout. The skill caller computes derived
# insights from this single artifact.
#
# Usage:
#   collect.sh [--days N | --since YYYY-MM-DD --until YYYY-MM-DD]
#              [--tbar /path/to/tbar] [--prompt-sample N]
#
# Defaults: --days 0 (all-time), tbar resolved from $TOKENBAR_REPO/script/tbar
# or PATH, prompt sample size 500.

set -euo pipefail

DAYS=""
SINCE=""
UNTIL=""
TBAR=""
PROMPT_SAMPLE=500

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --tbar) TBAR="$2"; shift 2 ;;
    --prompt-sample) PROMPT_SAMPLE="$2"; shift 2 ;;
    *) echo "collect.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

# Resolve tbar binary. We prefer the prebuilt SPM artifact so parallel
# invocations don't fight over .build's lock; if it's missing we build once
# (single-process) and then reuse the artifact for every query.
resolve_tbar() {
  if [[ -n "$TBAR" ]]; then return; fi
  local repo=""
  if [[ -n "${TOKENBAR_REPO:-}" ]]; then
    repo="$TOKENBAR_REPO"
  elif [[ -d "$HOME/Documents/workspace/projects/tokenbar" ]]; then
    repo="$HOME/Documents/workspace/projects/tokenbar"
  fi
  if [[ -n "$repo" ]]; then
    for cfg in release debug; do
      if [[ -x "$repo/.build/$cfg/tbar" ]]; then
        TBAR="$repo/.build/$cfg/tbar"
        return
      fi
    done
    # No prebuilt artifact — build once with the lock held, then call directly.
    if command -v swift >/dev/null 2>&1; then
      (cd "$repo" && swift build --product tbar >&2)
      if [[ -x "$repo/.build/debug/tbar" ]]; then
        TBAR="$repo/.build/debug/tbar"
        return
      fi
    fi
    # Fall back to the wrapper if the build attempt did not produce a binary.
    if [[ -x "$repo/script/tbar" ]]; then
      TBAR="$repo/script/tbar"
      return
    fi
  fi
  if command -v tbar >/dev/null 2>&1; then
    TBAR=$(command -v tbar)
    return
  fi
  echo "collect.sh: cannot locate tbar; pass --tbar /path or export TOKENBAR_REPO" >&2
  exit 3
}
resolve_tbar

# Build the shared filter argv used by every aggregation query.
FILTER=()
if [[ -n "$SINCE" || -n "$UNTIL" ]]; then
  if [[ -n "$DAYS" ]]; then
    echo "collect.sh: --days is mutually exclusive with --since/--until" >&2
    exit 2
  fi
  [[ -n "$SINCE" ]] && FILTER+=(--since "$SINCE")
  [[ -n "$UNTIL" ]] && FILTER+=(--until "$UNTIL")
else
  FILTER+=(--days "${DAYS:-0}")
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Run all queries in parallel. Each writes its raw envelope to $WORK/<name>.json.
run() {
  local name="$1"; shift
  "$TBAR" "$@" --json > "$WORK/$name.json" 2> "$WORK/$name.err" &
}

run schema schema
run summary_agent      summary  --group-by agent          "${FILTER[@]}"
run summary_model      summary  --group-by model          "${FILTER[@]}"
run summary_project    summary  --group-by project        "${FILTER[@]}"
run summary_day        summary  --group-by day            "${FILTER[@]}"
run summary_day_hour   summary  --group-by day,hour-of-day "${FILTER[@]}"
run timeline_day       timeline --bucket day              "${FILTER[@]}"
run timeline_hour      timeline --bucket hour-of-day      "${FILTER[@]}"
run projects           projects                            "${FILTER[@]}"
run models             models                              "${FILTER[@]}"
run agents             agents                              "${FILTER[@]}"
run prompts            prompts  --limit "$PROMPT_SAMPLE" --sort timestamp:desc "${FILTER[@]}"
run sources            sources

wait

# Surface any per-query failures up to the caller.
for f in "$WORK"/*.err; do
  if [[ -s "$f" ]]; then
    echo "collect.sh: $(basename "$f" .err) emitted stderr:" >&2
    sed 's/^/  /' "$f" >&2
  fi
done
for f in "$WORK"/*.json; do
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" >/dev/null 2>&1; then
    echo "collect.sh: $(basename "$f") is not valid JSON" >&2
    exit 4
  fi
done

# Read pricing overrides. @AppStorage stores the value as a JSON-encoded
# string under tokenbar.pricingOverrides; defaults read returns that string
# in the plist's string-escaped form, so we pull the raw bytes via plutil.
PLIST="$HOME/Library/Preferences/com.javis.TokenBar.plist"
if [[ -f "$PLIST" ]]; then
  /usr/libexec/PlistBuddy -c 'Print :tokenbar.pricingOverrides' "$PLIST" \
    2>/dev/null > "$WORK/pricing_overrides_raw.txt" || true
fi

# Stitch everything together with Python. Easier than jq for this shape.
python3 - "$WORK" "$PROMPT_SAMPLE" <<'PY'
import json
import os
import sys

work, sample_n = sys.argv[1], int(sys.argv[2])

def load(name):
    with open(os.path.join(work, f"{name}.json")) as f:
        return json.load(f)

schema       = load("schema")
sumAgent     = load("summary_agent")
sumModel     = load("summary_model")
sumProject   = load("summary_project")
sumDay       = load("summary_day")
sumDayHour   = load("summary_day_hour")
tlDay        = load("timeline_day")
tlHour       = load("timeline_hour")
projects     = load("projects")
models       = load("models")
agents       = load("agents")
prompts      = load("prompts")
sources      = load("sources")

# Parse pricing overrides — the value is a JSON-encoded string stored as the
# preference value (because @AppStorage<String>). Empty/missing → {}.
overrides = {}
raw_path = os.path.join(work, "pricing_overrides_raw.txt")
if os.path.exists(raw_path):
    raw = open(raw_path).read().strip()
    if raw and raw != "{}":
        try:
            overrides = json.loads(raw)
        except json.JSONDecodeError:
            pass

aggregate = {
    "schemaVersion": "tokenbar-report.1",
    "generatedAt": schema.get("generatedAt"),
    "databasePath": schema.get("databasePath"),
    "dataWindow": schema["schema"]["dataWindow"],
    "queryWindow": tlDay.get("window") or sumAgent.get("window"),
    "promptSampleSize": sample_n,
    "schema": schema["schema"],
    "summary": {
        "byAgent":    sumAgent["summary"]["rows"],
        "byModel":    sumModel["summary"]["rows"],
        "byProject":  sumProject["summary"]["rows"],
        "byDay":      sumDay["summary"]["rows"],
        "byDayHour":  sumDayHour["summary"]["rows"],
    },
    "timeline": {
        "byDay":  tlDay["timeline"]["buckets"],
        "byHour": tlHour["timeline"]["buckets"],
    },
    "projects": projects["projects"]["projects"],
    "models":   models["models"]["models"],
    "agents":   agents["agents"]["agents"],
    "prompts":  prompts["prompts"]["prompts"],
    "promptsTotalCount": prompts["prompts"].get("totalCount"),
    "sources":  sources["sources"],
    "pricingOverrides": overrides,
    "pricingOverrideCount": len(overrides),
}

json.dump(aggregate, sys.stdout, indent=2, ensure_ascii=False)
PY
