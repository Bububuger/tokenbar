#!/usr/bin/env python3
"""render.py — turn the priced payload + per-persona narrative payloads into
six themed HTML reports plus an index landing page.

CLI:
    render.py --payload aggregate.json --narratives narratives.json \\
              --output-dir ~/Desktop/tokenbar-report-YYYY-MM-DD/ \\
              --themes-dir <skill-dir>/assets/themes

v5: personas are xiuxian / wuxia / santi / shuihu / talk / jojo. The
shared "dossier" slot is gone — each persona owns its full 5-section
structure, including a题材化的`identity_card`narrative authored by its
subagent.

`narratives.json` shape:
    { "xiuxian": { ...persona blurbs... }, "wuxia": {...}, ... }

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
    ("jojo",    "JOJO"),
    ("bleach",  "死神"),
    ("hxh",     "猎人"),
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


def streaks(daily: List[Dict[str, Any]]) -> Tuple[int, int]:
    if not daily:
        return 0, 0
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
# Shared SVG renderers (used by all personas, styling driven by theme CSS)

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


# ─────────────────────────────────────────────────────────────────────────────
# Static HTML chunk builders

def _esc(s: Any) -> str:
    return html.escape(str(s)) if s is not None else "—"


def models_table_html(models: List[Dict[str, Any]], top_n: int = 8, total_tokens: int = 1) -> str:
    sorted_m = sorted(models, key=lambda m: m.get("totalTokens", 0), reverse=True)[:top_n]
    rows = []
    for m in sorted_m:
        share = pct(m.get("totalTokens", 0), total_tokens)
        rows.append(
            '<tr class="model-row">'
            f'<td class="model-name">{html.escape(m.get("name","—"))}</td>'
            f'<td class="model-tokens">{compact_tokens(m.get("totalTokens",0))}</td>'
            f'<td class="model-share">{share:.1f}%</td>'
            f'<td class="model-cost">{usd(m.get("estimatedCostUSD",0))}</td>'
            '</tr>'
        )
    return (
        '<table class="leaderboard models">'
        '<thead><tr><th>Model</th><th>Tokens</th><th>Share</th><th>Cost</th></tr></thead>'
        '<tbody>' + "".join(rows) + '</tbody></table>'
    )


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
# Persona-specific signature section builders
# Each builder consumes the subagent's `data.<section>` block and returns
# class-driven HTML. Theme CSS does all visual styling.

# NOTE: v6 dropped the 5 prior personas (xiuxian/wuxia/santi/shuihu/talk).
# Section builders below are jojo + bleach + hxh only.


# ── jojo ───────────────────────────────────────────────────────────────────

_JOJO_GRADE_TO_R = {"A": 1.0, "B": 0.8, "C": 0.6, "D": 0.4, "E": 0.22}


def jojo_stand_stats_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    axes = data.get("axes") or []
    if len(axes) != 6:
        while len(axes) < 6:
            axes.append({"label_cn": "—", "label_en": "—", "grade": "E", "primary": ""})

    cx = cy = 220
    R = 180
    pts_axis: List[Tuple[float, float]] = []
    label_pts: List[Tuple[float, float, str, str, str]] = []
    polygon_pts: List[Tuple[float, float]] = []
    for i, ax in enumerate(axes):
        a = math.radians((360 * i / 6) - 90)
        pts_axis.append((cx + R * math.cos(a), cy + R * math.sin(a)))
        grade = (ax.get("grade") or "E").upper()
        r = R * _JOJO_GRADE_TO_R.get(grade, 0.2)
        polygon_pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        lr = R + 28
        lx, ly = cx + lr * math.cos(a), cy + lr * math.sin(a)
        label_pts.append((lx, ly, ax.get("label_cn", "—"), ax.get("label_en", "—"), grade))

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
    spokes = [f'<line class="spoke" x1="{cx}" y1="{cy}" x2="{x:.1f}" y2="{y:.1f}"/>' for (x, y) in pts_axis]

    poly_pts_str = " ".join(f"{x:.1f},{y:.1f}" for x, y in polygon_pts)
    poly = f'<polygon class="stat-polygon" points="{poly_pts_str}"/>'
    dots = [f'<circle class="stat-vertex" cx="{x:.1f}" cy="{y:.1f}" r="5"/>' for (x, y) in polygon_pts]

    grade_letters = [
        f'<text class="ring-label" x="{cx + 4}" y="{cy - R*ratio + 4:.1f}">{letter}</text>'
        for ratio, letter in zip([1.0, 0.8, 0.6, 0.4, 0.22], ["A", "B", "C", "D", "E"])
    ]

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
    cry = data.get("stand_cry") or ""
    cry_html = f'<div class="stand-card-cry">{_esc(cry)}</div>' if cry else ""
    return (
        '<div class="stand-card">'
        f'<div class="stand-card-label">STAND ACQUIRED</div>'
        f'<div class="stand-card-name">{_esc(data.get("stand_name"))}</div>'
        f'<div class="stand-card-type">{_esc(data.get("stand_type"))}</div>'
        f'<div class="stand-card-master">USER · {_esc(data.get("master"))}</div>'
        f'{cry_html}'
        f'<div class="stand-card-verdict">「{_esc(data.get("fatalistic_verdict"))}」</div>'
        '</div>'
    )


def signature_visual_jojo(persona_payload: Dict[str, Any]) -> str:
    """Stand portrait frame — chosen glyph + name + cry + halftone aura."""
    data = persona_payload.get("data") or {}
    sc = data.get("stand_card") or {}
    stand_name = sc.get("stand_name", "「— —」")
    stand_cry = sc.get("stand_cry", "")
    stand_type = sc.get("stand_type", "")
    glyph_svg, accent = _jojo_stand_glyph(stand_name)

    # Halftone dot pattern (background)
    halftone_id = "jojo_ht"
    halftone = (
        f'<defs><pattern id="{halftone_id}" x="0" y="0" width="14" height="14" patternUnits="userSpaceOnUse">'
        f'<circle cx="7" cy="7" r="1.4" fill="{accent}" opacity="0.45"/>'
        '</pattern></defs>'
    )

    # Outer comic-style frame
    frame = (
        f'<rect x="6" y="6" width="488" height="488" fill="none" stroke="#0a0a0a" stroke-width="6"/>'
        f'<rect x="14" y="14" width="472" height="472" fill="url(#{halftone_id})"/>'
        f'<rect x="14" y="14" width="472" height="472" fill="none" stroke="{accent}" stroke-width="2" stroke-dasharray="8 4"/>'
    )

    # STAND ACQUIRED banner
    banner = (
        f'<g transform="translate(250, 50)">'
        f'<rect x="-120" y="-22" width="240" height="44" fill="#0a0a0a" stroke="{accent}" stroke-width="3" transform="skewX(-6)"/>'
        f'<text x="0" y="-2" text-anchor="middle" font-family="Impact,Helvetica,sans-serif" font-size="14" fill="{accent}" letter-spacing="0.32em" font-weight="900" transform="skewX(-6)">STAND ACQUIRED</text>'
        f'<text x="0" y="14" text-anchor="middle" font-family="Impact,Helvetica,sans-serif" font-size="9" fill="#f4ecd8" opacity="0.6" letter-spacing="0.24em" transform="skewX(-6)">{html.escape(stand_type)}</text>'
        '</g>'
    )

    # Glyph centered, scaled into the available area (already drawn around 400x400 origin)
    glyph_group = f'<g transform="translate(50, 60) scale(1.0)">{glyph_svg}</g>'

    # Stand name (large, two-line bold)
    name_block = (
        f'<g transform="translate(250, 440)">'
        f'<text x="0" y="0" text-anchor="middle" font-family="Hiragino Mincho ProN,STKaiti,serif" font-size="22" fill="#0a0a0a" font-weight="900" letter-spacing="0.06em">{html.escape(stand_name)}</text>'
        '</g>'
    )

    # Stand cry — speech-bubble style
    cry_block = ""
    if stand_cry:
        cry_block = (
            f'<g transform="translate(250, 480)">'
            f'<text x="0" y="0" text-anchor="middle" font-family="Hiragino Mincho ProN,STKaiti,serif" font-size="18" fill="{accent}" font-style="italic" font-weight="700">「{html.escape(stand_cry)}」</text>'
            '</g>'
        )

    return (
        '<svg class="signature-visual sv-jojo" viewBox="0 0 500 510" width="100%" preserveAspectRatio="xMidYMid meet">'
        + halftone
        + '<rect width="500" height="510" fill="#f4ecd8"/>'
        + frame
        + banner
        + glyph_group
        + name_block
        + cry_block
        + '</svg>'
    )


# ─────────────────────────────────────────────────────────────────────────────
# bleach + hxh section builders

def bleach_psyche_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return '<p class="empty">心相分析样本不足。</p>'
    rows = []
    for e in entries:
        rows.append(
            '<div class="psyche-card">'
            f'<div class="psyche-trait">{_esc(e.get("trait_name"))}</div>'
            f'<div class="psyche-clinical">{_esc(e.get("evidence"))}</div>'
            f'<div class="psyche-dark">{_esc(e.get("inner_world_note"))}</div>'
            '</div>'
        )
    return '<div class="psyche-grid">' + "".join(rows) + '</div>'


def bleach_zanpakuto_card_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    return (
        '<div class="stand-card">'
        f'<div class="stand-card-label">ZANPAKUTO ACQUIRED · 斩魄刀継承</div>'
        f'<div class="stand-card-name">{_esc(data.get("zanpakuto_name"))}</div>'
        f'<div class="stand-card-type">{_esc(data.get("master_division"))} · {_esc(data.get("master_codename"))}</div>'
        f'<div class="stand-card-cry"><span class="cry-label">始解</span> {_esc(data.get("shikai_name", ""))} 「{_esc(data.get("shikai_call", ""))}」</div>'
        f'<div class="stand-card-cry"><span class="cry-label">卍解</span> {_esc(data.get("bankai_name", ""))} 「{_esc(data.get("bankai_call", ""))}」</div>'
        f'<div class="stand-card-verdict">「{_esc(data.get("inner_path_verdict"))}」</div>'
        '</div>'
    )


def hxh_nen_assessment_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    neighbors = data.get("neighbors") or []
    # Build hexagon radar — re-use jojo radar geometry but label by nen type
    cx = cy = 220
    R = 170
    if len(neighbors) != 6:
        return f'<div class="nen-assessment">{_esc(data.get("diagnosis"))}</div>'
    # Polygon points by affinity
    pts = []
    for i, n in enumerate(neighbors):
        a = math.radians((360 * i / 6) - 90)
        r = R * (n.get("affinity", 0) / 100.0)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    poly = '<polygon class="stat-polygon" points="' + " ".join(f"{x:.1f},{y:.1f}" for x, y in pts) + '"/>'
    # Background ring
    ring_pts = " ".join(
        f"{cx + R*math.cos(math.radians((360*i/6)-90)):.1f},{cy + R*math.sin(math.radians((360*i/6)-90)):.1f}"
        for i in range(6)
    )
    ring = f'<polygon class="ring" points="{ring_pts}"/>'
    # Spokes + labels
    spokes = []
    labels = []
    for i, n in enumerate(neighbors):
        a = math.radians((360 * i / 6) - 90)
        x = cx + R * math.cos(a); y = cy + R * math.sin(a)
        spokes.append(f'<line class="spoke" x1="{cx}" y1="{cy}" x2="{x:.1f}" y2="{y:.1f}"/>')
        lr = R + 32
        lx, ly = cx + lr * math.cos(a), cy + lr * math.sin(a)
        anchor = "middle"
        if lx < cx - 20:
            anchor = "end"
        elif lx > cx + 20:
            anchor = "start"
        is_primary = (n.get("type") == data.get("primary_type"))
        cls = "axis-cn primary" if is_primary else "axis-cn"
        labels.append(
            f'<text class="{cls}" x="{lx:.1f}" y="{ly:.1f}" text-anchor="{anchor}">{html.escape(n.get("type",""))}</text>'
            f'<text class="axis-en" x="{lx:.1f}" y="{ly + 14:.1f}" text-anchor="{anchor}">{html.escape(n.get("label",""))} · {n.get("affinity",0):.0f}</text>'
        )

    svg = (
        f'<svg class="nen-hex" viewBox="0 0 440 440" width="440" height="440">'
        + ring
        + "".join(spokes)
        + poly
        + "".join(labels)
        + "</svg>"
    )
    diagnosis = _esc(data.get("diagnosis"))
    return (
        '<div class="nen-assessment">'
        f'<div class="nen-primary-banner">PRIMARY TYPE · <span class="primary-type">{_esc(data.get("primary_type"))}</span> · {_esc(data.get("primary_label"))} ({data.get("primary_affinity",0):.0f}/100)</div>'
        f'<div class="nen-secondary">SECONDARY · {_esc(data.get("secondary_type"))} · {_esc(data.get("secondary_label"))} ({data.get("secondary_affinity",0):.0f}/100)</div>'
        f'<div class="nen-hex-wrap">{svg}</div>'
        f'<div class="nen-diagnosis">{diagnosis}</div>'
        '</div>'
    )


def hxh_ability_design_html(entries: List[Dict[str, Any]]) -> str:
    if not entries:
        return '<p class="empty">未登録能力。</p>'
    rows = []
    for e in entries:
        rows.append(
            '<div class="ability-card">'
            f'<div class="ability-name-jp">{_esc(e.get("ability_name_jp"))}</div>'
            f'<div class="ability-name-cn">{_esc(e.get("ability_name_cn"))}</div>'
            f'<div class="ability-type">{_esc(e.get("ability_type"))}</div>'
            f'<div class="ability-effect">{_esc(e.get("effect"))}</div>'
            f'<div class="ability-constraint"><span class="label">制約：</span>{_esc(e.get("constraint"))}</div>'
            f'<div class="ability-vow"><span class="label">誓約：</span>{_esc(e.get("vow"))}</div>'
            + (f'<div class="ability-verdict">{_esc(e.get("verdict"))}</div>' if e.get("verdict") else "")
            + '</div>'
        )
    return '<div class="ability-grid">' + "".join(rows) + '</div>'


def hxh_nen_progression_html(data: Dict[str, Any]) -> str:
    if not data:
        return ""
    stages = data.get("stages_mastered") or []
    rows = []
    for s in stages:
        check = "✓" if s.get("mastered") else "—"
        cls = "stage-row mastered" if s.get("mastered") else "stage-row"
        rows.append(
            f'<div class="{cls}">'
            f'<span class="stage-check">{check}</span>'
            f'<span class="stage-name">{_esc(s.get("stage"))}</span>'
            f'<span class="stage-evidence">{_esc(s.get("evidence"))}</span>'
            '</div>'
        )
    return (
        '<div class="nen-progression">'
        + "".join(rows)
        + f'<div class="prog-current">現在の段階：{_esc(data.get("current_stage"))}</div>'
        + f'<div class="prog-next">次の目標：{_esc(data.get("next_milestone"))}</div>'
        + f'<div class="prog-verdict">{_esc(data.get("verdict"))}</div>'
        + '</div>'
    )


# ─────────────────────────────────────────────────────────────────────────────
# Generic image data-URL lookup + per-persona signature visuals
# All embedded as base64 data: URLs so HTML stays offline-capable.

import base64

# Cache: (category, asset_id) → base64 data URL (empty string if no file)
_IMAGE_CACHE: Dict[Tuple[str, str], str] = {}


def _image_data_url(category: str, asset_id: str) -> str:
    """Look for assets/<category>/<asset_id>.{png,webp,jpg} and return a base64
    data URL. Empty string if no file."""
    if not asset_id:
        return ""
    cache_key = (category, asset_id)
    if cache_key in _IMAGE_CACHE:
        return _IMAGE_CACHE[cache_key]
    skill_dir = pathlib.Path(__file__).resolve().parent.parent
    base = skill_dir / "assets" / category
    for ext, mime in [("png", "image/png"), ("webp", "image/webp"), ("jpg", "image/jpeg"), ("jpeg", "image/jpeg")]:
        candidate = base / f"{asset_id}.{ext}"
        if candidate.exists():
            data = candidate.read_bytes()
            b64 = base64.b64encode(data).decode("ascii")
            url = f"data:{mime};base64,{b64}"
            _IMAGE_CACHE[cache_key] = url
            return url
    _IMAGE_CACHE[cache_key] = ""
    return ""


# Stand keyword → id mapping
_STAND_KEYWORDS = [
    ("ger",     ["ゴールド・エクスペリエンス・レクイエム", "黄金体验·安魂曲", "レクイエム"]),
    ("ge",      ["ゴールド・エクスペリエンス", "黄金体验"]),
    ("mih",     ["メイド・イン・ヘブン", "天堂制造"]),
    ("spw",     ["スタープラチナ・ザ・ワールド", "白金之星·世界"]),
    ("tw",      ["ザ・ワールド", "世界"]),
    ("sp",      ["スタープラチナ", "白金之星"]),
    ("kc",      ["キング・クリムゾン", "绯红之王"]),
    ("cd",      ["クレイジー・ダイヤモンド", "疯狂钻石"]),
    ("kq",      ["キラークイーン", "杀手皇后"]),
    ("tusk",    ["タスク", "獠牙"]),
    ("d4c",     ["D4C", "肮脏作乱"]),
    ("sf",      ["スティッキィ", "黏液栗子"]),
    ("sc",      ["シルバー・チャリオッツ", "银色战车"]),
    ("hp",      ["ハーミット・パープル", "隐者之紫"]),
    ("echoes3", ["エコーズ", "回音"]),
    ("ws",      ["ホワイト・スネイク", "白蛇"]),
]

_STAND_THEME_ACCENT = {
    "ger": "#f0c800", "ge": "#f0c800", "mih": "#d04a8c",
    "spw": "#5d3a8c", "tw": "#d4af37", "sp": "#5d3a8c",
    "kc": "#a40e1c", "cd": "#ffb4d8", "kq": "#f4a4c0",
    "tusk": "#d4a574", "d4c": "#3a5a8c", "sf": "#4a8cff",
    "sc": "#c0c0c0", "hp": "#7d4a9c", "echoes3": "#8cc8e8",
    "ws": "#f4f4f4",
}


def _resolve_asset_id(name: str, keyword_map: List[Tuple[str, List[str]]]) -> str:
    s = name or ""
    for sid, keywords in keyword_map:
        for kw in keywords:
            if kw in s:
                return sid
    return ""


def _jojo_stand_glyph(stand_name: str) -> Tuple[str, str]:
    """Returns (svg_glyph_or_image, accent_color). Prefers embedded PNG
    over geometric fallback."""
    stand_id = _resolve_asset_id(stand_name, _STAND_KEYWORDS)
    accent = _STAND_THEME_ACCENT.get(stand_id, "#d4af37")
    img_url = _image_data_url("stands", stand_id) if stand_id else ""
    if img_url:
        return f'<image href="{img_url}" x="0" y="0" width="400" height="400" preserveAspectRatio="xMidYMid meet"/>', accent
    # Fallback: simple placeholder
    return f'<g transform="translate(200,200)"><circle r="120" fill="none" stroke="{accent}" stroke-width="4"/><text x="0" y="14" text-anchor="middle" font-family="Impact,Helvetica,sans-serif" font-size="48" font-weight="900" fill="{accent}">?</text></g>', accent


# Zanpakuto keyword → id mapping
_ZANPAKUTO_KEYWORDS = [
    ("tensa_zangetsu",    ["天鎖斬月", "天锁斩月", "斬月"]),
    ("senbonzakura",      ["千本桜景厳", "千本樱景严", "千本桜"]),
    ("ryujin_jakka",      ["流刃若火", "残火"]),
    ("kyoka_suigetsu",    ["鏡花水月", "镜花水月"]),
    ("kanonji_no_tsuru",  ["片羽の御使い", "片翼天使", "紅姫"]),
    ("hyourinmaru",       ["氷輪丸", "冰轮丸", "大紅蓮"]),
    ("katenkyoukotsu",    ["花天狂骨枯松心中", "花天狂骨"]),
    ("kokujou_tengen",    ["黒縄天譴明王", "黑绳天谴明王"]),
    ("zabimaru",          ["双骨", "蛇尾丸"]),
    ("sodenoshirayuki",   ["袖白雪", "白霞罸"]),
    ("sougyo_kotowari",   ["双魚理", "双鱼理"]),
    ("haineko",           ["灰猫"]),
]


def _bleach_zanpakuto_glyph(zanpakuto_name: str) -> Tuple[str, str]:
    asset_id = _resolve_asset_id(zanpakuto_name, _ZANPAKUTO_KEYWORDS)
    accent = "#e8e2d2"
    img_url = _image_data_url("zanpakuto", asset_id) if asset_id else ""
    if img_url:
        return f'<image href="{img_url}" x="0" y="0" width="400" height="400" preserveAspectRatio="xMidYMid meet"/>', accent
    # Fallback: stylized katana silhouette
    return (
        '<g transform="translate(200,200)">'
        '<line x1="0" y1="-160" x2="0" y2="120" stroke="#e8e2d2" stroke-width="4"/>'
        '<line x1="-30" y1="120" x2="30" y2="120" stroke="#1a1a1a" stroke-width="6"/>'
        '<line x1="0" y1="120" x2="0" y2="170" stroke="#1a1a1a" stroke-width="8"/>'
        '<circle cx="0" cy="175" r="8" fill="#1a1a1a"/>'
        '<polygon points="-6,-160 6,-160 0,-180" fill="#e8e2d2"/>'
        '</g>'
    ), accent


def _hxh_nen_glyph(nen_type: str) -> Tuple[str, str]:
    """Return image for the dominant nen system (assets/nen/<id>.png). Else hexagon."""
    NEN_ID = {
        "強化系":   ("enhancement",   "#e83a3a"),
        "操作系":   ("manipulation",  "#a04acf"),
        "具現化系": ("conjuration",   "#3a8ce8"),
        "放出系":   ("emission",      "#e88c3a"),
        "変化系":   ("transmutation", "#3acf6e"),
        "特質系":   ("specialization", "#d4af37"),
    }
    asset_id, accent = NEN_ID.get(nen_type, ("", "#5dc0ff"))
    img_url = _image_data_url("nen", asset_id) if asset_id else ""
    if img_url:
        return f'<image href="{img_url}" x="0" y="0" width="400" height="400" preserveAspectRatio="xMidYMid meet"/>', accent
    # Fallback: stylized aura sphere
    return (
        f'<g transform="translate(200,200)">'
        f'<circle r="140" fill="none" stroke="{accent}" stroke-width="3" stroke-dasharray="4 4"/>'
        f'<circle r="100" fill="none" stroke="{accent}" stroke-width="2"/>'
        f'<circle r="50" fill="{accent}" opacity="0.4"/>'
        f'<text x="0" y="14" text-anchor="middle" font-family="STKaiti,serif" font-size="40" font-weight="900" fill="{accent}">{_esc(nen_type)}</text>'
        f'</g>'
    ), accent


# ── signature visuals ─────────────────────────────────────────────────────

def signature_visual_jojo(persona_payload: Dict[str, Any]) -> str:
    """Stand portrait — embedded PNG or fallback glyph + halftone JoJo frame."""
    data = persona_payload.get("data") or {}
    sc = data.get("stand_card") or {}
    stand_name = sc.get("stand_name", "「— —」")
    stand_cry = sc.get("stand_cry", "")
    stand_type = sc.get("stand_type", "")
    glyph_svg, accent = _jojo_stand_glyph(stand_name)

    halftone_id = "jojo_ht"
    halftone = (
        f'<defs><pattern id="{halftone_id}" x="0" y="0" width="14" height="14" patternUnits="userSpaceOnUse">'
        f'<circle cx="7" cy="7" r="1.4" fill="{accent}" opacity="0.45"/>'
        '</pattern></defs>'
    )
    frame = (
        f'<rect x="6" y="6" width="488" height="488" fill="none" stroke="#0a0a0a" stroke-width="6"/>'
        f'<rect x="14" y="14" width="472" height="472" fill="url(#{halftone_id})"/>'
        f'<rect x="14" y="14" width="472" height="472" fill="none" stroke="{accent}" stroke-width="2" stroke-dasharray="8 4"/>'
    )
    banner = (
        f'<g transform="translate(250, 50)">'
        f'<rect x="-120" y="-22" width="240" height="44" fill="#0a0a0a" stroke="{accent}" stroke-width="3" transform="skewX(-6)"/>'
        f'<text x="0" y="-2" text-anchor="middle" font-family="Impact,Helvetica,sans-serif" font-size="14" fill="{accent}" letter-spacing="0.32em" font-weight="900" transform="skewX(-6)">STAND ACQUIRED</text>'
        f'<text x="0" y="14" text-anchor="middle" font-family="Impact,Helvetica,sans-serif" font-size="9" fill="#f4ecd8" opacity="0.6" letter-spacing="0.24em" transform="skewX(-6)">{html.escape(stand_type)}</text>'
        '</g>'
    )
    glyph_group = f'<g transform="translate(50, 60) scale(1.0)">{glyph_svg}</g>'
    name_block = (
        f'<g transform="translate(250, 440)">'
        f'<text x="0" y="0" text-anchor="middle" font-family="Hiragino Mincho ProN,STKaiti,serif" font-size="22" fill="#0a0a0a" font-weight="900" letter-spacing="0.06em">{html.escape(stand_name)}</text>'
        '</g>'
    )
    cry_block = ""
    if stand_cry:
        cry_block = (
            f'<g transform="translate(250, 480)">'
            f'<text x="0" y="0" text-anchor="middle" font-family="Hiragino Mincho ProN,STKaiti,serif" font-size="18" fill="{accent}" font-style="italic" font-weight="700">「{html.escape(stand_cry)}」</text>'
            '</g>'
        )

    return (
        '<svg class="signature-visual sv-jojo" viewBox="0 0 500 510" width="100%" preserveAspectRatio="xMidYMid meet">'
        + halftone + '<rect width="500" height="510" fill="#f4ecd8"/>'
        + frame + banner + glyph_group + name_block + cry_block
        + '</svg>'
    )


def signature_visual_bleach(persona_payload: Dict[str, Any]) -> str:
    """Zanpakuto portrait — embedded PNG or katana fallback + 死神 frame
    (dark indigo + silver, with sumi-e brush border)."""
    data = persona_payload.get("data") or {}
    zc = data.get("zanpakuto_card") or {}
    zanpakuto_name = zc.get("zanpakuto_name", "「— —」")
    shikai_call = zc.get("shikai_call", "")
    bankai_call = zc.get("bankai_call", "")
    division = zc.get("master_division", "")
    glyph_svg, accent = _bleach_zanpakuto_glyph(zanpakuto_name)

    # Sumi-e splash backdrop pattern
    sumi = (
        f'<defs>'
        f'<radialGradient id="bleachHalo" cx="50%" cy="50%" r="50%">'
        f'<stop offset="0%" stop-color="{accent}" stop-opacity="0.18"/>'
        f'<stop offset="100%" stop-color="{accent}" stop-opacity="0"/>'
        f'</radialGradient>'
        f'</defs>'
    )
    halo = f'<circle cx="250" cy="270" r="200" fill="url(#bleachHalo)"/>'
    # Vertical sumi-e brush strokes
    strokes = []
    for i in range(8):
        x = 40 + i * 56
        strokes.append(f'<rect x="{x}" y="20" width="6" height="470" fill="#1a1a2a" opacity="0.18"/>')

    frame = (
        f'<rect x="6" y="6" width="488" height="498" fill="none" stroke="{accent}" stroke-width="2"/>'
        f'<rect x="10" y="10" width="480" height="490" fill="none" stroke="#1a1a2a" stroke-width="6"/>'
    )

    # ZANPAKUTO 継承 banner
    banner = (
        f'<g transform="translate(250, 52)">'
        f'<rect x="-130" y="-22" width="260" height="44" fill="#1a1a2a" stroke="{accent}" stroke-width="2"/>'
        f'<text x="0" y="-2" text-anchor="middle" font-family="STKaiti,serif" font-size="14" fill="{accent}" letter-spacing="0.32em" font-weight="900">ZANPAKUTO 継承</text>'
        f'<text x="0" y="14" text-anchor="middle" font-family="STKaiti,serif" font-size="10" fill="#c0c0c0" opacity="0.7" letter-spacing="0.24em">{html.escape(division)}</text>'
        '</g>'
    )

    glyph_group = f'<g transform="translate(50, 70) scale(1.0)">{glyph_svg}</g>'

    name_block = (
        f'<g transform="translate(250, 452)">'
        f'<text x="0" y="0" text-anchor="middle" font-family="STKaiti,Hiragino Mincho ProN,serif" font-size="26" fill="{accent}" font-weight="900" letter-spacing="0.06em">{html.escape(zanpakuto_name)}</text>'
        '</g>'
    )
    calls = []
    if shikai_call:
        calls.append(f'<text x="250" y="478" text-anchor="middle" font-family="STKaiti,serif" font-size="14" fill="#c0c0c0" font-style="italic">始解：「{html.escape(shikai_call)}」</text>')
    if bankai_call:
        calls.append(f'<text x="250" y="496" text-anchor="middle" font-family="STKaiti,serif" font-size="14" fill="{accent}" font-style="italic" font-weight="700">卍解：「{html.escape(bankai_call)}」</text>')

    return (
        '<svg class="signature-visual sv-bleach" viewBox="0 0 500 510" width="100%" preserveAspectRatio="xMidYMid meet">'
        + sumi + '<rect width="500" height="510" fill="#0a0a14"/>'
        + "".join(strokes) + halo + frame + banner + glyph_group + name_block
        + "".join(calls)
        + '</svg>'
    )


def signature_visual_hxh(persona_payload: Dict[str, Any]) -> str:
    """Nen hexagon + dominant 系 visual."""
    data = persona_payload.get("data") or {}
    nen = data.get("nen_assessment") or {}
    primary_type = nen.get("primary_type", "強化系")
    primary_label = nen.get("primary_label", "ENHANCEMENT")
    primary_affinity = nen.get("primary_affinity", 0)
    glyph_svg, accent = _hxh_nen_glyph(primary_type)

    frame = (
        f'<rect x="6" y="6" width="488" height="498" fill="none" stroke="{accent}" stroke-width="2"/>'
        f'<rect x="14" y="14" width="472" height="482" fill="none" stroke="#5dc0ff" stroke-width="1" stroke-dasharray="3 5"/>'
    )

    # "NEN ANALYSIS" banner
    banner = (
        f'<g transform="translate(250, 52)">'
        f'<rect x="-130" y="-22" width="260" height="44" fill="#001428" stroke="{accent}" stroke-width="2"/>'
        f'<text x="0" y="-2" text-anchor="middle" font-family="SF Mono,monospace" font-size="14" fill="{accent}" letter-spacing="0.32em" font-weight="900">NEN ANALYSIS</text>'
        f'<text x="0" y="14" text-anchor="middle" font-family="SF Mono,monospace" font-size="10" fill="#5dc0ff" opacity="0.7" letter-spacing="0.24em">水見式 · 系判定済</text>'
        '</g>'
    )

    glyph_group = f'<g transform="translate(50, 70) scale(1.0)">{glyph_svg}</g>'

    # Primary type label below
    name_block = (
        f'<g transform="translate(250, 452)">'
        f'<text x="0" y="0" text-anchor="middle" font-family="STKaiti,serif" font-size="28" fill="{accent}" font-weight="900" letter-spacing="0.06em">{html.escape(primary_type)}</text>'
        '</g>'
    )
    sub = (
        f'<text x="250" y="478" text-anchor="middle" font-family="SF Mono,monospace" font-size="14" fill="#5dc0ff" letter-spacing="0.16em">{html.escape(primary_label)} · {primary_affinity:.0f}/100</text>'
    )

    # Background star field
    stars = []
    star_pos = [(45, 80, 1), (120, 50, 2), (310, 30, 1), (450, 70, 1), (75, 410, 1), (200, 430, 2), (390, 410, 1)]
    for x, y, sz in star_pos:
        stars.append(f'<circle cx="{x}" cy="{y}" r="{sz}" fill="{accent}" opacity="0.55"/>')

    return (
        '<svg class="signature-visual sv-hxh" viewBox="0 0 500 510" width="100%" preserveAspectRatio="xMidYMid meet">'
        + '<rect width="500" height="510" fill="#0a1a2a"/>'
        + "".join(stars) + frame + banner + glyph_group + name_block + sub
        + '</svg>'
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

  .stage {{
    position:relative;
    height: 520px;
    max-width:1200px;
    margin: 0 auto 24px;
    display:flex; align-items:center; justify-content:center;
    perspective: 1400px;
  }}

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

  .card3d.in-deck:nth-child(1) {{ transform: translate3d(-2px, 6px, 0) rotateZ(-3deg); z-index:1; }}
  .card3d.in-deck:nth-child(2) {{ transform: translate3d( 1px, 3px, 0) rotateZ(-1.4deg); z-index:2; }}
  .card3d.in-deck:nth-child(3) {{ transform: translate3d( 0px, 0px, 0) rotateZ( 0.0deg); z-index:3; }}
  .card3d.in-deck:nth-child(4) {{ transform: translate3d( 2px,-2px, 0) rotateZ( 1.0deg); z-index:4; }}
  .card3d.in-deck:nth-child(5) {{ transform: translate3d(-1px,-4px, 0) rotateZ( 2.0deg); z-index:5; }}
  .card3d.in-deck:nth-child(6) {{ transform: translate3d( 3px,-7px, 0) rotateZ( 3.0deg); z-index:6; }}

  .card3d.drawn {{
    transform: translate3d(0, -10px, 80px) rotateY(180deg) rotateZ(0deg) scale(1.05);
    z-index:200;
  }}
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
        c.classList.add(i % 2 === 0 ? 'shoved-left' : 'shoved-right');
      }}
    }});
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

# Card preview palettes — each tuned to that persona's theme
PERSONA_CARD_PALETTES = {
    "jojo":   ("#3a1f5d", "#0a0a0a", "#d4af37", "#f4ecd8"),
    "bleach": ("#0a0a14", "#1a1a2a", "#e8e2d2", "#c0c0c0"),
    "hxh":    ("#0a1a2a", "#001428", "#5dc0ff", "#f4f0e0"),
}


def build_index(payload: Dict[str, Any], narratives: Dict[str, Any]) -> str:
    cards3d = []
    css_chunks = []
    for key, label in PERSONAS:
        bg1, bg2, accent, ink = PERSONA_CARD_PALETTES.get(key, ("#222", "#000", "#fff", "#fff"))
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

        cards3d.append(
            f'    <div class="card3d" data-key="{html.escape(key)}" data-href="{href}">'
            f'<div class="face back">'
            f'<div class="seal-sub">TOKENBAR · LENS</div>'
            f'<div class="seal">?</div>'
            f'<div class="seal-label">UNKNOWN</div>'
            f'</div>'
            f'<div class="face front">'
            f'<div>'
            f'<div class="pid">#{idx:02d} · {html.escape(key)}</div>'
            f'<div class="ptitle">{html.escape(label)}</div>'
            f'<div class="plabel">{html.escape(title)}</div>'
            f'<div class="psub">{html.escape(sub)}</div>'
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
    streak_long, streak_cur = streaks(daily)

    first_date = payload["dataWindow"]["earliest"].split("T")[0]
    last_date = payload["dataWindow"]["latest"].split("T")[0]
    cost_total = payload.get("cost", {}).get("totalUSD", 0)

    window = payload.get("queryWindow") or {}
    start_iso = window.get("since") or payload["dataWindow"]["earliest"]
    end_iso = window.get("until") or payload["dataWindow"]["latest"]

    return {
        "total_tokens":       compact_tokens(total_tokens),
        "total_tokens_full":  commas(total_tokens),
        "total_prompts":      commas(total_prompts),
        "total_cost_usd":     usd(cost_total),
        "override_count":     str(payload.get("pricingOverrideCount", 0)),
        "default_models_count": str(payload.get("cost", {}).get("defaultModels", 0)),
        "date_range_start":   start_iso.split("T")[0],
        "date_range_end":     end_iso.split("T")[0],
        "date_range_days":    str(days_between(start_iso, end_iso)),
        "event_count":        commas(payload["dataWindow"]["eventCount"]),
        "heaviest_day_date":  heaviest.get("label", "—"),
        "heaviest_day_tokens": compact_tokens(heaviest.get("totalTokens", 0)),
        "heaviest_day_prompts": commas(heaviest.get("promptCount", 0)),
        "streak_longest":     str(streak_long),
        "streak_current":     str(streak_cur),
        "distinct_projects":  str(len(payload.get("projects", []))),
        "distinct_models":    str(len(payload.get("models", []))),
        "distinct_agents":    str(len(payload.get("agents", []))),
        "first_prompt_date":  first_date,
        "last_prompt_date":   last_date,
        "daily_bars_svg":     svg_daily_bars(daily),
        "hour_clock_svg":     svg_hour_clock(hourly),
        "models_table":       models_table_html(payload.get("models", []), total_tokens=total_tokens or 1),
        "projects_list":      projects_list_html(
            payload.get("projects", []), payload["dataWindow"]["latest"]
        ),
    }


# Per-persona placeholder→builder dispatch table.
PERSONA_BUILDERS: Dict[str, Dict[str, Tuple[str, Any]]] = {
    "jojo": {
        "stand_stats":         ("stand_stats",          jojo_stand_stats_html),
        "psyche_breakdown":    ("psyche_breakdown",     jojo_psyche_html),
        "stand_card":          ("stand_card",           jojo_stand_card_html),
    },
    "bleach": {
        "reiatsu_stats":       ("reiatsu_stats",        lambda d: jojo_stand_stats_html(d) if d else ""),  # reuse radar
        "psyche_breakdown":    ("psyche_breakdown",     bleach_psyche_html),
        "zanpakuto_card":      ("zanpakuto_card",       bleach_zanpakuto_card_html),
    },
    "hxh": {
        "nen_assessment":      ("nen_assessment",       hxh_nen_assessment_html),
        "ability_design":      ("ability_design",       hxh_ability_design_html),
        "nen_progression":     ("nen_progression",      hxh_nen_progression_html),
    },
}


def _build_signature_visual(persona_key: str, python_derived: Dict[str, Any], persona_payload: Dict[str, Any]) -> str:
    """All 3 personas need the persona_payload because the visual depends on
    the chosen asset (Stand / Zanpakuto / Nen type)."""
    if persona_key == "jojo":
        return signature_visual_jojo(persona_payload)
    if persona_key == "bleach":
        return signature_visual_bleach(persona_payload)
    if persona_key == "hxh":
        return signature_visual_hxh(persona_payload)
    return ""


def render_persona(
    template: str,
    derived: Dict[str, Any],
    persona_payload: Dict[str, Any],
    persona_key: str,
    persona_label: str,
    personality_tag: str,
    python_derived: Dict[str, Any],
) -> Tuple[str, List[str]]:
    values = dict(derived)
    values["persona_key"] = persona_key
    values["persona_label"] = persona_label
    values["personality_tag"] = personality_tag
    values["signature_visual"] = _build_signature_visual(persona_key, python_derived, persona_payload)

    data_block = persona_payload.get("data", {}) or {}
    builders = PERSONA_BUILDERS.get(persona_key, {})
    for placeholder, (data_key, builder) in builders.items():
        values[placeholder] = builder(data_block.get(data_key))

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

    shared = narratives.get("_shared", {})
    personality_tag = shared.get("personality_tag", "—")
    python_derived = shared.get("python_derived", {}) or {}

    summary_lines = []
    for idx, (key, label) in enumerate(PERSONAS, start=1):
        template_path = themes_dir / f"{key}.html"
        if not template_path.exists():
            print(f"render.py: missing template {template_path}", file=sys.stderr)
            continue
        template = template_path.read_text(encoding="utf-8")
        narrative = narratives.get(key, {})
        html_out, missing = render_persona(
            template, derived, narrative, key, label, personality_tag, python_derived
        )
        out_file = out_dir / f"{idx:02d}-{key}.html"
        out_file.write_text(html_out, encoding="utf-8")
        summary_lines.append(f"  {key:<10s} → {out_file}  ({len(missing)} placeholders unmatched)")

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
