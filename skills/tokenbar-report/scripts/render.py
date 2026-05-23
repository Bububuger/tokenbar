#!/usr/bin/env python3
"""render.py — turn the priced payload + per-persona narrative payloads into
seven themed HTML reports plus an index landing page.

CLI:
    render.py --payload aggregate.json --narratives narratives.json \\
              --output-dir ~/Desktop/tokenbar-report-YYYY-MM-DD/ \\
              --themes-dir <skill-dir>/assets/themes

`narratives.json` shape:
    { "comic": { ...persona blurbs... }, "brutalist": {...}, ... }

Every theme template file (assets/themes/<key>.html) contains `{{placeholder}}`
tokens. The substitution is purely string-level — no logic, no escaping by
template. The renderer is responsible for safe escaping of any user-derived
strings before injecting them.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import html
import json
import math
import os
import pathlib
import re
import sys
from typing import Any, Dict, List, Tuple

PERSONAS = [
    ("comic",     "幽默风趣"),
    ("brutalist", "忠言逆耳"),
    ("terminal",  "数据极客"),
    ("essay",     "哲学反思"),
    ("ft",        "财经评论员"),
    ("jojo",      "人性透视"),
]

# ─────────────────────────────────────────────────────────────────────────────
# Number formatting

def compact_tokens(n: int | float) -> str:
    n = float(n)
    abs_n = abs(n)
    for thresh, suffix in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]:
        if abs_n >= thresh:
            return f"{n / thresh:.2f}{suffix}".rstrip("0").rstrip(".")
    return f"{int(n)}"


def commas(n: int | float) -> str:
    return f"{int(n):,}"


def usd(n: float) -> str:
    if n >= 1000:
        return f"${n:,.0f}"
    return f"${n:,.2f}"


def pct(num: float, denom: float) -> float:
    if denom <= 0:
        return 0.0
    return num / denom * 100


# ─────────────────────────────────────────────────────────────────────────────
# Date utilities

def parse_iso(s: str) -> dt.datetime:
    s = s.replace("Z", "+00:00")
    return dt.datetime.fromisoformat(s)


def days_between(a: str, b: str) -> int:
    da = parse_iso(a).date()
    db = parse_iso(b).date()
    return (db - da).days + 1


# ─────────────────────────────────────────────────────────────────────────────
# Insight derivation

def heaviest_day(daily: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not daily:
        return {"label": "—", "totalTokens": 0, "promptCount": 0}
    return max(daily, key=lambda b: b.get("totalTokens", 0))


def longest_day(day_hour_rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    by_day: Dict[str, set] = collections.defaultdict(set)
    tokens_by_day: Dict[str, int] = collections.defaultdict(int)
    for r in day_hour_rows:
        day = r.get("day")
        hour = r.get("hour-of-day")
        if day is None or hour is None:
            continue
        by_day[day].add(hour)
        tokens_by_day[day] += r.get("totalTokens", 0)
    if not by_day:
        return {"day": "—", "hours": 0, "totalTokens": 0}
    # max distinct hours; tie-break by tokens
    best = max(by_day.items(), key=lambda kv: (len(kv[1]), tokens_by_day[kv[0]]))
    return {"day": best[0], "hours": len(best[1]), "totalTokens": tokens_by_day[best[0]]}


def hour_metrics(hourly: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not hourly:
        return {"peak_label": "—", "peak_tokens": 0, "night_owl_pct": 0, "morning_pct": 0}
    total = sum(b.get("totalTokens", 0) for b in hourly) or 1
    peak = max(hourly, key=lambda b: b.get("totalTokens", 0))
    night = sum(b.get("totalTokens", 0) for b in hourly if b.get("hourOfDay") in {23, 0, 1, 2, 3, 4})
    morning = sum(b.get("totalTokens", 0) for b in hourly if b.get("hourOfDay") in {6, 7, 8, 9, 10})
    return {
        "peak_label": peak.get("label", "—"),
        "peak_tokens": peak.get("totalTokens", 0),
        "night_owl_pct": night / total * 100,
        "morning_pct": morning / total * 100,
    }


def weekday_split(daily: List[Dict[str, Any]]) -> Tuple[float, float]:
    """Returns (weekend_pct, weekday_pct)."""
    weekend, weekday = 0, 0
    for b in daily:
        label = b.get("label")
        if not label:
            continue
        try:
            d = dt.date.fromisoformat(label)
        except ValueError:
            continue
        if d.weekday() >= 5:
            weekend += b.get("totalTokens", 0)
        else:
            weekday += b.get("totalTokens", 0)
    total = weekend + weekday or 1
    return weekend / total * 100, weekday / total * 100


def streaks(daily: List[Dict[str, Any]]) -> Tuple[int, int]:
    """Returns (longest, current)."""
    if not daily:
        return 0, 0
    # Sort by date; an active day is totalTokens > 0.
    dates = sorted(
        ((dt.date.fromisoformat(b["label"]), b.get("totalTokens", 0)) for b in daily if "label" in b),
        key=lambda kv: kv[0],
    )
    longest = current = 0
    prev_date = None
    for d, tok in dates:
        if tok <= 0:
            current = 0
            prev_date = d
            continue
        if prev_date is not None and (d - prev_date).days == 1:
            current += 1
        else:
            current = 1
        longest = max(longest, current)
        prev_date = d
    return longest, current


# ─────────────────────────────────────────────────────────────────────────────
# SVG rendering — class-driven, the theme CSS does the actual styling.

def svg_daily_bars(daily: List[Dict[str, Any]], width: int = 720, height: int = 180) -> str:
    if not daily:
        return f'<svg class="chart daily" viewBox="0 0 {width} {height}"></svg>'
    dated = []
    for b in daily:
        try:
            d = dt.date.fromisoformat(b["label"])
        except (ValueError, KeyError):
            continue
        dated.append((d, b.get("totalTokens", 0)))
    dated.sort()
    if not dated:
        return f'<svg class="chart daily" viewBox="0 0 {width} {height}"></svg>'
    start, end = dated[0][0], dated[-1][0]
    span = (end - start).days + 1
    by_date = {d: tok for d, tok in dated}
    peak_tok = max((tok for _, tok in dated), default=1) or 1
    peak_date = max(dated, key=lambda kv: kv[1])[0]

    bar_w = max(1.0, (width - 12) / span)
    inner_h = height - 24

    bars = []
    for i in range(span):
        d = start + dt.timedelta(days=i)
        tok = by_date.get(d, 0)
        h = (tok / peak_tok) * inner_h if peak_tok else 0
        x = 6 + i * bar_w
        cls = "daily-bar"
        if d == peak_date:
            cls += " daily-bar-peak"
        if tok == 0:
            cls += " daily-bar-empty"
        bars.append(
            f'<rect class="{cls}" x="{x:.2f}" y="{height - 12 - h:.2f}" '
            f'width="{bar_w:.2f}" height="{h:.2f}">'
            f'<title>{d.isoformat()}: {compact_tokens(tok)} tokens</title></rect>'
        )

    # Month tick labels under the bars.
    ticks = []
    seen_months = set()
    for i in range(span):
        d = start + dt.timedelta(days=i)
        ym = (d.year, d.month)
        if ym in seen_months:
            continue
        seen_months.add(ym)
        x = 6 + i * bar_w
        ticks.append(
            f'<text class="axis-label" x="{x:.1f}" y="{height - 2}">{d.strftime("%b")}</text>'
        )

    return (
        f'<svg class="chart daily" viewBox="0 0 {width} {height}" preserveAspectRatio="none">'
        + "".join(bars)
        + "".join(ticks)
        + "</svg>"
    )


def svg_hour_clock(hourly: List[Dict[str, Any]], size: int = 240) -> str:
    """Radial 24-segment dial. The active arc per hour is sized by tokens."""
    cx = cy = size / 2
    outer = size / 2 - 8
    inner = outer * 0.36
    by_hour = {b.get("hourOfDay"): b.get("totalTokens", 0) for b in hourly}
    peak = max(by_hour.values(), default=1) or 1
    peak_hour = max(by_hour.items(), key=lambda kv: kv[1])[0] if by_hour else None

    paths = []
    for h in range(24):
        tok = by_hour.get(h, 0)
        ratio = (tok / peak) if peak else 0
        ratio = max(ratio, 0.05) if tok > 0 else 0.02
        a0 = math.radians((h / 24) * 360 - 90)
        a1 = math.radians(((h + 1) / 24) * 360 - 90)
        r = inner + (outer - inner) * ratio
        x0i = cx + inner * math.cos(a0); y0i = cy + inner * math.sin(a0)
        x1i = cx + inner * math.cos(a1); y1i = cy + inner * math.sin(a1)
        x0o = cx + r * math.cos(a0);     y0o = cy + r * math.sin(a0)
        x1o = cx + r * math.cos(a1);     y1o = cy + r * math.sin(a1)
        path = (
            f"M{x0i:.2f},{y0i:.2f} "
            f"L{x0o:.2f},{y0o:.2f} "
            f"A{r:.2f},{r:.2f} 0 0 1 {x1o:.2f},{y1o:.2f} "
            f"L{x1i:.2f},{y1i:.2f} "
            f"A{inner:.2f},{inner:.2f} 0 0 0 {x0i:.2f},{y0i:.2f} Z"
        )
        cls = "hour-seg"
        if h == peak_hour:
            cls += " hour-seg-peak"
        if tok == 0:
            cls += " hour-seg-empty"
        paths.append(
            f'<path class="{cls}" d="{path}"><title>{h:02d}:00 — '
            f'{compact_tokens(tok)} tokens</title></path>'
        )

    # 12/24/6/18 numerals
    numerals = []
    for h, label in [(0, "00"), (6, "06"), (12, "12"), (18, "18")]:
        a = math.radians((h / 24) * 360 - 90)
        r = outer + 6
        x = cx + r * math.cos(a)
        y = cy + r * math.sin(a) + 4
        anchor = "middle"
        numerals.append(
            f'<text class="hour-tick" x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}">{label}</text>'
        )

    return (
        f'<svg class="chart hour-clock" viewBox="0 0 {size} {size}" width="{size}" height="{size}">'
        + "".join(paths)
        + "".join(numerals)
        + "</svg>"
    )


def svg_cluster_bars(clusters: List[Dict[str, Any]], width: int = 480, row_h: int = 28) -> str:
    if not clusters:
        return ""
    total = sum(c.get("count", 0) for c in clusters) or 1
    height = row_h * len(clusters) + 12
    bar_left = 140
    bar_max = width - bar_left - 70
    rows = []
    peak = max((c.get("count", 0) for c in clusters), default=1) or 1
    for i, c in enumerate(clusters):
        y = 6 + i * row_h
        share = c.get("count", 0) / total * 100
        bar_w = (c.get("count", 0) / peak) * bar_max
        rows.append(
            f'<text class="cluster-label" x="0" y="{y + row_h * 0.65:.1f}">{html.escape(c.get("name","—"))}</text>'
            f'<rect class="cluster-bar" x="{bar_left}" y="{y + row_h * 0.25:.1f}" '
            f'width="{bar_w:.1f}" height="{row_h * 0.55:.1f}"></rect>'
            f'<text class="cluster-pct" x="{width - 4}" y="{y + row_h * 0.65:.1f}" '
            f'text-anchor="end">{share:.0f}%</text>'
        )
    return (
        f'<svg class="chart cluster" viewBox="0 0 {width} {height}" width="100%" height="{height}">'
        + "".join(rows)
        + "</svg>"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Static HTML chunk builders

def models_table_html(models: List[Dict[str, Any]], top_n: int = 8, total_tokens: int = 1) -> str:
    sorted_m = sorted(models, key=lambda m: m.get("totalTokens", 0), reverse=True)[:top_n]
    rows = []
    for m in sorted_m:
        share = pct(m.get("totalTokens", 0), total_tokens)
        method = m.get("costMethod", "default-flat")
        method_tag = '<span class="cost-tag">OVR</span>' if method == "override" else ""
        rows.append(
            '<tr class="model-row">'
            f'<td class="model-name">{html.escape(m.get("name","—"))}</td>'
            f'<td class="model-tokens">{compact_tokens(m.get("totalTokens",0))}</td>'
            f'<td class="model-share">{share:.1f}%</td>'
            f'<td class="model-cost">{usd(m.get("estimatedCostUSD",0))}{method_tag}</td>'
            '</tr>'
        )
    return (
        '<table class="leaderboard models">'
        '<thead><tr><th>Model</th><th>Tokens</th><th>Share</th><th>Cost</th></tr></thead>'
        '<tbody>' + "".join(rows) + '</tbody></table>'
    )


def agents_chart_html(agents: List[Dict[str, Any]], total_tokens: int = 1) -> str:
    sorted_a = sorted(agents, key=lambda a: a.get("totalTokens", 0), reverse=True)
    rows = []
    for a in sorted_a:
        share = pct(a.get("totalTokens", 0), total_tokens)
        rows.append(
            f'<div class="agent-row">'
            f'<span class="agent-name">{html.escape(a.get("displayName","—"))}</span>'
            f'<span class="agent-bar-wrap"><span class="agent-bar" style="width:{share:.1f}%"></span></span>'
            f'<span class="agent-pct">{share:.1f}%</span>'
            f'<span class="agent-tokens">{compact_tokens(a.get("totalTokens",0))}</span>'
            f'</div>'
        )
    return '<div class="agents-chart">' + "".join(rows) + '</div>'


def profile_card_html(profile: Dict[str, Any]) -> str:
    """Render the deep personality profile as a themed class-driven HTML card.
    The theme CSS paints these classes — the structure here is uniform."""
    if not profile:
        return '<div class="profile-card profile-empty">No personality profile authored.</div>'

    def chip(label: str, value: str, kind: str = "") -> str:
        cls = f"profile-chip {kind}".strip()
        return (
            f'<span class="{cls}"><span class="chip-label">{html.escape(label)}</span>'
            f'<span class="chip-value">{html.escape(value)}</span></span>'
        )

    def evidence_block(evidence: Any) -> str:
        if not evidence:
            return ""
        items = evidence if isinstance(evidence, list) else [str(evidence)]
        lis = "".join(f"<li>{html.escape(str(e))}</li>" for e in items)
        return f'<ul class="profile-evidence">{lis}</ul>'

    mastery = profile.get("mastery_level", {}) or {}
    intensity = profile.get("intensity", {}) or {}
    work_style = profile.get("work_style", {}) or {}
    tooling = profile.get("tooling_sophistication", {}) or {}
    traits = profile.get("personality_traits", []) or []
    quirks = profile.get("quirks", []) or []

    parts = ['<div class="profile-card">']

    # Headline rating row: mastery + intensity + tooling (the 3 "level" enums)
    parts.append('<div class="profile-headline">')
    parts.append(chip("MASTERY", mastery.get("rating", "—"), f"mastery-{mastery.get('rating','unknown')}"))
    parts.append(chip("INTENSITY", intensity.get("rating", "—"), f"intensity-{intensity.get('rating','unknown')}"))
    parts.append(chip("TOOLING", tooling.get("rating", "—"), f"tooling-{tooling.get('rating','unknown')}"))
    confidence_bits = []
    if mastery.get("confidence"):
        confidence_bits.append(f"mastery·{mastery['confidence']}")
    if intensity.get("confidence"):
        confidence_bits.append(f"intensity·{intensity['confidence']}")
    if confidence_bits:
        parts.append(f'<span class="profile-confidence">confidence: {html.escape(" / ".join(confidence_bits))}</span>')
    parts.append('</div>')

    # Work-style 4-axis composite
    if work_style:
        parts.append('<div class="profile-section profile-workstyle">')
        parts.append('<div class="profile-section-head">WORK STYLE</div>')
        parts.append('<div class="profile-axes">')
        for axis in ("tempo", "preference", "focus", "scheduling"):
            v = work_style.get(axis)
            if v:
                parts.append(
                    f'<div class="profile-axis"><div class="axis-name">{axis}</div>'
                    f'<div class="axis-value axis-{html.escape(str(v))}">{html.escape(str(v))}</div></div>'
                )
        parts.append('</div>')
        parts.append(evidence_block(work_style.get("evidence")))
        parts.append('</div>')

    # Per-section evidence panels for mastery + intensity + tooling
    for section_name, section_data in (("MASTERY", mastery), ("INTENSITY", intensity), ("TOOLING", tooling)):
        evidence = section_data.get("evidence")
        if evidence:
            parts.append(
                f'<div class="profile-section profile-{section_name.lower()}-evidence">'
                f'<div class="profile-section-head">{section_name} · evidence</div>'
                f'{evidence_block(evidence)}'
                f'</div>'
            )

    # Personality traits (3-5)
    if traits:
        parts.append('<div class="profile-section profile-traits">')
        parts.append('<div class="profile-section-head">TRAITS</div>')
        parts.append('<div class="profile-trait-list">')
        for t in traits:
            name = html.escape(str(t.get("trait", "—")))
            ev = html.escape(str(t.get("evidence", "")))
            parts.append(
                f'<div class="profile-trait"><div class="trait-name">{name}</div>'
                f'<div class="trait-evidence">{ev}</div></div>'
            )
        parts.append('</div></div>')

    # Quirks (specific patterns)
    if quirks:
        parts.append('<div class="profile-section profile-quirks">')
        parts.append('<div class="profile-section-head">QUIRKS</div>')
        parts.append('<ul class="profile-quirk-list">')
        for q in quirks:
            parts.append(f'<li>{html.escape(str(q))}</li>')
        parts.append('</ul></div>')

    parts.append('</div>')
    return "".join(parts)


def projects_list_html(projects: List[Dict[str, Any]], latest_iso: str, top_n: int = 10) -> str:
    sorted_p = sorted(projects, key=lambda p: p.get("totalTokens", 0), reverse=True)[:top_n]
    latest = parse_iso(latest_iso).date() if latest_iso else dt.date.today()
    rows = []
    for p in sorted_p:
        last = p.get("lastSeen")
        days_ago = ""
        if last:
            try:
                d = parse_iso(last).date()
                delta = (latest - d).days
                if delta > 0:
                    days_ago = f' <span class="project-stale">— {delta}d ago</span>'
            except Exception:
                pass
        rows.append(
            f'<li class="project-row">'
            f'<span class="project-name">{html.escape(p.get("name","—"))}</span>'
            f'<span class="project-tokens">{compact_tokens(p.get("totalTokens",0))}</span>'
            f'{days_ago}'
            f'</li>'
        )
    return '<ol class="projects-list">' + "".join(rows) + '</ol>'


# ─────────────────────────────────────────────────────────────────────────────
# Per-persona signature section builders
#
# Each persona has 3 signature sections (defined in references/personas/<key>.md).
# These builders consume the subagent's `data` block + the orchestrator's
# `python_derived` block and emit class-driven HTML chunks the theme CSS
# paints. The theme HTML references them via {{<section>}} placeholders.

def _esc(s: Any) -> str:
    return html.escape(str(s)) if s is not None else "—"


# ── comic ──────────────────────────────────────────────────────────────────

def comic_pop_culture_html(equivalents: List[Dict[str, Any]]) -> str:
    if not equivalents:
        return ""
    rows = []
    for e in equivalents:
        count = e.get("count", 0)
        count_str = f"{count:,.0f}" if count >= 100 else f"{count:.1f}"
        rows.append(
            f'<div class="pop-row">'
            f'<span class="pop-count">{count_str}×</span>'
            f'<span class="pop-unit">{_esc(e.get("unit"))}</span>'
            f'<span class="pop-blurb">{_esc(e.get("blurb"))}</span>'
            f'</div>'
        )
    return '<div class="pop-culture">' + "".join(rows) + '</div>'


def comic_hall_of_shame_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return '<p class="empty">数据太干净，找不出锅。难得。</p>'
    rows = []
    for e in entries:
        samples = e.get("samples") or []
        sample_html = ""
        if samples:
            sample_html = '<ul class="shame-samples">' + "".join(
                f'<li>"{_esc(s)[:100]}"</li>' for s in samples[:2]
            ) + "</ul>"
        rows.append(
            f'<div class="shame-row">'
            f'<div class="shame-head"><span class="shame-pattern">{_esc(e.get("pattern"))}</span>'
            f'<span class="shame-count">× {e.get("occurrences", 0)}</span></div>'
            f'{sample_html}'
            f'<div class="shame-blurb">{_esc(e.get("blurb"))}</div>'
            f'</div>'
        )
    return '<div class="hall-of-shame">' + "".join(rows) + '</div>'


def comic_trivia_html(items: List[Dict[str, Any]]) -> str:
    if not items:
        return ""
    rows = []
    for it in items:
        rows.append(
            f'<div class="trivia-row">'
            f'<div class="trivia-label">{_esc(it.get("label"))}</div>'
            f'<div class="trivia-value">{_esc(it.get("value"))}</div>'
            f'<div class="trivia-blurb">{_esc(it.get("blurb"))}</div>'
            f'</div>'
        )
    return '<div class="trivia-grid">' + "".join(rows) + '</div>'


# ── brutalist ──────────────────────────────────────────────────────────────

def brutalist_stale_debt_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return '<p class="empty">No stale ledger. (For once.)</p>'
    rows = []
    for e in entries:
        status_class = f"stale-{_esc(e.get('status', 'stale'))}"
        rows.append(
            f'<tr class="{status_class}">'
            f'<td class="ledger-project">{_esc(e.get("project"))}</td>'
            f'<td class="ledger-tokens">{_esc(e.get("tokens_compact"))}</td>'
            f'<td class="ledger-cost">${e.get("cost_usd", 0):,.0f}</td>'
            f'<td class="ledger-days">{e.get("days_idle", 0)}d</td>'
            f'<td class="ledger-status">{_esc(e.get("status"))}</td>'
            f'<td class="ledger-verdict">{_esc(e.get("verdict"))}</td>'
            f'</tr>'
        )
    return (
        '<table class="stale-ledger">'
        '<thead><tr><th>PROJECT</th><th>TOKENS</th><th>COST</th><th>IDLE</th><th>STATUS</th><th>VERDICT</th></tr></thead>'
        '<tbody>' + "".join(rows) + '</tbody></table>'
    )


def brutalist_dependence_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return ""
    rows = []
    for e in entries:
        rating = _esc(e.get("rating", "—"))
        rows.append(
            f'<div class="dep-row dep-{rating}">'
            f'<div class="dep-axis">{_esc(e.get("axis","—")).upper()}</div>'
            f'<div class="dep-value">{_esc(e.get("value"))}</div>'
            f'<div class="dep-rating">{rating}</div>'
            f'<div class="dep-verdict">{_esc(e.get("verdict"))}</div>'
            f'</div>'
        )
    return '<div class="dependence-index">' + "".join(rows) + '</div>'


def brutalist_repeat_offenders_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return '<p class="empty">No repeated patterns above threshold.</p>'
    rows = []
    for e in entries:
        rows.append(
            f'<div class="repeat-row">'
            f'<div class="repeat-head">'
            f'<span class="repeat-pattern">{_esc(e.get("pattern"))}</span>'
            f'<span class="repeat-count">× {e.get("count", 0)}</span></div>'
            f'<div class="repeat-span">{_esc(e.get("first_seen"))} → {_esc(e.get("last_seen"))}</div>'
            f'<div class="repeat-verdict">{_esc(e.get("verdict"))}</div>'
            f'</div>'
        )
    return '<div class="repeat-offenders">' + "".join(rows) + '</div>'


# ── terminal ───────────────────────────────────────────────────────────────

def terminal_distribution_html(stats: Dict[str, Any]) -> str:
    if not stats:
        return ""

    def fmt(v: float) -> str:
        if v >= 1_000_000:
            return f"{v / 1_000_000:.2f}M"
        if v >= 1_000:
            return f"{v / 1_000:.1f}K"
        return f"{int(v)}"

    sections = []
    for metric_key, label in [
        ("daily_tokens", "daily-tokens"),
        ("daily_prompts", "daily-prompts"),
        ("content_length_chars", "content-length"),
    ]:
        s = stats.get(metric_key, {})
        if not s:
            continue
        comment = s.get("comment", "")
        sections.append(
            f'<div class="dist-row">'
            f'<div class="dist-name">{label}</div>'
            f'<div class="dist-cells">'
            f'<span class="dist-cell"><span class="dist-label">p50</span><span class="dist-val">{fmt(s.get("p50", 0))}</span></span>'
            f'<span class="dist-cell"><span class="dist-label">p90</span><span class="dist-val">{fmt(s.get("p90", 0))}</span></span>'
            f'<span class="dist-cell"><span class="dist-label">p99</span><span class="dist-val">{fmt(s.get("p99", 0))}</span></span>'
            f'<span class="dist-cell"><span class="dist-label">σ</span><span class="dist-val">{fmt(s.get("sigma", 0))}</span></span>'
            f'<span class="dist-cell"><span class="dist-label">max</span><span class="dist-val">{fmt(s.get("max", 0))}</span></span>'
            f'</div>'
            f'<div class="dist-comment">// {_esc(comment)}</div>'
            f'</div>'
        )
    return '<div class="distributions">' + "".join(sections) + '</div>'


def terminal_heatmap_svg(heatmap: Dict[str, Any]) -> str:
    if not heatmap:
        return ""
    grid = heatmap.get("grid") or [[0] * 24 for _ in range(7)]
    max_v = max((v for row in grid for v in row), default=0) or 1

    cell_w = 22
    cell_h = 22
    label_w = 40
    width = label_w + 24 * cell_w
    height = cell_h * 7 + 28
    days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    cells = []
    for wd in range(7):
        cells.append(
            f'<text class="heatmap-day" x="0" y="{28 + wd * cell_h + cell_h * 0.65:.1f}">{days[wd]}</text>'
        )
        for hr in range(24):
            v = grid[wd][hr]
            intensity = v / max_v if max_v else 0
            opacity = max(0.03, intensity)
            cells.append(
                f'<rect class="heat-cell" x="{label_w + hr * cell_w}" y="{28 + wd * cell_h}" '
                f'width="{cell_w - 1}" height="{cell_h - 1}" '
                f'fill-opacity="{opacity:.3f}">'
                f'<title>{days[wd]} {hr:02d}:00 — {compact_tokens(v)} tokens</title></rect>'
            )

    for hr in [0, 6, 12, 18]:
        cells.append(
            f'<text class="heatmap-hour" x="{label_w + hr * cell_w}" y="22">{hr:02d}</text>'
        )
    return (
        f'<svg class="heatmap" viewBox="0 0 {width} {height}" width="100%">'
        + "".join(cells)
        + "</svg>"
    )


def terminal_anomalies_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return '<p class="empty">no anomalies detected (|z| < 3 across window)</p>'
    rows = []
    for e in entries:
        direction_class = f"anom-{_esc(e.get('direction','upper'))}"
        rows.append(
            f'<tr class="{direction_class}">'
            f'<td class="anom-date">{_esc(e.get("date"))}</td>'
            f'<td class="anom-tokens">{_esc(e.get("tokens_compact"))}</td>'
            f'<td class="anom-z">{e.get("z_score", 0):+.1f}σ</td>'
            f'<td class="anom-dir">{_esc(e.get("direction"))}</td>'
            f'<td class="anom-comment">{_esc(e.get("comment", ""))}</td>'
            f'</tr>'
        )
    return (
        '<table class="anomalies"><thead><tr>'
        '<th>date</th><th>tokens</th><th>z-score</th><th>dir</th><th>// comment</th>'
        '</tr></thead><tbody>' + "".join(rows) + '</tbody></table>'
    )


# ── essay ──────────────────────────────────────────────────────────────────

def essay_negative_space_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    parts = []
    headline = _esc(data.get("headline", ""))
    if headline:
        parts.append(f'<div class="ns-headline">{headline}</div>')
    inactive = data.get("inactive_day_count") or 0
    parts.append(f'<div class="ns-stat">{inactive} 个不在场的日子</div>')
    evocative = data.get("evocative_days") or []
    if evocative:
        items = []
        for d in evocative[:5]:
            items.append(
                f'<li><span class="ns-date">{_esc(d.get("date"))}</span>'
                f'<span class="ns-wd">{_esc(d.get("weekday"))}</span>'
                f'<span class="ns-ctx">{_esc(d.get("context",""))}</span></li>'
            )
        parts.append('<ul class="ns-evocative">' + "".join(items) + "</ul>")
    abandoned = data.get("abandoned_projects") or []
    if abandoned:
        items = []
        for p in abandoned[:5]:
            items.append(
                f'<li><span class="ns-proj">{_esc(p.get("name"))}</span>'
                f'<span class="ns-meta">{_esc(p.get("lastSeen"))} · {_esc(p.get("tokensInvested"))}</span>'
                f'<span class="ns-reflect">{_esc(p.get("reflection"))}</span></li>'
            )
        parts.append('<ul class="ns-abandoned">' + "".join(items) + "</ul>")
    essay = data.get("essay") or ""
    if essay:
        parts.append(f'<div class="ns-essay">{_esc(essay).replace(chr(10), "<br><br>")}</div>')
    return '<div class="negative-space">' + "".join(parts) + '</div>'


def essay_recurrence_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return ""
    rows = []
    for e in entries:
        rows.append(
            f'<div class="rec-row">'
            f'<div class="rec-head">'
            f'<span class="rec-project">{_esc(e.get("project"))}</span>'
            f'<span class="rec-trajectory">{_esc(e.get("trajectory","—"))}</span></div>'
            f'<div class="rec-meditation">{_esc(e.get("meditation"))}</div>'
            f'</div>'
        )
    return '<div class="recurrence-diary">' + "".join(rows) + '</div>'


def essay_unread_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    essay = _esc(data.get("essay", ""))
    pct = data.get("long_prompt_pct", 0)
    avg = data.get("avg_long_chars", 0)
    longest = data.get("longest_chars", 0)
    return (
        f'<div class="unread-conversation">'
        f'<div class="unread-stats">'
        f'<span class="unread-stat"><span class="unread-num">{pct}%</span><span class="unread-label">超长 prompt 占比</span></span>'
        f'<span class="unread-stat"><span class="unread-num">{avg:,}</span><span class="unread-label">平均长 prompt 字符</span></span>'
        f'<span class="unread-stat"><span class="unread-num">{longest:,}</span><span class="unread-label">最长一条字符</span></span>'
        f'</div>'
        f'<div class="unread-essay">{essay.replace(chr(10), "<br><br>")}</div>'
        f'</div>'
    )


# ── ft ─────────────────────────────────────────────────────────────────────

def ft_capital_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return ""
    rows = []
    for e in entries:
        delta = e.get("mom_delta_pct")
        delta_str = f"{delta:+.1f}%" if delta is not None else "—"
        rows.append(
            f'<tr class="cap-row">'
            f'<td class="cap-project">{_esc(e.get("project"))}</td>'
            f'<td class="cap-tokens">{_esc(e.get("tokens_compact"))}</td>'
            f'<td class="cap-cost">${e.get("cost_usd", 0):,.0f}</td>'
            f'<td class="cap-weight">{e.get("weight_pct", 0)}%</td>'
            f'<td class="cap-delta">{delta_str}</td>'
            f'<td class="cap-verdict">{_esc(e.get("verdict",""))}</td>'
            f'</tr>'
        )
    return (
        '<table class="capital-table">'
        '<thead><tr><th>Project</th><th>Tokens</th><th>Cost</th><th>Weight</th><th>MoM</th><th>Verdict</th></tr></thead>'
        '<tbody>' + "".join(rows) + '</tbody></table>'
    )


def ft_hhi_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    rows = []
    for axis in ("projects", "models", "agents"):
        entry = data.get(axis) or {}
        hhi_val = entry.get("hhi", 0)
        interp = _esc(entry.get("interpretation", ""))
        verdict = _esc(entry.get("verdict", ""))
        rows.append(
            f'<div class="hhi-row">'
            f'<div class="hhi-axis">{axis.upper()}</div>'
            f'<div class="hhi-value">HHI {hhi_val:.4f}</div>'
            f'<div class="hhi-interp">{interp}</div>'
            f'<div class="hhi-verdict">{verdict}</div>'
            f'</div>'
        )
    return '<div class="hhi-grid">' + "".join(rows) + '</div>'


def ft_pnl_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    months = data.get("months") or []
    obs = _esc(data.get("qoq_observation", ""))
    verdict = _esc(data.get("verdict", ""))
    rows = []
    for m in months:
        delta = m.get("mom_delta_pct")
        delta_str = f"{delta:+.1f}%" if delta is not None else "—"
        rows.append(
            f'<tr class="pnl-row">'
            f'<td class="pnl-month">{_esc(m.get("month"))}</td>'
            f'<td class="pnl-tokens">{_esc(m.get("tokens_compact"))}</td>'
            f'<td class="pnl-cost">${m.get("cost_usd", 0):,.0f}</td>'
            f'<td class="pnl-delta">{delta_str}</td>'
            f'</tr>'
        )
    return (
        '<div class="monthly-pnl">'
        '<table class="pnl-table"><thead><tr><th>Month</th><th>Tokens</th><th>Cost</th><th>MoM</th></tr></thead>'
        '<tbody>' + "".join(rows) + '</tbody></table>'
        f'<div class="pnl-observation">{obs}</div>'
        f'<div class="pnl-verdict">{verdict}</div>'
        '</div>'
    )


# ── jojo ───────────────────────────────────────────────────────────────────

# Mapping from A-E grade to a normalized 0..1 distance from center on the radar
_JOJO_GRADE_TO_R = {"A": 1.0, "B": 0.8, "C": 0.6, "D": 0.4, "E": 0.22}


def jojo_stand_stats_html(data: Dict[str, Any]) -> str:
    """Render the 6-axis stand stats radar + a side panel of per-axis verdicts.
    `data` shape: {"composite_rank":"B", "axes":[{"axis":..,"label_cn":..,"label_en":..,
    "grade":"A","score":4.2,"primary":"...","secondary":"...","verdict":"..."}]}"""
    if not data:
        return ""
    axes = data.get("axes") or []
    if len(axes) != 6:
        # Pad to 6 to keep the radar geometry consistent.
        while len(axes) < 6:
            axes.append({"label_cn": "—", "label_en": "—", "grade": "E", "primary": ""})

    cx = cy = 220
    R = 180
    pts_outer: List[Tuple[float, float]] = []
    pts_axis: List[Tuple[float, float]] = []
    label_pts: List[Tuple[float, float, str, str, str]] = []
    polygon_pts: List[Tuple[float, float]] = []
    for i, ax in enumerate(axes):
        # Top, then clockwise. -90deg offset puts the first vertex on top.
        a = math.radians((360 * i / 6) - 90)
        pts_outer.append((cx + R * math.cos(a), cy + R * math.sin(a)))
        pts_axis.append((cx + R * math.cos(a), cy + R * math.sin(a)))
        # Polygon point uses the grade's radius
        grade = (ax.get("grade") or "E").upper()
        r = R * _JOJO_GRADE_TO_R.get(grade, 0.2)
        polygon_pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        # Label outside the ring
        lr = R + 28
        lx, ly = cx + lr * math.cos(a), cy + lr * math.sin(a)
        label_pts.append((lx, ly, ax.get("label_cn", "—"), ax.get("label_en", "—"), grade))

    # Background concentric rings + radial spokes
    rings = []
    for ratio, letter in zip([1.0, 0.8, 0.6, 0.4, 0.22], ["A", "B", "C", "D", "E"]):
        rings.append(
            f'<polygon class="ring ring-{letter}" '
            + 'points="'
            + " ".join(
                f"{cx + R*ratio*math.cos(math.radians((360*i/6)-90)):.1f},"
                f"{cy + R*ratio*math.sin(math.radians((360*i/6)-90)):.1f}"
                for i in range(6)
            )
            + '"/>'
        )
    spokes = []
    for (x, y) in pts_axis:
        spokes.append(f'<line class="spoke" x1="{cx}" y1="{cy}" x2="{x:.1f}" y2="{y:.1f}"/>')

    poly_pts_str = " ".join(f"{x:.1f},{y:.1f}" for x, y in polygon_pts)
    poly = f'<polygon class="stat-polygon" points="{poly_pts_str}"/>'

    dots = []
    for (x, y) in polygon_pts:
        dots.append(f'<circle class="stat-vertex" cx="{x:.1f}" cy="{y:.1f}" r="5"/>')

    grade_letters = []
    for ratio, letter in zip([1.0, 0.8, 0.6, 0.4, 0.22], ["A", "B", "C", "D", "E"]):
        grade_letters.append(
            f'<text class="ring-label" x="{cx + 4}" y="{cy - R*ratio + 4:.1f}">{letter}</text>'
        )

    labels = []
    for (x, y, cn, en, grade) in label_pts:
        anchor = "middle"
        if x < cx - 20:
            anchor = "end"
        elif x > cx + 20:
            anchor = "start"
        labels.append(
            f'<text class="axis-cn" x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}">{html.escape(cn)}</text>'
            f'<text class="axis-en" x="{x:.1f}" y="{y + 14:.1f}" text-anchor="{anchor}">{html.escape(en)} · {grade}</text>'
        )

    svg = (
        f'<svg class="stand-radar" viewBox="0 0 440 440" width="440" height="440">'
        + "".join(rings)
        + "".join(spokes)
        + "".join(grade_letters)
        + poly
        + "".join(dots)
        + "".join(labels)
        + "</svg>"
    )

    # Per-axis tile list with verdicts beside the radar
    tile_rows = []
    for ax in axes:
        grade = (ax.get("grade") or "E").upper()
        tile_rows.append(
            f'<div class="stand-axis stand-grade-{grade}">'
            f'<div class="stand-axis-head"><span class="stand-axis-cn">{_esc(ax.get("label_cn"))}</span>'
            f'<span class="stand-axis-en">{_esc(ax.get("label_en"))}</span>'
            f'<span class="stand-axis-grade">{grade}</span></div>'
            f'<div class="stand-axis-primary">{_esc(ax.get("primary"))}</div>'
            + (f'<div class="stand-axis-secondary">{_esc(ax.get("secondary"))}</div>' if ax.get("secondary") else "")
            + (f'<div class="stand-axis-verdict">{_esc(ax.get("verdict"))}</div>' if ax.get("verdict") else "")
            + '</div>'
        )

    composite = (data.get("composite_rank") or "—").upper()
    return (
        '<div class="stand-stats-wrap">'
        f'<div class="composite-banner">COMPOSITE · <span class="composite-grade composite-{composite}">{composite}</span></div>'
        '<div class="stand-stats-grid">'
        f'<div class="stand-radar-wrap">{svg}</div>'
        f'<div class="stand-axes-list">{"".join(tile_rows)}</div>'
        '</div></div>'
    )


def jojo_psyche_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return '<p class="empty">分析样本不足以建立画像。</p>'
    rows = []
    for e in entries:
        meta = e.get("evidence_meta") or {}
        meta_str = " · ".join(
            filter(None, [meta.get("timestamp"), meta.get("project"), meta.get("agent")])
        )
        quote = e.get("evidence_quote") or ""
        rows.append(
            '<div class="psyche-card">'
            f'<div class="psyche-trait">{_esc(e.get("trait_name"))}</div>'
            f'<blockquote class="psyche-evidence">{_esc(quote)}</blockquote>'
            f'<div class="psyche-meta">{_esc(meta_str)}</div>'
            f'<div class="psyche-clinical">{_esc(e.get("clinical_note"))}</div>'
            f'<div class="psyche-dark">{_esc(e.get("darker_read"))}</div>'
            '</div>'
        )
    return '<div class="psyche-grid">' + "".join(rows) + '</div>'


def jojo_stand_card_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    return (
        '<div class="stand-card">'
        f'<div class="stand-card-label">STAND ACQUIRED</div>'
        f'<div class="stand-card-name">{_esc(data.get("stand_name"))}</div>'
        f'<div class="stand-card-type">{_esc(data.get("stand_type"))}</div>'
        f'<div class="stand-card-master">USER · {_esc(data.get("master"))}</div>'
        f'<div class="stand-card-verdict">「{_esc(data.get("fatalistic_verdict"))}」</div>'
        '</div>'
    )


# ─────────────────────────────────────────────────────────────────────────────
# Placeholder substitution

PLACEHOLDER_RE = re.compile(r"\{\{\s*([a-zA-Z0-9_]+)\s*\}\}")


def substitute(template: str, values: Dict[str, Any], *, lenient: bool = False) -> Tuple[str, List[str]]:
    missing: List[str] = []

    def repl(m: re.Match) -> str:
        key = m.group(1)
        if key in values:
            return str(values[key])
        missing.append(key)
        return "" if lenient else m.group(0)

    return PLACEHOLDER_RE.sub(repl, template), missing


# ─────────────────────────────────────────────────────────────────────────────
# Index page

INDEX_HTML = r"""<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<title>TokenBar Report · {start} → {end}</title>
<style>
  :root {{ color-scheme: dark; --paper:#0a0a0a; --gold:#d4af37; --ink:#eaeaea; }}
  * {{ box-sizing:border-box; }}
  html, body {{ height:100%; }}
  body {{
    margin:0; padding:0;
    font-family:-apple-system,BlinkMacSystemFont,'PingFang SC',Helvetica,sans-serif;
    background:
      radial-gradient(circle at 18% 12%, rgba(212,175,55,.10) 0, transparent 36%),
      radial-gradient(circle at 82% 88%, rgba(58,31,93,.18)  0, transparent 40%),
      var(--paper);
    color:var(--ink);
    overflow-x:hidden;
  }}
  header {{
    padding:36px 32px 16px; max-width:1200px; margin:0 auto;
    display:flex; justify-content:space-between; align-items:baseline; gap:16px; flex-wrap:wrap;
  }}
  header h1 {{ font-size:34px; margin:0; letter-spacing:-0.02em; font-weight:900; }}
  header .sub {{ color:#aaa; margin:0; font-size:13px; line-height:1.6; }}

  /* Stage = the area where the deck and the revealed card live */
  .stage {{
    position:relative;
    height: 520px;
    max-width:1200px;
    margin: 0 auto 24px;
    display:flex; align-items:center; justify-content:center;
    perspective: 1400px;
  }}

  /* Each card: dual-faced 3D, positioned absolutely so we can fan them in CSS */
  .card3d {{
    position:absolute;
    width:300px; height:430px;
    transform-style:preserve-3d;
    transition: transform .9s cubic-bezier(.22,.61,.36,1), opacity .4s ease;
    cursor:pointer;
    will-change: transform;
  }}
  .card3d .face {{
    position:absolute; inset:0;
    backface-visibility: hidden;
    -webkit-backface-visibility: hidden;
    border-radius:18px;
    padding:24px 22px;
    box-shadow: 0 24px 60px rgba(0,0,0,.55), 0 0 0 1px rgba(255,255,255,.04) inset;
    display:flex; flex-direction:column; justify-content:space-between;
  }}
  .card3d .back {{
    background:
      repeating-linear-gradient(45deg, rgba(212,175,55,.06) 0 8px, transparent 8px 16px),
      linear-gradient(135deg, #1a1a2e 0%, #0a0a0a 100%);
    color:var(--gold);
    border:2px solid var(--gold);
    text-align:center;
  }}
  .card3d .back .seal {{
    font-family:Impact,"Bebas Neue",sans-serif;
    font-size:64px; line-height:1; letter-spacing:.04em;
    margin-top:auto; margin-bottom:auto;
    opacity:.88;
    text-shadow: 0 2px 0 rgba(0,0,0,.4);
  }}
  .card3d .back .seal-sub {{
    font-family:Impact,"Bebas Neue",sans-serif;
    font-size:10px; letter-spacing:.32em; opacity:.55; margin-bottom:8px;
  }}
  .card3d .back .seal-label {{
    font-size:11px; letter-spacing:.24em; opacity:.5; margin-top:8px;
  }}
  .card3d .front {{
    transform: rotateY(180deg);
    color:#fff;
  }}
  .card3d .front .pid {{ font-size:11px; opacity:.7; letter-spacing:.16em; text-transform:uppercase; }}
  .card3d .front .ptitle {{ font-size:30px; font-weight:900; line-height:1.1; letter-spacing:-0.02em; margin:8px 0 4px; }}
  .card3d .front .plabel {{ font-size:14px; opacity:.85; margin-bottom:12px; }}
  .card3d .front .psub {{ font-size:13px; line-height:1.5; opacity:.9; }}
  .card3d .front .cta {{ margin-top:auto; font-size:12px; letter-spacing:.18em; text-transform:uppercase; opacity:.7; }}

  /* Deck arrangement: 6 cards stacked & fanned */
  .card3d.in-deck:nth-child(1) {{ transform: translate3d(-2px, 6px, 0) rotateZ(-3deg); z-index:1; }}
  .card3d.in-deck:nth-child(2) {{ transform: translate3d( 1px, 3px, 0) rotateZ(-1.4deg); z-index:2; }}
  .card3d.in-deck:nth-child(3) {{ transform: translate3d( 0px, 0px, 0) rotateZ( 0.0deg); z-index:3; }}
  .card3d.in-deck:nth-child(4) {{ transform: translate3d( 2px,-2px, 0) rotateZ( 1.0deg); z-index:4; }}
  .card3d.in-deck:nth-child(5) {{ transform: translate3d(-1px,-4px, 0) rotateZ( 2.0deg); z-index:5; }}
  .card3d.in-deck:nth-child(6) {{ transform: translate3d( 3px,-7px, 0) rotateZ( 3.0deg); z-index:6; }}

  /* Drawn (the picked card flies forward and flips) */
  .card3d.drawn {{
    transform: translate3d(0, -10px, 80px) rotateY(180deg) rotateZ(0deg) scale(1.05);
    z-index:200;
  }}
  /* Others slide aside */
  .card3d.shoved-left  {{ transform: translate3d(-440px, 30px, -60px) rotateZ(-12deg); opacity:.4; }}
  .card3d.shoved-right {{ transform: translate3d( 440px, 30px, -60px) rotateZ( 12deg); opacity:.4; }}

  .controls {{
    text-align:center; margin: 18px 0 24px;
    display:flex; justify-content:center; gap:14px; flex-wrap:wrap;
  }}
  button.draw, button.reshuffle {{
    appearance:none; cursor:pointer; border:none;
    padding:14px 28px; font-size:13px; font-weight:800;
    letter-spacing:.22em; text-transform:uppercase;
    border-radius:999px; transition:transform .12s;
  }}
  button.draw {{ background:var(--gold); color:#0a0a0a; }}
  button.reshuffle {{ background:#222; color:#eee; border:1px solid #444; }}
  button.draw:hover, button.reshuffle:hover {{ transform:translateY(-2px); }}

  @media (max-width:880px) {{
    .card3d {{ width:240px; height:340px; }}
    .card3d .back .seal {{ font-size:52px; }}
    .stage {{ height:460px; }}
  }}

  .totals {{
    max-width:1200px; margin:24px auto 48px; padding: 16px 32px 0;
    border-top:1px solid #222; color:#888; font-size:12px; line-height:1.7;
  }}
  .totals b {{ color:var(--ink); font-weight:600; }}

  .hint {{ text-align:center; color:#888; font-size:12px; letter-spacing:.16em; text-transform:uppercase; margin: 6px 0 24px; opacity:.7; }}
{theme_cards_css}
</style></head><body>
  <header>
    <div>
      <h1>TokenBar Report</h1>
      <p class="sub">{start} → {end} · {days} 天 · {total_tokens} tokens · {total_prompts} prompts · {total_cost}</p>
    </div>
    <div class="sub" style="text-align:right;">
      抽一张牌，看看今天的镜头是哪一面<br>
      <span style="opacity:.55;">DRAW A CARD · 6 LENSES · 1 DATASET</span>
    </div>
  </header>

  <p class="hint">点击下方任意卡牌或「DRAW」按钮 · 每次刷新都会重新洗牌</p>

  <div class="stage" id="stage">
{cards3d}
  </div>

  <div class="controls">
    <button class="draw" id="drawBtn">Draw a Card</button>
    <button class="reshuffle" id="reshuffleBtn">Reshuffle</button>
  </div>

  <div class="totals">
    <div><b>Data window:</b> {window_start} → {window_end} ({window_days} 天, {event_count} events)</div>
    <div><b>Models touched:</b> {distinct_models} · <b>Agents:</b> {distinct_agents} · <b>Projects:</b> {distinct_projects}</div>
    <div><b>Cost method:</b> {override_count} model override(s), {default_count} default-rate model(s)</div>
  </div>

<script>
(function() {{
  const stage = document.getElementById('stage');
  const cards = Array.from(stage.querySelectorAll('.card3d'));
  const drawBtn = document.getElementById('drawBtn');
  const reshuffleBtn = document.getElementById('reshuffleBtn');
  let drawn = null;

  function shuffle() {{
    drawn = null;
    cards.forEach(c => c.classList.remove('drawn','shoved-left','shoved-right'));
    // randomize DOM order so the fanning happens with new neighbors each shuffle
    const shuffled = cards.slice().sort(() => Math.random() - 0.5);
    shuffled.forEach((c, i) => {{
      stage.appendChild(c);
      c.classList.add('in-deck');
    }});
  }}

  function draw(target) {{
    if (drawn) return;
    drawn = target;
    drawn.classList.remove('in-deck');
    drawn.classList.add('drawn');
    cards.forEach((c, i) => {{
      if (c !== drawn) {{
        c.classList.remove('in-deck');
        // Alternate left / right shove for visual spread
        c.classList.add(i % 2 === 0 ? 'shoved-left' : 'shoved-right');
      }}
    }});
    // 1.1s later, navigate to that persona's report
    setTimeout(() => {{ window.location.href = drawn.dataset.href; }}, 1100);
  }}

  drawBtn.addEventListener('click', () => {{
    if (drawn) return;
    const inDeck = cards.filter(c => c.classList.contains('in-deck'));
    if (inDeck.length === 0) return;
    const pick = inDeck[Math.floor(Math.random() * inDeck.length)];
    draw(pick);
  }});
  reshuffleBtn.addEventListener('click', shuffle);
  cards.forEach(c => c.addEventListener('click', () => draw(c)));

  shuffle();
}})();
</script>
</body></html>
"""

# Card preview colors per persona (intentionally tight strips of each theme's palette)
PERSONA_CARD_PALETTES = {
    "comic":     ("#FFE94A", "#FF4FA0", "#2BD4F8", "#111"),
    "brutalist": ("#000",    "#000",    "#E0093A", "#fff"),
    "terminal":  ("#0b1419", "#001a08", "#3aff7d", "#3aff7d"),
    "essay":     ("#F5EFE2", "#E7DCC4", "#1c1a16", "#1c1a16"),
    "ft":        ("#FFF1E5", "#FCE3CC", "#0d1b2a", "#0d1b2a"),
    "jojo":      ("#3a1f5d", "#0a0a0a", "#d4af37", "#f4ecd8"),
}


def build_index(payload: Dict[str, Any], narratives: Dict[str, Any]) -> str:
    cards3d = []
    css_chunks = []
    for key, label in PERSONAS:
        bg1, bg2, accent, ink = PERSONA_CARD_PALETTES[key]
        css_chunks.append(
            f"  .card3d[data-key='{key}'] .front {{ background:linear-gradient(135deg, {bg1} 0%, {bg2} 100%); color:{ink}; }}\n"
            f"  .card3d[data-key='{key}'] .front .pid {{ color:{accent}; }}\n"
        )

        persona_payload = narratives.get(key, {}) or {}
        n = persona_payload.get("narrative", persona_payload)
        title = n.get("title", label)
        sub = n.get("hero_subtitle", "—")
        idx = int_idx(key) + 1
        href = f"{idx:02d}-{key}.html"
        title_safe = html.escape(title)
        sub_safe = html.escape(sub)
        label_safe = html.escape(label)
        key_safe = html.escape(key)

        # 3D dual-faced card for the stage deck. Front face hides the key/label
        # behind the reveal — you only see it AFTER the flip.
        cards3d.append(
            f'    <div class="card3d" data-key="{key_safe}" data-href="{href}">'
            f'<div class="face back">'
            f'<div class="seal-sub">TOKENBAR · LENS</div>'
            f'<div class="seal">?</div>'
            f'<div class="seal-label">UNKNOWN</div>'
            f'</div>'
            f'<div class="face front">'
            f'<div>'
            f'<div class="pid">#{idx:02d} · {key_safe}</div>'
            f'<div class="ptitle">{label_safe}</div>'
            f'<div class="plabel">{title_safe}</div>'
            f'<div class="psub">{sub_safe}</div>'
            f'</div>'
            f'<div class="cta">Tap to read →</div>'
            f'</div>'
            f'</div>'
        )

    window = payload.get("queryWindow") or {}
    start = window.get("since") or payload["dataWindow"]["earliest"]
    end = window.get("until") or payload["dataWindow"]["latest"]
    start_d = start.split("T")[0]
    end_d = end.split("T")[0]
    days = days_between(start, end)

    total_tokens = sum(b.get("totalTokens", 0) for b in payload["timeline"]["byDay"])
    total_prompts = sum(a.get("promptCount", 0) for a in payload["agents"])
    total_cost = usd(payload.get("cost", {}).get("totalUSD", 0))

    return INDEX_HTML.format(
        start=start_d,
        end=end_d,
        days=days,
        total_tokens=compact_tokens(total_tokens),
        total_prompts=commas(total_prompts),
        total_cost=total_cost,
        theme_cards_css="".join(css_chunks),
        cards3d="\n".join(cards3d),
        window_start=payload["dataWindow"]["earliest"].split("T")[0],
        window_end=payload["dataWindow"]["latest"].split("T")[0],
        window_days=days_between(payload["dataWindow"]["earliest"], payload["dataWindow"]["latest"]),
        event_count=commas(payload["dataWindow"]["eventCount"]),
        distinct_models=len(payload.get("models", [])),
        distinct_agents=len(payload.get("agents", [])),
        distinct_projects=len(payload.get("projects", [])),
        override_count=payload.get("pricingOverrideCount", 0),
        default_count=payload.get("cost", {}).get("defaultModels", 0),
    )


def int_idx(key: str) -> int:
    for i, (k, _) in enumerate(PERSONAS):
        if k == key:
            return i
    return -1


# ─────────────────────────────────────────────────────────────────────────────
# Main

def derive(payload: Dict[str, Any]) -> Dict[str, Any]:
    daily = payload["timeline"]["byDay"]
    hourly = payload["timeline"]["byHour"]
    total_tokens = sum(b.get("totalTokens", 0) for b in daily) or 0
    total_prompts = sum(a.get("promptCount", 0) for a in payload["agents"])

    heaviest = heaviest_day(daily)
    longest = longest_day(payload["summary"]["byDayHour"])
    hm = hour_metrics(hourly)
    weekend_p, weekday_p = weekday_split(daily)
    streak_long, streak_cur = streaks(daily)

    # First / last prompt date — use dataWindow as the authoritative source.
    first_date = payload["dataWindow"]["earliest"].split("T")[0]
    last_date = payload["dataWindow"]["latest"].split("T")[0]

    prompts = payload.get("prompts", [])
    long_prompt_pct = 0.0
    if prompts:
        long_count = sum(1 for p in prompts if p.get("contentLength", 0) > 16384)
        long_prompt_pct = long_count / len(prompts) * 100

    cost_total = payload.get("cost", {}).get("totalUSD", 0)

    window = payload.get("queryWindow") or {}
    start_iso = window.get("since") or payload["dataWindow"]["earliest"]
    end_iso = window.get("until") or payload["dataWindow"]["latest"]

    return {
        "total_tokens": compact_tokens(total_tokens),
        "total_tokens_full": commas(total_tokens),
        "total_prompts": commas(total_prompts),
        "total_cost_usd": usd(cost_total),
        "override_count": str(payload.get("pricingOverrideCount", 0)),
        "default_models_count": str(payload.get("cost", {}).get("defaultModels", 0)),
        "date_range_start": start_iso.split("T")[0],
        "date_range_end": end_iso.split("T")[0],
        "date_range_days": str(days_between(start_iso, end_iso)),
        "event_count": commas(payload["dataWindow"]["eventCount"]),
        "heaviest_day_date": heaviest.get("label", "—"),
        "heaviest_day_tokens": compact_tokens(heaviest.get("totalTokens", 0)),
        "heaviest_day_prompts": commas(heaviest.get("promptCount", 0)),
        "longest_day_date": longest.get("day", "—"),
        "longest_day_hours": str(longest.get("hours", 0)),
        "longest_day_tokens": compact_tokens(longest.get("totalTokens", 0)),
        "peak_hour_label": hm["peak_label"],
        "peak_hour_tokens": compact_tokens(hm["peak_tokens"]),
        "night_owl_pct": f"{hm['night_owl_pct']:.0f}",
        "morning_pct": f"{hm['morning_pct']:.0f}",
        "weekend_pct": f"{weekend_p:.0f}",
        "weekday_pct": f"{weekday_p:.0f}",
        "streak_longest": str(streak_long),
        "streak_current": str(streak_cur),
        "distinct_projects": str(len(payload.get("projects", []))),
        "distinct_models": str(len(payload.get("models", []))),
        "distinct_agents": str(len(payload.get("agents", []))),
        "first_prompt_date": first_date,
        "last_prompt_date": last_date,
        "long_prompt_pct": f"{long_prompt_pct:.0f}",
        # Pre-rendered HTML chunks
        "daily_bars_svg": svg_daily_bars(daily),
        "hour_clock_svg": svg_hour_clock(hourly),
        "models_table": models_table_html(payload.get("models", []), total_tokens=total_tokens or 1),
        "agents_chart": agents_chart_html(payload.get("agents", []), total_tokens=total_tokens or 1),
        "projects_list": projects_list_html(
            payload.get("projects", []), payload["dataWindow"]["latest"]
        ),
    }


# ─────────────────────────────────────────────────────────────────────────────
# Per-persona placeholder→builder dispatch table.
# Each entry: placeholder_name → (data_key_in_persona_data_block, builder_fn).
PERSONA_BUILDERS: Dict[str, Dict[str, Tuple[str, Any]]] = {
    "comic": {
        "pop_culture":       ("pop_culture_equivalents", comic_pop_culture_html),
        "hall_of_shame":     ("hall_of_shame",           comic_hall_of_shame_html),
        "trivia_card":       ("trivia_card",             comic_trivia_html),
    },
    "brutalist": {
        "stale_debt":        ("stale_debt",              brutalist_stale_debt_html),
        "dependence_index":  ("dependence_index",        brutalist_dependence_html),
        "repeat_offenders":  ("repeat_offenders",        brutalist_repeat_offenders_html),
    },
    "terminal": {
        "distribution_stats": ("distribution_stats",     terminal_distribution_html),
        "hourly_heatmap":    ("hourly_heatmap",          terminal_heatmap_svg),
        "anomaly_log":       ("anomaly_log",             terminal_anomalies_html),
    },
    "essay": {
        "negative_space":    ("negative_space",          essay_negative_space_html),
        "recurrence_diary":  ("recurrence_diary",        essay_recurrence_html),
        "unread_conversation": ("unread_conversation",   essay_unread_html),
    },
    "ft": {
        "capital_allocation_table": ("capital_allocation_table", ft_capital_html),
        "concentration_metrics":    ("concentration_metrics",    ft_hhi_html),
        "monthly_pnl":              ("monthly_pnl",              ft_pnl_html),
    },
    "jojo": {
        "stand_stats":      ("stand_stats",      jojo_stand_stats_html),
        "psyche_breakdown": ("psyche_breakdown", jojo_psyche_html),
        "stand_card":       ("stand_card",       jojo_stand_card_html),
    },
}


def render_persona(
    template: str,
    derived: Dict[str, Any],
    persona_payload: Dict[str, Any],
    persona_key: str,
    persona_label: str,
    cluster_svg: str,
    personality_tag: str,
    profile_card: str,
) -> Tuple[str, List[str]]:
    """
    persona_payload shape:
      { "narrative": { ...flat strings... }, "data": { ...structured signature data... } }
    """
    values = dict(derived)
    values["persona_key"] = persona_key
    values["persona_label"] = persona_label
    values["personality_tag"] = personality_tag
    values["cluster_chart"] = cluster_svg
    values["profile_card"] = profile_card

    # Per-persona signature section HTML chunks (build from persona's data block).
    data_block = persona_payload.get("data", {}) or {}
    builders = PERSONA_BUILDERS.get(persona_key, {})
    for placeholder, (data_key, builder) in builders.items():
        values[placeholder] = builder(data_block.get(data_key))

    # Narrative fields — escape so authors can't break the template HTML.
    narrative = persona_payload.get("narrative") or {}
    for k, v in narrative.items():
        values[k] = html.escape(str(v)).replace("\n", "<br>")

    return substitute(template, values, lenient=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--payload", required=True, help="Aggregated+priced JSON from collect.sh | apply_pricing.py")
    ap.add_argument("--narratives", required=True, help="Per-persona narrative JSON")
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--themes-dir", required=True)
    ap.add_argument("--open", action="store_true", help="`open` the index.html after rendering")
    args = ap.parse_args()

    payload = json.load(open(args.payload))
    narratives = json.load(open(args.narratives))
    themes_dir = pathlib.Path(args.themes_dir)
    out_dir = pathlib.Path(os.path.expanduser(args.output_dir))
    out_dir.mkdir(parents=True, exist_ok=True)

    derived = derive(payload)

    # Shared LLM-authored payload (clusters, tag, deep profile).
    shared = narratives.get("_shared", {})
    clusters = shared.get("clusters", [])
    cluster_svg = svg_cluster_bars(clusters)
    personality_tag = shared.get("personality_tag", "—")
    profile_card = profile_card_html(shared.get("personality_profile") or {})

    summary_lines = []
    for idx, (key, label) in enumerate(PERSONAS, start=1):
        template_path = themes_dir / f"{key}.html"
        if not template_path.exists():
            print(f"render.py: missing template {template_path}", file=sys.stderr)
            continue
        template = template_path.read_text(encoding="utf-8")
        narrative = narratives.get(key, {})
        html_out, missing = render_persona(
            template, derived, narrative, key, label, cluster_svg, personality_tag, profile_card
        )
        out_file = out_dir / f"{idx:02d}-{key}.html"
        out_file.write_text(html_out, encoding="utf-8")
        summary_lines.append(f"  {key:<10s} → {out_file}  ({len(missing)} placeholders unmatched)")

    # Persist the source payload for debugging / re-generation.
    (out_dir / "data.json").write_text(json.dumps(payload, indent=2, ensure_ascii=False))

    index_html = build_index(payload, narratives)
    (out_dir / "index.html").write_text(index_html, encoding="utf-8")
    summary_lines.append(f"  index.html → {out_dir / 'index.html'}")

    print(f"render.py wrote {len(PERSONAS)} themed reports + index to {out_dir}", file=sys.stderr)
    for line in summary_lines:
        print(line, file=sys.stderr)

    if args.open:
        os.system(f'open "{out_dir / "index.html"}"')

    return 0


if __name__ == "__main__":
    sys.exit(main())
