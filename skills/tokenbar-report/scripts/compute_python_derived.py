#!/usr/bin/env python3
"""compute_python_derived.py — compute deterministic per-persona analyses
that don't need an LLM. Reads the priced payload on stdin, writes a single
JSON document on stdout keyed by persona, with everything subagents need to
build their reports.
"""
from __future__ import annotations

import collections
import datetime as dt
import json
import math
import re
import statistics
import sys
from typing import Any, Dict, List, Optional, Tuple


def _parse_date(s: str) -> dt.date:
    return dt.date.fromisoformat(s.split("T")[0])


def _quantile(sorted_vals: List[float], q: float) -> float:
    if not sorted_vals:
        return 0.0
    pos = (len(sorted_vals) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = pos - lo
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * frac


def _stats(values: List[float]) -> Dict[str, float]:
    if not values:
        return {"p50": 0, "p90": 0, "p99": 0, "sigma": 0, "max": 0, "mean": 0}
    sv = sorted(values)
    mean = statistics.fmean(values)
    sigma = statistics.pstdev(values) if len(values) > 1 else 0
    return {
        "p50":   _quantile(sv, 0.50),
        "p90":   _quantile(sv, 0.90),
        "p99":   _quantile(sv, 0.99),
        "sigma": sigma,
        "max":   sv[-1],
        "mean":  mean,
    }


def _by_month(daily: List[dict]) -> Dict[str, int]:
    out: Dict[str, int] = collections.defaultdict(int)
    for b in daily:
        try:
            d = _parse_date(b["label"])
        except (KeyError, ValueError):
            continue
        out[f"{d.year}-{d.month:02d}"] += b.get("totalTokens", 0)
    return dict(sorted(out.items()))


def _by_week(daily: List[dict]) -> List[Tuple[dt.date, int]]:
    out: Dict[dt.date, int] = collections.defaultdict(int)
    for b in daily:
        try:
            d = _parse_date(b["label"])
        except (KeyError, ValueError):
            continue
        monday = d - dt.timedelta(days=d.weekday())
        out[monday] += b.get("totalTokens", 0)
    return sorted(out.items())


def _streaks(daily: List[dict]) -> Tuple[int, int, Optional[dt.date]]:
    if not daily:
        return 0, 0, None
    dated = sorted(
        (_parse_date(b["label"]), b.get("totalTokens", 0))
        for b in daily if "label" in b
    )
    longest = current = 0
    longest_end: Optional[dt.date] = None
    prev = None
    for d, tok in dated:
        if tok <= 0:
            current = 0
            prev = d
            continue
        if prev is not None and (d - prev).days == 1:
            current += 1
        else:
            current = 1
        if current > longest:
            longest = current
            longest_end = d
        prev = d
    return longest, current, longest_end


def _total_tokens(daily: List[dict]) -> int:
    return sum(b.get("totalTokens", 0) for b in daily)


def _project_cost(project_tokens: int, total_tokens: int, total_cost: float) -> float:
    if total_tokens <= 0:
        return 0.0
    return project_tokens / total_tokens * total_cost


def _compact(n: float) -> str:
    n = float(n)
    for thresh, suffix in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]:
        if abs(n) >= thresh:
            return f"{n / thresh:.2f}{suffix}".rstrip("0").rstrip(".")
    return f"{int(n)}"


def derive_comic(payload: dict) -> dict:
    daily = payload["timeline"]["byDay"]
    hourly = payload["timeline"]["byHour"]
    prompts = payload.get("prompts", [])

    first_seen = payload["dataWindow"]["earliest"]

    longest = max(prompts, key=lambda p: p.get("contentLength", 0)) if prompts else None

    nonzero_hours = [h for h in hourly if h.get("totalTokens", 0) > 0]
    quietest = min(nonzero_hours, key=lambda h: h.get("totalTokens", 0)) if nonzero_hours else None

    return {
        "first_prompt": {
            "timestamp": first_seen,
            "weekday":   _parse_date(first_seen).strftime("%A"),
        },
        "longest_prompt": ({
            "chars":      longest.get("contentLength", 0),
            "tokens_est": longest.get("contentLength", 0) // 4,
            "project":    longest.get("projectName"),
            "agent":      longest.get("agentDisplayName"),
        } if longest else None),
        "quietest_hour": ({
            "label":  quietest.get("label"),
            "tokens": quietest.get("totalTokens", 0),
        } if quietest else None),
        "total_tokens":          _total_tokens(daily),
        "total_prompts_sampled": len(prompts),
    }


def derive_brutalist(payload: dict) -> dict:
    last_seen_dt = _parse_date(payload["dataWindow"]["latest"])
    projects = payload.get("projects", [])
    total_tokens = _total_tokens(payload["timeline"]["byDay"]) or 1
    total_cost = payload.get("cost", {}).get("totalUSD", 0)

    stale = []
    for p in projects:
        last = p.get("lastSeen")
        if not last:
            continue
        try:
            d = _parse_date(last)
        except ValueError:
            continue
        days_idle = (last_seen_dt - d).days
        if days_idle < 14:
            continue
        tokens = p.get("totalTokens", 0)
        cost = _project_cost(tokens, total_tokens, total_cost)
        status = "stale"
        if days_idle > 60:
            status = "dead"
        elif days_idle > 30:
            status = "dormant"
        stale.append({
            "project":        p.get("name"),
            "last_seen":      last.split("T")[0],
            "days_idle":      days_idle,
            "tokens":         tokens,
            "tokens_compact": _compact(tokens),
            "cost_usd":       round(cost, 2),
            "status":         status,
        })
    stale.sort(key=lambda r: r["tokens"], reverse=True)

    models = sorted(payload.get("models", []), key=lambda m: m.get("totalTokens", 0), reverse=True)
    agents = sorted(payload.get("agents", []), key=lambda a: a.get("totalTokens", 0), reverse=True)
    projs = sorted(projects, key=lambda p: p.get("totalTokens", 0), reverse=True)

    top_model_name = models[0].get("name", "—") if models else None
    top_model_share = (models[0].get("totalTokens", 0) / total_tokens * 100) if models else 0
    top_agent_name = (agents[0].get("displayName") or agents[0].get("kind")) if agents else None
    top_agent_share = (agents[0].get("totalTokens", 0) / total_tokens * 100) if agents else 0
    top_project_name = projs[0].get("name") if projs else None
    top_project_share = (projs[0].get("totalTokens", 0) / total_tokens * 100) if projs else 0

    long_tail_models = sum(
        1 for m in models if (m.get("totalTokens", 0) / total_tokens * 100) < 1.0
    )

    return {
        "stale_projects": stale[:15],
        "dependence": {
            "top_model_name":    top_model_name,
            "top_model_share":   round(top_model_share, 2),
            "top_agent_name":    top_agent_name,
            "top_agent_share":   round(top_agent_share, 2),
            "top_project_name":  top_project_name,
            "top_project_share": round(top_project_share, 2),
            "long_tail_models":  long_tail_models,
            "agent_count":       len(agents),
            "model_count":       len(models),
            "project_count":     len(projs),
        }
    }


def derive_terminal(payload: dict) -> dict:
    daily = payload["timeline"]["byDay"]
    prompts = payload.get("prompts", [])
    day_hour = payload["summary"]["byDayHour"]

    daily_tokens = [b.get("totalTokens", 0) for b in daily]
    daily_prompts = [b.get("promptCount", 0) for b in daily]
    content_lengths = [p.get("contentLength", 0) for p in prompts]

    grid = [[0] * 24 for _ in range(7)]
    for r in day_hour:
        try:
            d = _parse_date(r["day"])
        except (KeyError, ValueError):
            continue
        h = r.get("hour-of-day")
        if h is None or not (0 <= h <= 23):
            continue
        grid[d.weekday()][h] += r.get("totalTokens", 0)

    peak_cell = {"weekday": "—", "hour": 0, "tokens": 0}
    deadzone = {"weekday": "—", "hour": 0, "tokens": 0}
    max_val = -1
    min_val = math.inf
    weekday_names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    for wd in range(7):
        for hr in range(24):
            v = grid[wd][hr]
            if v > max_val:
                max_val = v
                peak_cell = {"weekday": weekday_names[wd], "hour": hr, "tokens": v}
            row_has_activity = any(grid[wd])
            if row_has_activity and v < min_val:
                min_val = v
                deadzone = {"weekday": weekday_names[wd], "hour": hr, "tokens": v}

    if daily_tokens:
        sorted_d = sorted(daily_tokens)
        median = _quantile(sorted_d, 0.5)
        sigma = statistics.pstdev(daily_tokens) if len(daily_tokens) > 1 else 0
        anomalies = []
        if sigma > 0:
            for b in daily:
                tok = b.get("totalTokens", 0)
                z = (tok - median) / sigma
                if abs(z) >= 3:
                    anomalies.append({
                        "date":           b.get("label"),
                        "tokens":         tok,
                        "tokens_compact": _compact(tok),
                        "z_score":        round(z, 2),
                        "direction":      "upper" if z > 0 else "lower",
                    })
            anomalies.sort(key=lambda a: abs(a["z_score"]), reverse=True)
    else:
        anomalies = []

    return {
        "distribution_stats": {
            "daily_tokens":         _stats(daily_tokens),
            "daily_prompts":        _stats(daily_prompts),
            "content_length_chars": _stats(content_lengths),
        },
        "hourly_heatmap": {
            "grid":      grid,
            "peak_cell": peak_cell,
            "deadzone":  deadzone,
        },
        "anomalies": anomalies[:8],
    }


def derive_essay(payload: dict) -> dict:
    daily = payload["timeline"]["byDay"]
    earliest = _parse_date(payload["dataWindow"]["earliest"])
    latest = _parse_date(payload["dataWindow"]["latest"])
    active_dates = {_parse_date(b["label"]) for b in daily if "label" in b and b.get("totalTokens", 0) > 0}
    span_days = (latest - earliest).days + 1
    all_dates = {earliest + dt.timedelta(days=i) for i in range(span_days)}
    inactive = sorted(all_dates - active_dates)

    weekday_gaps: Dict[str, int] = collections.defaultdict(int)
    for d in inactive:
        weekday_gaps[d.strftime("%a")] += 1

    last_seen_dt = latest
    projects = payload.get("projects", [])
    stalled = []
    for p in sorted(projects, key=lambda p: p.get("totalTokens", 0), reverse=True):
        last = p.get("lastSeen")
        if not last:
            continue
        try:
            d = _parse_date(last)
        except ValueError:
            continue
        days_idle = (last_seen_dt - d).days
        if days_idle <= 30:
            continue
        stalled.append({
            "project":        p.get("name"),
            "last_seen":      last.split("T")[0],
            "days_idle":      days_idle,
            "tokens":         p.get("totalTokens", 0),
            "tokens_compact": _compact(p.get("totalTokens", 0)),
        })

    prompts = payload.get("prompts", [])
    long_count = sum(1 for p in prompts if p.get("contentLength", 0) > 16384)
    long_pct = (long_count / len(prompts) * 100) if prompts else 0
    long_chars = [p.get("contentLength", 0) for p in prompts if p.get("contentLength", 0) > 16384]
    avg_long = sum(long_chars) // len(long_chars) if long_chars else 0
    longest_chars = max((p.get("contentLength", 0) for p in prompts), default=0)

    return {
        "negative_space": {
            "inactive_days":      [d.isoformat() for d in inactive[:20]],
            "inactive_day_count": len(inactive),
            "weekday_gaps":       dict(weekday_gaps),
            "stalled_projects":   stalled[:10],
        },
        "long_prompts": {
            "long_prompt_pct": round(long_pct, 1),
            "avg_long_chars":  avg_long,
            "longest_chars":   longest_chars,
            "sample_total":    len(prompts),
        },
    }


def derive_ft(payload: dict) -> dict:
    total_tokens = _total_tokens(payload["timeline"]["byDay"]) or 1
    total_cost = payload.get("cost", {}).get("totalUSD", 0)

    projects = sorted(payload.get("projects", []), key=lambda p: p.get("totalTokens", 0), reverse=True)
    capital = []
    for p in projects[:10]:
        tokens = p.get("totalTokens", 0)
        cost = _project_cost(tokens, total_tokens, total_cost)
        capital.append({
            "project":        p.get("name"),
            "tokens":         tokens,
            "tokens_compact": _compact(tokens),
            "cost_usd":       round(cost, 2),
            "weight_pct":     round(tokens / total_tokens * 100, 2),
            "last_seen":      (p.get("lastSeen") or "").split("T")[0] or None,
        })

    def hhi(item_list, key="totalTokens") -> Tuple[float, str]:
        s = sum(i.get(key, 0) for i in item_list) or 1
        value = sum((i.get(key, 0) / s) ** 2 for i in item_list)
        if value < 0.10:
            interp = "unconcentrated"
        elif value < 0.18:
            interp = "moderately concentrated"
        elif value < 0.25:
            interp = "highly concentrated"
        else:
            interp = "monopolistic"
        return round(value, 4), interp

    proj_hhi, proj_interp = hhi(projects)
    model_hhi, model_interp = hhi(payload.get("models", []))
    agent_hhi, agent_interp = hhi(payload.get("agents", []))

    monthly = _by_month(payload["timeline"]["byDay"])
    monthly_pnl = []
    prev_tokens = None
    for month, tok in monthly.items():
        delta = ((tok - prev_tokens) / prev_tokens * 100) if prev_tokens else None
        cost = tok / total_tokens * total_cost
        monthly_pnl.append({
            "month":          month,
            "tokens":         tok,
            "tokens_compact": _compact(tok),
            "cost_usd":       round(cost, 2),
            "mom_delta_pct":  round(delta, 1) if delta is not None else None,
        })
        prev_tokens = tok

    return {
        "capital_allocation": capital,
        "herfindahl": {
            "projects": {"hhi": proj_hhi,  "interpretation": proj_interp},
            "models":   {"hhi": model_hhi, "interpretation": model_interp},
            "agents":   {"hhi": agent_hhi, "interpretation": agent_interp},
        },
        "monthly_pnl": monthly_pnl,
    }


# ─────────────────────────────────────────────────────────────────────────────
# jojo — 6-axis stand stats + prompt intel for psyche analysis
#
# Owned vocabulary: A-E grades, prompt content quotes, verb-frequency, session
# stats. Other personas may NOT use these signals.

# Chinese + English verbs whose frequency in prompt content is signal-bearing
# for the psyche analysis. Keep the list small and high-signal.
_JOJO_VERBS = [
    # restart / iteration
    "重写", "重新", "再来", "重来", "重置", "重构", "重做",
    # destruction
    "删除", "去掉", "干掉", "炸了", "废了",
    # hesitation / questioning
    "为什么", "为啥", "怎么", "能不能",
    # demand / urgency
    "立刻", "马上", "现在", "快点",
    # correction
    "不对", "错了", "改一下", "调整",
    # exploration
    "看看", "试试", "对比",
    # EN verbs
    "fix", "refactor", "rewrite", "explain", "why", "again", "wrong",
]

_SHORT_PROMPT_CHARS = 200
_LONG_PROMPT_CHARS = 5000


def _excerpt(text: str, n: int = 200) -> str:
    s = " ".join(text.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _grade(value: float, thresholds: List[float], reverse: bool = False) -> Tuple[str, float]:
    """Map a numeric metric to A-E grade.
    `thresholds` is a 4-element list of cut points yielding 5 bands (A B C D E).
    `reverse=True` means lower values get higher grades.
    Returns (letter_grade, normalized_0_to_5_score).
    """
    grades = ["A", "B", "C", "D", "E"]
    if reverse:
        for i, t in enumerate(thresholds):
            if value <= t:
                return grades[i], 5 - i
        return "E", 1
    for i, t in enumerate(thresholds):
        if value >= t:
            return grades[i], 5 - i
    return "E", 1


def _near_duplicate_clusters(prompts: List[dict], min_count: int = 3) -> List[dict]:
    """Group prompts by the first ~32 normalized chars to find near-repeats."""
    buckets: Dict[str, List[dict]] = collections.defaultdict(list)
    for p in prompts:
        content = (p.get("content") or "").strip()
        if not content:
            continue
        # Normalize: lower, strip punctuation, keep first 32 chars
        norm = re.sub(r"[\s\W_]+", "", content.lower())[:32]
        if not norm:
            continue
        buckets[norm].append(p)
    out = []
    for norm, items in buckets.items():
        if len(items) < min_count:
            continue
        items_sorted = sorted(items, key=lambda p: p.get("timestamp", ""))
        samples = [
            {
                "timestamp": items_sorted[i].get("timestamp", "").split(".")[0],
                "project":   items_sorted[i].get("projectName"),
                "excerpt":   _excerpt(items_sorted[i].get("content", ""), 80),
            }
            for i in (0, len(items_sorted) // 2, -1)[: min(3, len(items_sorted))]
        ]
        out.append({
            "norm_key":   norm,
            "count":      len(items),
            "first_seen": items_sorted[0].get("timestamp", "").split("T")[0],
            "last_seen":  items_sorted[-1].get("timestamp", "").split("T")[0],
            "samples":    samples,
        })
    out.sort(key=lambda c: c["count"], reverse=True)
    return out[:8]


def _verb_frequency(prompts: List[dict]) -> Dict[str, int]:
    freq: Dict[str, int] = {}
    for v in _JOJO_VERBS:
        freq[v] = 0
    for p in prompts:
        content = (p.get("content") or "").lower()
        for v in _JOJO_VERBS:
            if v.lower() in content:
                freq[v] += 1
    # Sort by count desc; drop zeros
    return {k: c for k, c in sorted(freq.items(), key=lambda kv: kv[1], reverse=True) if c > 0}


def _session_stats(prompts: List[dict]) -> Dict[str, Any]:
    sessions: Dict[str, int] = collections.defaultdict(int)
    for p in prompts:
        sid = p.get("sessionId")
        if sid:
            sessions[sid] += 1
    if not sessions:
        return {"count": 0, "avg_prompts": 0, "max_prompts": 0}
    counts = list(sessions.values())
    return {
        "count":        len(sessions),
        "avg_prompts":  round(sum(counts) / len(counts), 1),
        "max_prompts":  max(counts),
    }


def _project_age_days(payload: dict) -> int:
    """Span (in days) of the longest still-active project (lastSeen within 30d of dataWindow.latest)."""
    latest = _parse_date(payload["dataWindow"]["latest"])
    longest = 0
    for p in payload.get("projects", []):
        first = p.get("firstSeen")
        last = p.get("lastSeen")
        if not first or not last:
            continue
        try:
            d_first = _parse_date(first)
            d_last = _parse_date(last)
        except ValueError:
            continue
        if (latest - d_last).days > 30:
            continue
        span = (d_last - d_first).days
        longest = max(longest, span)
    return longest


def derive_jojo(payload: dict) -> dict:
    daily = payload["timeline"]["byDay"]
    hourly = payload["timeline"]["byHour"]
    prompts = payload.get("prompts", [])

    total_tokens = _total_tokens(daily) or 1
    daily_tokens_vals = [b.get("totalTokens", 0) for b in daily]
    sorted_daily = sorted(daily_tokens_vals)
    median_daily = _quantile(sorted_daily, 0.5) if sorted_daily else 1
    max_daily = sorted_daily[-1] if sorted_daily else 0

    # ── 破坏力 / DESTRUCTIVE POWER
    destruction_verbs = ["重写", "删除", "重构", "重新", "炸了", "废了", "rewrite", "refactor"]
    destruction_count = 0
    for p in prompts:
        content = (p.get("content") or "").lower()
        for v in destruction_verbs:
            if v.lower() in content:
                destruction_count += 1
                break
    destruction_ratio = destruction_count / max(len(prompts), 1)
    top_p50_ratio = (max_daily / median_daily) if median_daily > 0 else 1.0
    # composite: 70% top/median ratio (capped), 30% destruction verb prevalence
    destr_score = min(top_p50_ratio / 5.0, 1.0) * 0.7 + destruction_ratio * 0.3
    destr_grade, destr_norm = _grade(destr_score, [0.7, 0.5, 0.35, 0.2])

    # ── 速度 / SPEED
    hour_total = sum(b.get("totalTokens", 0) for b in hourly) or 1
    peak_hour_share = max((b.get("totalTokens", 0) / hour_total for b in hourly), default=0)
    max_prompts_day = max((b.get("promptCount", 0) for b in daily), default=0)
    speed_score = min(peak_hour_share * 2.5, 1.0) * 0.6 + min(max_prompts_day / 100.0, 1.0) * 0.4
    speed_grade, speed_norm = _grade(speed_score, [0.7, 0.5, 0.35, 0.2])

    # ── 射程 / RANGE
    nproj = len(payload.get("projects", []))
    nmodel = len(payload.get("models", []))
    nagent = len(payload.get("agents", []))
    range_score = min(nproj / 30.0, 1.0) * 0.5 + min(nmodel / 12.0, 1.0) * 0.3 + min(nagent / 3.0, 1.0) * 0.2
    range_grade, range_norm = _grade(range_score, [0.75, 0.55, 0.35, 0.2])

    # ── 持久力 / DURABILITY
    longest_streak, _, _ = _streaks(daily)
    oldest_active = _project_age_days(payload)
    dur_score = min(longest_streak / 80.0, 1.0) * 0.5 + min(oldest_active / 540.0, 1.0) * 0.5
    dur_grade, dur_norm = _grade(dur_score, [0.7, 0.5, 0.35, 0.2])

    # ── 精密性 / PRECISION
    content_lens = [p.get("contentLength", 0) for p in prompts]
    short_pct = (sum(1 for c in content_lens if 0 < c < _SHORT_PROMPT_CHARS) / max(len(content_lens), 1)) * 100
    long_pct = (sum(1 for c in content_lens if c > _LONG_PROMPT_CHARS) / max(len(content_lens), 1)) * 100
    # High precision = many short prompts AND few super-long dumps
    prec_score = (short_pct / 100.0) * 0.7 + (max(0, 30 - long_pct) / 30.0) * 0.3
    prec_grade, prec_norm = _grade(prec_score, [0.65, 0.45, 0.30, 0.15])

    # ── 成长性 / GROWTH POTENTIAL
    dated = sorted(
        ((_parse_date(b["label"]), b.get("totalTokens", 0))
         for b in daily if "label" in b),
        key=lambda kv: kv[0],
    )
    growth_ratio = 1.0
    if len(dated) >= 60:
        first_30 = sum(tok for _, tok in dated[:30])
        last_30 = sum(tok for _, tok in dated[-30:])
        if first_30 > 0:
            growth_ratio = last_30 / first_30
    elif len(dated) >= 14:
        half = len(dated) // 2
        first = sum(tok for _, tok in dated[:half])
        last = sum(tok for _, tok in dated[half:])
        if first > 0:
            growth_ratio = last / first
    growth_score = min(growth_ratio / 4.0, 1.0)
    growth_grade, growth_norm = _grade(growth_score, [0.75, 0.50, 0.30, 0.15])

    # ── prompt_intel
    ultra_long = sorted(
        (p for p in prompts if p.get("contentLength", 0) > _LONG_PROMPT_CHARS),
        key=lambda p: p.get("contentLength", 0),
        reverse=True,
    )[:5]
    ultra_long_dump = [
        {
            "timestamp":  (p.get("timestamp", "") or "").split(".")[0],
            "project":    p.get("projectName"),
            "agent":      p.get("agentDisplayName") or p.get("agent"),
            "chars":      p.get("contentLength", 0),
            "excerpt":    _excerpt(p.get("content", ""), 200),
        }
        for p in ultra_long
    ]

    near_dups = _near_duplicate_clusters(prompts)
    verb_freq = _verb_frequency(prompts)
    sessions = _session_stats(prompts)

    # Sample first/last prompts each day (first 10 days)
    by_day: Dict[str, List[dict]] = collections.defaultdict(list)
    for p in prompts:
        ts = p.get("timestamp", "")
        if "T" in ts:
            by_day[ts.split("T")[0]].append(p)
    first_prompts_each_day = []
    last_prompts_each_day = []
    for d in sorted(by_day.keys())[-10:]:
        items = sorted(by_day[d], key=lambda p: p.get("timestamp", ""))
        if items:
            first_prompts_each_day.append({
                "date":      d,
                "timestamp": items[0].get("timestamp", "").split(".")[0],
                "excerpt":   _excerpt(items[0].get("content", ""), 80),
            })
            last_prompts_each_day.append({
                "date":      d,
                "timestamp": items[-1].get("timestamp", "").split(".")[0],
                "excerpt":   _excerpt(items[-1].get("content", ""), 80),
            })

    # behavioral_extremes
    active_hours = [b.get("hourOfDay") for b in hourly if b.get("totalTokens", 0) > 0]
    first_active = min(active_hours, default=0)
    last_active = max(active_hours, default=0)

    weekday_tokens: Dict[int, int] = collections.defaultdict(int)
    weekend_tokens = 0
    for b in daily:
        try:
            d = _parse_date(b["label"])
        except (KeyError, ValueError):
            continue
        weekday_tokens[d.weekday()] += b.get("totalTokens", 0)
        if d.weekday() >= 5:
            weekend_tokens += b.get("totalTokens", 0)
    weekday_vals = list(weekday_tokens.values())
    if weekday_vals and statistics.fmean(weekday_vals) > 0:
        weekday_cv = statistics.pstdev(weekday_vals) / statistics.fmean(weekday_vals)
    else:
        weekday_cv = 0
    weekend_intensity = weekend_tokens / total_tokens

    composite_norm = (destr_norm + speed_norm + range_norm + dur_norm + prec_norm + growth_norm) / 6.0
    composite_grade, _ = _grade(composite_norm, [4.2, 3.4, 2.6, 1.8])

    return {
        "stand_stats": {
            "composite_rank": composite_grade,
            "axes": [
                {
                    "axis":        "destructive_power",
                    "label_cn":    "破坏力",
                    "label_en":    "DESTRUCTIVE POWER",
                    "grade":       destr_grade,
                    "score":       round(destr_norm, 2),
                    "primary":     f"单日峰值 / 中位 = {top_p50_ratio:.1f}×",
                    "secondary":   f"破坏类动词 prompt 占 {destruction_ratio*100:.0f}%",
                    "top_day_tokens":     max_daily,
                    "median_day_tokens":  median_daily,
                },
                {
                    "axis":      "speed",
                    "label_cn":  "速度",
                    "label_en":  "SPEED",
                    "grade":     speed_grade,
                    "score":     round(speed_norm, 2),
                    "primary":   f"峰值小时占全日 {peak_hour_share*100:.0f}%",
                    "secondary": f"单日 prompt 峰值 {max_prompts_day}",
                },
                {
                    "axis":      "range",
                    "label_cn":  "射程",
                    "label_en":  "RANGE",
                    "grade":     range_grade,
                    "score":     round(range_norm, 2),
                    "primary":   f"{nproj} 项目 · {nmodel} 模型 · {nagent} agents",
                },
                {
                    "axis":      "durability",
                    "label_cn":  "持久力",
                    "label_en":  "DURABILITY",
                    "grade":     dur_grade,
                    "score":     round(dur_norm, 2),
                    "primary":   f"最长 streak {longest_streak} 天",
                    "secondary": f"最老仍活项目跨度 {oldest_active} 天",
                },
                {
                    "axis":      "precision",
                    "label_cn":  "精密性",
                    "label_en":  "PRECISION",
                    "grade":     prec_grade,
                    "score":     round(prec_norm, 2),
                    "primary":   f"短 prompt (< {_SHORT_PROMPT_CHARS} 字) 占 {short_pct:.0f}%",
                    "secondary": f"超长 prompt (> {_LONG_PROMPT_CHARS} 字) 占 {long_pct:.1f}%",
                },
                {
                    "axis":      "growth_potential",
                    "label_cn":  "成长性",
                    "label_en":  "GROWTH POTENTIAL",
                    "grade":     growth_grade,
                    "score":     round(growth_norm, 2),
                    "primary":   f"近期 / 早期 token 比 = {growth_ratio:.2f}×",
                },
            ],
        },
        "prompt_intel": {
            "sample_size":           len(prompts),
            "short_prompt_pct":      round(short_pct, 1),
            "long_prompt_pct":       round(long_pct, 1),
            "ultra_long_prompts":    ultra_long_dump,
            "near_duplicate_clusters": near_dups,
            "verb_frequency":        verb_freq,
            "first_prompts_each_day": first_prompts_each_day,
            "last_prompts_each_day":  last_prompts_each_day,
            "session_stats":         sessions,
        },
        "behavioral_extremes": {
            "first_active_hour":   first_active,
            "last_active_hour":    last_active,
            "weekday_consistency": round(weekday_cv, 3),
            "weekend_intensity":   round(weekend_intensity, 3),
        },
    }


def main() -> int:
    payload = json.load(sys.stdin)
    out = {
        "comic":     derive_comic(payload),
        "brutalist": derive_brutalist(payload),
        "terminal":  derive_terminal(payload),
        "essay":     derive_essay(payload),
        "ft":        derive_ft(payload),
        "jojo":      derive_jojo(payload),
    }
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
