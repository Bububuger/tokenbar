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


def derive_sunrise(payload: dict) -> dict:
    daily = payload["timeline"]["byDay"]
    longest, current, longest_end = _streaks(daily)
    total = _total_tokens(daily)
    distinct_projects = len(payload.get("projects", []))
    distinct_agents = len(payload.get("agents", []))
    distinct_models = len(payload.get("models", []))

    dated = sorted(
        (_parse_date(b["label"]), b.get("totalTokens", 0))
        for b in daily if "label" in b
    )

    def first_day_crossing(threshold: int) -> Optional[str]:
        for d, tok in dated:
            if tok >= threshold:
                return d.isoformat()
        return None

    milestones = []
    for thresh_label, thresh in [
        ("first_1M_day",   1_000_000),
        ("first_10M_day",  10_000_000),
        ("first_100M_day", 100_000_000),
        ("first_500M_day", 500_000_000),
        ("first_1B_day",   1_000_000_000),
    ]:
        when = first_day_crossing(thresh)
        if when:
            milestones.append({
                "badge_id":    thresh_label,
                "name":        f"单日 ≥ {_compact(thresh)} tokens",
                "unlocked_at": when,
            })

    for streak_thresh in [7, 30, 60, 100]:
        if longest >= streak_thresh:
            milestones.append({
                "badge_id":    f"streak_{streak_thresh}",
                "name":        f"{streak_thresh} 天连续编码",
                "unlocked_at": longest_end.isoformat() if longest_end else None,
            })

    if distinct_projects >= 10:
        milestones.append({"badge_id": "projects_10", "name": "10+ 项目并行", "unlocked_at": None})
    if distinct_projects >= 50:
        milestones.append({"badge_id": "projects_50", "name": "50+ 项目触达", "unlocked_at": None})
    if distinct_projects >= 100:
        milestones.append({"badge_id": "projects_100", "name": "100+ 项目触达", "unlocked_at": None})
    if distinct_agents >= 3:
        milestones.append({"badge_id": "agents_3", "name": "多 agent 协同", "unlocked_at": None})
    if distinct_models >= 10:
        milestones.append({"badge_id": "models_10", "name": "10+ 模型探险家", "unlocked_at": None})

    weeks = _by_week(daily)
    weekly_growth = []
    last6 = weeks[-6:]
    for i, (monday, tok) in enumerate(last6):
        prev = last6[i - 1][1] if i > 0 else None
        delta = ((tok - prev) / prev * 100) if prev else None
        weekly_growth.append({
            "week_start":      monday.isoformat(),
            "tokens":          tok,
            "tokens_compact":  _compact(tok),
            "wow_delta_pct":   round(delta, 1) if delta is not None else None,
        })

    next_milestones = []
    for streak_thresh in [30, 60, 100, 200]:
        if longest < streak_thresh:
            next_milestones.append({
                "badge_id": f"streak_{streak_thresh}",
                "name":     f"{streak_thresh} 天连续编码",
                "distance": f"{streak_thresh - longest} 天",
            })

    for thresh in [100_000_000, 500_000_000, 1_000_000_000]:
        if not first_day_crossing(thresh):
            avg_daily = total / max(len(daily), 1)
            if avg_daily > 0:
                next_milestones.append({
                    "badge_id": f"day_{thresh}",
                    "name":     f"单日 ≥ {_compact(thresh)} tokens",
                    "distance": f"~{thresh / max(avg_daily,1):.1f}× 当前日均",
                })

    return {
        "milestones":      milestones,
        "weekly_growth":   weekly_growth,
        "next_milestones": next_milestones[:5],
    }


def derive_notebook(payload: dict) -> dict:
    daily = payload["timeline"]["byDay"]
    hourly = payload["timeline"]["byHour"]

    projects = sorted(payload.get("projects", []), key=lambda p: p.get("totalTokens", 0), reverse=True)
    top_projects = []
    for p in projects[:3]:
        first = p.get("firstSeen")
        last = p.get("lastSeen")
        top_projects.append({
            "project":        p.get("name"),
            "first_seen":     first.split("T")[0] if first else None,
            "last_seen":      last.split("T")[0] if last else None,
            "tokens":         p.get("totalTokens", 0),
            "tokens_compact": _compact(p.get("totalTokens", 0)),
            "promptCount":    p.get("promptCount", 0),
        })

    weeks = _by_week(daily)
    heaviest_week = None
    if weeks:
        monday, total = max(weeks, key=lambda kv: kv[1])
        week_start, week_end = monday, monday + dt.timedelta(days=6)
        daily_breakdown = []
        for b in daily:
            try:
                d = _parse_date(b["label"])
            except (KeyError, ValueError):
                continue
            if week_start <= d <= week_end:
                daily_breakdown.append({
                    "date":           d.isoformat(),
                    "weekday":        d.strftime("%a"),
                    "tokens":         b.get("totalTokens", 0),
                    "tokens_compact": _compact(b.get("totalTokens", 0)),
                })
        heaviest_week = {
            "week_start":     week_start.isoformat(),
            "week_end":       week_end.isoformat(),
            "tokens":         total,
            "tokens_compact": _compact(total),
            "daily":          sorted(daily_breakdown, key=lambda r: r["date"]),
        }

    hour_tokens = [(b.get("hourOfDay", 0), b.get("totalTokens", 0)) for b in hourly]
    band_totals = []
    for h in range(24):
        triple = sum(hour_tokens[(h + i) % 24][1] for i in range(3))
        band_totals.append((h, triple))
    best_band = max(band_totals, key=lambda kv: kv[1]) if band_totals else (0, 0)
    band_label = f"{best_band[0]:02d}:00-{(best_band[0]+3)%24:02d}:00"

    weekday_tokens: Dict[str, int] = collections.defaultdict(int)
    for b in daily:
        try:
            d = _parse_date(b["label"])
        except (KeyError, ValueError):
            continue
        weekday_tokens[d.strftime("%a")] += b.get("totalTokens", 0)
    best_weekday = max(weekday_tokens.items(), key=lambda kv: kv[1])[0] if weekday_tokens else "—"

    broke: List[dict] = []
    avg_weekday_tokens = (sum(weekday_tokens.values()) / max(len(weekday_tokens), 1)) / 7 if weekday_tokens else 0
    for b in daily:
        try:
            d = _parse_date(b["label"])
        except (KeyError, ValueError):
            continue
        tok = b.get("totalTokens", 0)
        if d.weekday() < 5 and tok == 0 and avg_weekday_tokens > 1_000_000:
            broke.append({
                "date":    d.isoformat(),
                "weekday": d.strftime("%A"),
            })

    return {
        "project_arcs":   top_projects,
        "heaviest_week":  heaviest_week,
        "routine": {
            "most_regular_hour_band": band_label,
            "most_regular_weekday":   best_weekday,
            "broke_routine":          broke[:6],
        }
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


def main() -> int:
    payload = json.load(sys.stdin)
    out = {
        "comic":     derive_comic(payload),
        "brutalist": derive_brutalist(payload),
        "terminal":  derive_terminal(payload),
        "essay":     derive_essay(payload),
        "sunrise":   derive_sunrise(payload),
        "notebook":  derive_notebook(payload),
        "ft":        derive_ft(payload),
    }
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
