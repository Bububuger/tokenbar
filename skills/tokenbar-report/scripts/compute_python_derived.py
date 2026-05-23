#!/usr/bin/env python3
"""compute_python_derived.py — compute deterministic per-persona analyses.

v6 personas (3): jojo / bleach / hxh. All three share the same underlying
6-axis math but expose it under their universe's vocabulary, plus each has
its own iconic-asset picker (Stand / Zanpakuto / Nen ability).
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


def _streaks(daily: List[dict]) -> Tuple[int, int]:
    if not daily:
        return 0, 0
    dated = sorted(
        (_parse_date(b["label"]), b.get("totalTokens", 0))
        for b in daily if "label" in b
    )
    longest = current = 0
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
        prev = d
    return longest, current


def _total_tokens(daily: List[dict]) -> int:
    return sum(b.get("totalTokens", 0) for b in daily)


def _compact(n: float) -> str:
    n = float(n)
    for thresh, suffix in [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]:
        if abs(n) >= thresh:
            return f"{n / thresh:.2f}{suffix}".rstrip("0").rstrip(".")
    return f"{int(n)}"


def _excerpt(text: str, n: int = 200) -> str:
    s = " ".join(text.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _project_age_days(payload: dict) -> int:
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


def _grade(value: float, thresholds: List[float], reverse: bool = False) -> Tuple[str, float]:
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


# ─────────────────────────────────────────────────────────────────────────────
# Shared 6-axis computation (used by jojo / bleach / hxh)

_DESTRUCTION_VERBS = ["重写", "删除", "重构", "重新", "炸了", "废了", "rewrite", "refactor"]
_JOJO_VERBS = [
    "重写", "重新", "再来", "重来", "重置", "重构", "重做",
    "删除", "去掉", "干掉", "炸了", "废了",
    "为什么", "为啥", "怎么", "能不能",
    "立刻", "马上", "现在", "快点",
    "不对", "错了", "改一下", "调整",
    "看看", "试试", "对比",
    "fix", "refactor", "rewrite", "explain", "why", "again", "wrong",
]
_SHORT_PROMPT_CHARS = 200
_LONG_PROMPT_CHARS = 5000


def _compute_six_axes(payload: dict) -> Dict[str, Dict[str, Any]]:
    """Compute the 6 universal axes used by all 3 personas. Returns:
      { axis_key: { grade, score, primary, secondary, raw } }
    Axes keys: destructive_power / speed / range / durability / precision / growth_potential
    """
    daily = payload["timeline"]["byDay"]
    hourly = payload["timeline"]["byHour"]
    prompts = payload.get("prompts", [])

    daily_tokens_vals = [b.get("totalTokens", 0) for b in daily]
    sorted_daily = sorted(daily_tokens_vals)
    median_daily = _quantile(sorted_daily, 0.5) if sorted_daily else 1
    max_daily = sorted_daily[-1] if sorted_daily else 0

    # 破坏力
    destruction_count = 0
    for p in prompts:
        content = (p.get("content") or "").lower()
        for v in _DESTRUCTION_VERBS:
            if v.lower() in content:
                destruction_count += 1
                break
    destruction_ratio = destruction_count / max(len(prompts), 1)
    top_p50_ratio = (max_daily / median_daily) if median_daily > 0 else 1.0
    destr_score = min(top_p50_ratio / 5.0, 1.0) * 0.7 + destruction_ratio * 0.3
    destr_grade, destr_norm = _grade(destr_score, [0.7, 0.5, 0.35, 0.2])

    # 速度
    hour_total = sum(b.get("totalTokens", 0) for b in hourly) or 1
    peak_hour_share = max((b.get("totalTokens", 0) / hour_total for b in hourly), default=0)
    max_prompts_day = max((b.get("promptCount", 0) for b in daily), default=0)
    speed_score = min(peak_hour_share * 2.5, 1.0) * 0.6 + min(max_prompts_day / 100.0, 1.0) * 0.4
    speed_grade, speed_norm = _grade(speed_score, [0.7, 0.5, 0.35, 0.2])

    # 射程
    nproj = len(payload.get("projects", []))
    nmodel = len(payload.get("models", []))
    nagent = len(payload.get("agents", []))
    range_score = min(nproj / 30.0, 1.0) * 0.5 + min(nmodel / 12.0, 1.0) * 0.3 + min(nagent / 3.0, 1.0) * 0.2
    range_grade, range_norm = _grade(range_score, [0.75, 0.55, 0.35, 0.2])

    # 持久力
    longest_streak, _ = _streaks(daily)
    oldest_active = _project_age_days(payload)
    dur_score = min(longest_streak / 80.0, 1.0) * 0.5 + min(oldest_active / 540.0, 1.0) * 0.5
    dur_grade, dur_norm = _grade(dur_score, [0.7, 0.5, 0.35, 0.2])

    # 精密性
    content_lens = [p.get("contentLength", 0) for p in prompts]
    short_pct = (sum(1 for c in content_lens if 0 < c < _SHORT_PROMPT_CHARS) / max(len(content_lens), 1)) * 100
    long_pct = (sum(1 for c in content_lens if c > _LONG_PROMPT_CHARS) / max(len(content_lens), 1)) * 100
    prec_score = (short_pct / 100.0) * 0.7 + (max(0, 30 - long_pct) / 30.0) * 0.3
    prec_grade, prec_norm = _grade(prec_score, [0.65, 0.45, 0.30, 0.15])

    # 成长性
    dated = sorted(
        ((_parse_date(b["label"]), b.get("totalTokens", 0)) for b in daily if "label" in b),
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

    composite_norm = (destr_norm + speed_norm + range_norm + dur_norm + prec_norm + growth_norm) / 6.0
    composite_grade, _ = _grade(composite_norm, [4.2, 3.4, 2.6, 1.8])

    return {
        "composite_grade": composite_grade,
        "composite_norm":  round(composite_norm, 3),
        "destructive_power": {
            "grade": destr_grade, "score": round(destr_norm, 2),
            "raw_top_p50": top_p50_ratio, "raw_destruction_ratio": destruction_ratio,
            "raw_max_daily": max_daily, "raw_median_daily": median_daily,
        },
        "speed": {
            "grade": speed_grade, "score": round(speed_norm, 2),
            "raw_peak_hour_share": peak_hour_share, "raw_max_prompts_day": max_prompts_day,
        },
        "range": {
            "grade": range_grade, "score": round(range_norm, 2),
            "raw_nproj": nproj, "raw_nmodel": nmodel, "raw_nagent": nagent,
        },
        "durability": {
            "grade": dur_grade, "score": round(dur_norm, 2),
            "raw_longest_streak": longest_streak, "raw_oldest_active": oldest_active,
        },
        "precision": {
            "grade": prec_grade, "score": round(prec_norm, 2),
            "raw_short_pct": short_pct, "raw_long_pct": long_pct,
        },
        "growth_potential": {
            "grade": growth_grade, "score": round(growth_norm, 2),
            "raw_growth_ratio": growth_ratio,
        },
    }


# ─────────────────────────────────────────────────────────────────────────────
# Stand whitelist + picker (jojo)

_STAND_WHITELIST = [
    ("ger",      "黄金体验·安魂曲", "ゴールド・エクスペリエンス・レクイエム",
     "乔鲁诺·乔巴拿", "究极进化型 · 主权回归",
     ["any-A-composite"], "Requiem"),
    ("mih",      "天堂制造",         "メイド・イン・ヘブン",
     "プッチ神父", "时间加速型 · 演化奇点",
     ["growth_potential", "durability", "speed"], "Requiem"),
    ("spw",      "白金之星·世界",    "スタープラチナ・ザ・ワールド",
     "空条承太郎", "时间停止型 · 近距精密",
     ["destructive_power", "speed", "precision"], "Requiem"),
    ("tw",       "世界",             "ザ・ワールド",
     "DIO", "时间停止型 · 单体高破坏",
     ["destructive_power", "speed", "precision"], "S+"),
    ("sp",       "白金之星",         "スタープラチナ",
     "空条承太郎", "近距精密型 · 直拳之神",
     ["destructive_power", "speed", "precision"], "S+"),
    ("kc",       "绯红之王",         "キング・クリムゾン",
     "Diavolo", "时间删除型 · 战术预知",
     ["precision", "speed"], "S+"),
    ("cd",       "疯狂钻石",         "クレイジー・ダイヤモンド",
     "东方仗助", "治愈修复型 · 物体复原",
     ["destructive_power", "durability"], "S"),
    ("ge",       "黄金体验",         "ゴールド・エクスペリエンス",
     "乔鲁诺·乔巴拿", "赋予生命型 · 多线生长",
     ["growth_potential", "range"], "S"),
    ("kq",       "杀手皇后",         "キラークイーン",
     "吉良吉影", "隐匿自动型 · 第三炸弹",
     ["precision", "speed"], "S"),
    ("tusk",     "獠牙·第四幕",      "タスク・アクト4",
     "ジョニィ・ジョースター", "无限旋转型 · 直线穿透",
     ["durability", "growth_potential"], "S"),
    ("d4c",     "肮脏作乱·爱之列车", "D4C・ラブトレイン",
     "法尼·瓦伦泰", "灾难转移型 · 平行宇宙",
     ["range", "destructive_power"], "S"),
    ("sf",       "黏液栗子",         "スティッキィ・フィンガーズ",
     "ブチャラティ", "拉链构造型 · 多模块拼装",
     ["range", "durability"], "A"),
    ("echoes3",  "回音·ACT3",        "エコーズ・アクト3",
     "广濑康一", "多形态进化型 · 全能型",
     ["range"], "A"),
    ("sc",       "银色战车",         "シルバー・チャリオッツ",
     "ポルナレフ", "速攻剑士型 · 短打疾风",
     ["speed", "precision"], "A"),
    ("hp",       "隐者之紫",         "ハーミット・パープル",
     "乔瑟夫·乔斯达", "探测查询型 · 远距感知",
     ["range"], "A"),
    ("ws",       "白蛇",             "ホワイト・スネイク",
     "プッチ神父（初期）", "DISC 收集型 · 知识猎手",
     ["range"], "A"),
]


def _pick_stand(composite: str, axis_grades: Dict[str, str]) -> Dict[str, Any]:
    """Pick the stand from the tier-appropriate pool with the **highest match count**
    on the user's top axes (A/B grades). Tie-breaks by tier rank (Requiem > S+ > S > A)."""
    top_axes = set(k for k, g in axis_grades.items() if g in ("A", "B"))
    tier_rank = {"Requiem": 4, "S+": 3, "S": 2, "A": 1}

    def match_count(entry):
        if "any-A-composite" in entry[5]:
            return 99 if composite == "A" else 0
        return sum(1 for a in entry[5] if a in top_axes)

    pool = _STAND_WHITELIST
    if composite == "A":
        ranked = [e for e in pool if e[6] in ("Requiem", "S+")]
    elif composite == "B":
        ranked = [e for e in pool if e[6] in ("S+", "S")]
    elif composite == "C":
        ranked = [e for e in pool if e[6] in ("S", "A")]
    else:
        ranked = [e for e in pool if e[6] in ("A",)]
    if not ranked:
        ranked = pool

    # Sort by (match_count desc, tier_rank desc) — best match wins, then highest tier
    chosen = max(ranked, key=lambda e: (match_count(e), tier_rank.get(e[6], 0)))
    return {
        "id":      chosen[0],
        "name_cn": chosen[1],
        "name_jp": chosen[2],
        "master":  chosen[3],
        "type":    chosen[4],
        "tier":    chosen[6],
    }


# ─────────────────────────────────────────────────────────────────────────────
# Zanpakuto whitelist + picker (bleach)

# (id, name_jp, name_cn, master, division, shikai_call, bankai_call, best_axes, tier)
_ZANPAKUTO_WHITELIST = [
    ("tensa_zangetsu", "天鎖斬月", "天锁斩月",
     "黒崎一護", "代行死神（隊長級）",
     "斬月、刻ㄠ", "卍解！天鎖斬月！",
     ["destructive_power", "speed"], "S+"),
    ("senbonzakura", "千本桜景厳", "千本樱景严",
     "朽木白哉", "第六番隊 隊長",
     "散れ、千本桜", "卍解！千本桜景厳！",
     ["precision", "destructive_power", "speed"], "S+"),
    ("ryujin_jakka", "流刃若火", "流刃若火",
     "山本元柳斎重國", "第一番隊 總隊長",
     "万象一切灰燼と為せ、流刃若火", "卍解！残火の太刀！",
     ["destructive_power", "durability"], "S+"),
    ("kyoka_suigetsu", "鏡花水月", "镜花水月",
     "藍染惣右介", "元第五番隊 隊長",
     "砕けろ、鏡花水月", "—（虚化奥义）",
     ["precision", "growth_potential"], "S+"),
    ("kanonji_no_tsuru", "片羽の御使い", "片翼天使",
     "浦原喜助", "元第十二番隊 隊長",
     "起きろ、紅姫", "卍解！完全燼劫",
     ["growth_potential", "range"], "S+"),
    ("hyourinmaru", "氷輪丸", "冰轮丸",
     "日番谷冬獅郎", "第十番隊 隊長",
     "霜天に坐せ、氷輪丸", "卍解！大紅蓮氷輪丸！",
     ["precision", "speed"], "S"),
    ("katenkyoukotsu", "花天狂骨枯松心中", "花天狂骨枯松心中",
     "京楽春水", "第八番隊 隊長",
     "花は風に、風は心に、花天狂骨", "卍解！花天狂骨枯松心中！",
     ["growth_potential", "range"], "S"),
    ("kokujou_tengen", "黒縄天譴明王", "黑绳天谴明王",
     "狛村左陣", "第七番隊 隊長",
     "轟け、天譴", "卍解！黒縄天譴明王！",
     ["range", "durability"], "S"),
    ("zabimaru", "双骨", "双骨",
     "阿散井恋次", "第六番隊 副隊長",
     "咆えろ、蛇尾丸", "卍解！双骨大蛇！",
     ["destructive_power", "range"], "A"),
    ("sodenoshirayuki", "袖白雪", "袖白雪",
     "朽木ルキア", "第十三番隊 副隊長",
     "舞え、袖白雪", "卍解！白霞罸！",
     ["precision", "speed"], "A"),
    ("sougyo_kotowari", "双魚理", "双鱼理",
     "浮竹十四郎", "第十三番隊 隊長",
     "ぶつかれ、双魚理", "—",
     ["precision", "growth_potential"], "A"),
    ("haineko", "灰猫", "灰猫",
     "松本乱菊", "第十番隊 副隊長",
     "唸れ、灰猫", "—",
     ["range", "speed"], "A"),
]


def _pick_zanpakuto(composite: str, axis_grades: Dict[str, str]) -> Dict[str, Any]:
    """Pick the zanpakuto with highest match count on user's top (A/B) axes."""
    top_axes = set(k for k, g in axis_grades.items() if g in ("A", "B"))
    tier_rank = {"S+": 3, "S": 2, "A": 1}

    def match_count(entry):
        return sum(1 for a in entry[7] if a in top_axes)

    pool = _ZANPAKUTO_WHITELIST
    if composite == "A":
        ranked = [e for e in pool if e[8] in ("S+",)]
    elif composite == "B":
        ranked = [e for e in pool if e[8] in ("S+", "S")]
    elif composite == "C":
        ranked = [e for e in pool if e[8] in ("S", "A")]
    else:
        ranked = [e for e in pool if e[8] in ("A",)]
    if not ranked:
        ranked = pool

    chosen = max(ranked, key=lambda e: (match_count(e), tier_rank.get(e[8], 0)))
    return {
        "id":           chosen[0],
        "name_jp":      chosen[1],
        "name_cn":      chosen[2],
        "master":       chosen[3],
        "division":     chosen[4],
        "shikai_call":  chosen[5],
        "bankai_call":  chosen[6],
        "tier":         chosen[8],
    }


# ─────────────────────────────────────────────────────────────────────────────
# Nen affinity computation (hxh)

def _compute_nen_affinity(axes: Dict[str, Any]) -> Dict[str, Any]:
    """Map the 6 axes to 6 nen types' affinity (0-100). Each user has one
    dominant 系 (highest) and one or two adjacent 系 (next-highest)."""
    def score(axis_key: str) -> float:
        # 0..5 normalized to 0..100
        return axes[axis_key]["score"] * 20

    enhancement   = (score("durability") + score("destructive_power")) / 2
    manipulation  = score("growth_potential")
    conjuration   = score("precision")
    emission      = score("range")
    transmutation = score("speed")
    # 特質系: gets a boost if composite is A and any axis is also A
    composite_grade = axes["composite_grade"]
    n_a_axes = sum(1 for k in ("destructive_power", "speed", "range", "durability", "precision", "growth_potential")
                   if axes[k]["grade"] == "A")
    specialization = min(100.0, n_a_axes * 18 + (20 if composite_grade in ("A", "B") else 0))

    nen_scores = {
        "強化系":    {"label": "ENHANCEMENT",    "affinity": round(enhancement, 1)},
        "操作系":    {"label": "MANIPULATION",   "affinity": round(manipulation, 1)},
        "具現化系":  {"label": "CONJURATION",    "affinity": round(conjuration, 1)},
        "放出系":    {"label": "EMISSION",       "affinity": round(emission, 1)},
        "変化系":    {"label": "TRANSMUTATION",  "affinity": round(transmutation, 1)},
        "特質系":    {"label": "SPECIALIZATION", "affinity": round(specialization, 1)},
    }
    # Sort by affinity desc
    ranked = sorted(nen_scores.items(), key=lambda kv: kv[1]["affinity"], reverse=True)
    primary = ranked[0]
    secondary = ranked[1]
    return {
        "primary_type":      primary[0],
        "primary_label":     primary[1]["label"],
        "primary_affinity":  primary[1]["affinity"],
        "secondary_type":    secondary[0],
        "secondary_label":   secondary[1]["label"],
        "secondary_affinity": secondary[1]["affinity"],
        "neighbors": [
            {"type": k, "label": v["label"], "affinity": v["affinity"]}
            for k, v in nen_scores.items()
        ],
    }


# ─────────────────────────────────────────────────────────────────────────────
# Verb / pattern intel (for jojo's psyche_breakdown and shared)

def _near_duplicate_clusters(prompts: List[dict], min_count: int = 3) -> List[dict]:
    buckets: Dict[str, List[dict]] = collections.defaultdict(list)
    for p in prompts:
        content = (p.get("content") or "").strip()
        if not content:
            continue
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


# ─────────────────────────────────────────────────────────────────────────────
# jojo

def derive_jojo(payload: dict, axes: Dict[str, Any]) -> dict:
    daily = payload["timeline"]["byDay"]
    hourly = payload["timeline"]["byHour"]
    prompts = payload.get("prompts", [])
    total_tokens = _total_tokens(daily) or 1

    composite_grade = axes["composite_grade"]
    grade_dict = {k: axes[k]["grade"] for k in ("destructive_power","speed","range","durability","precision","growth_potential")}
    stand_suggestion = _pick_stand(composite_grade, grade_dict)

    short_pct = axes["precision"]["raw_short_pct"]
    long_pct = axes["precision"]["raw_long_pct"]
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

    return {
        "stand_stats": {
            "composite_rank": composite_grade,
            "axes": [
                {
                    "axis":        "destructive_power",
                    "label_cn":    "破坏力",
                    "label_en":    "DESTRUCTIVE POWER",
                    "grade":       axes["destructive_power"]["grade"],
                    "score":       axes["destructive_power"]["score"],
                    "primary":     f"单日峰值 / 中位 = {axes['destructive_power']['raw_top_p50']:.1f}×",
                    "secondary":   f"破坏类动词 prompt 占 {axes['destructive_power']['raw_destruction_ratio']*100:.0f}%",
                    "top_day_tokens":    axes["destructive_power"]["raw_max_daily"],
                    "median_day_tokens": axes["destructive_power"]["raw_median_daily"],
                },
                {
                    "axis":      "speed",
                    "label_cn":  "速度",
                    "label_en":  "SPEED",
                    "grade":     axes["speed"]["grade"],
                    "score":     axes["speed"]["score"],
                    "primary":   f"峰值小时占全日 {axes['speed']['raw_peak_hour_share']*100:.0f}%",
                    "secondary": f"单日 prompt 峰值 {axes['speed']['raw_max_prompts_day']}",
                },
                {
                    "axis":      "range",
                    "label_cn":  "射程",
                    "label_en":  "RANGE",
                    "grade":     axes["range"]["grade"],
                    "score":     axes["range"]["score"],
                    "primary":   f"{axes['range']['raw_nproj']} 项目 · {axes['range']['raw_nmodel']} 模型 · {axes['range']['raw_nagent']} agents",
                },
                {
                    "axis":      "durability",
                    "label_cn":  "持久力",
                    "label_en":  "DURABILITY",
                    "grade":     axes["durability"]["grade"],
                    "score":     axes["durability"]["score"],
                    "primary":   f"最长 streak {axes['durability']['raw_longest_streak']} 天",
                    "secondary": f"最老仍活项目跨度 {axes['durability']['raw_oldest_active']} 天",
                },
                {
                    "axis":      "precision",
                    "label_cn":  "精密性",
                    "label_en":  "PRECISION",
                    "grade":     axes["precision"]["grade"],
                    "score":     axes["precision"]["score"],
                    "primary":   f"短 prompt (< {_SHORT_PROMPT_CHARS} 字) 占 {short_pct:.0f}%",
                    "secondary": f"超长 prompt (> {_LONG_PROMPT_CHARS} 字) 占 {long_pct:.1f}%",
                },
                {
                    "axis":      "growth_potential",
                    "label_cn":  "成长性",
                    "label_en":  "GROWTH POTENTIAL",
                    "grade":     axes["growth_potential"]["grade"],
                    "score":     axes["growth_potential"]["score"],
                    "primary":   f"近期 / 早期 token 比 = {axes['growth_potential']['raw_growth_ratio']:.2f}×",
                },
            ],
        },
        "prompt_intel": {
            "sample_size":             len(prompts),
            "short_prompt_pct":        round(short_pct, 1),
            "long_prompt_pct":         round(long_pct, 1),
            "ultra_long_prompts":      ultra_long_dump,
            "near_duplicate_clusters": near_dups,
            "verb_frequency":          verb_freq,
            "first_prompts_each_day":  first_prompts_each_day,
            "last_prompts_each_day":   last_prompts_each_day,
            "session_stats":           sessions,
        },
        "behavioral_extremes": {
            "first_active_hour":    first_active,
            "last_active_hour":     last_active,
            "weekday_consistency":  round(weekday_cv, 3),
            "weekend_intensity":    round(weekend_intensity, 3),
        },
        "stand_suggestion": stand_suggestion,
    }


# ─────────────────────────────────────────────────────────────────────────────
# bleach

def derive_bleach(payload: dict, axes: Dict[str, Any]) -> dict:
    composite_grade = axes["composite_grade"]
    grade_dict = {k: axes[k]["grade"] for k in ("destructive_power","speed","range","durability","precision","growth_potential")}
    zanpakuto = _pick_zanpakuto(composite_grade, grade_dict)

    # Relabel axes for 死神 vocabulary
    BLEACH_AXIS_LABELS = {
        "destructive_power": ("斩击", "ZANGEKI"),
        "speed":             ("瞬步", "SHUNPO"),
        "range":             ("灵压圈", "REIATSU RANGE"),
        "durability":        ("体力", "TAIRYOKU"),
        "precision":         ("鬼道", "KIDO"),
        "growth_potential":  ("卍解适性", "BANKAI APTITUDE"),
    }
    bleach_axes = []
    for axis_key, (cn, en) in BLEACH_AXIS_LABELS.items():
        a = axes[axis_key]
        primary_text = ""
        if axis_key == "destructive_power":
            primary_text = f"单日斩击峰值 / 中位 = {a['raw_top_p50']:.1f}×"
        elif axis_key == "speed":
            primary_text = f"峰值小时占全日 {a['raw_peak_hour_share']*100:.0f}% · 单日斩击峰值 {a['raw_max_prompts_day']}"
        elif axis_key == "range":
            primary_text = f"{a['raw_nproj']} 番队所辖 · {a['raw_nmodel']} 刀型 · {a['raw_nagent']} 副官"
        elif axis_key == "durability":
            primary_text = f"最长出勤 {a['raw_longest_streak']} 日 · 最老警戒线跨度 {a['raw_oldest_active']} 日"
        elif axis_key == "precision":
            primary_text = f"短斩击占 {a['raw_short_pct']:.0f}%"
        elif axis_key == "growth_potential":
            primary_text = f"近期 / 早期 灵压比 = {a['raw_growth_ratio']:.2f}×"
        bleach_axes.append({
            "axis":     axis_key,
            "label_cn": cn,
            "label_en": en,
            "grade":    a["grade"],
            "score":    a["score"],
            "primary":  primary_text,
        })

    return {
        "reiatsu_stats": {
            "composite_rank": composite_grade,
            "axes":           bleach_axes,
        },
        "zanpakuto_suggestion": zanpakuto,
        "raw_metrics": {
            "total_reiatsu":     _total_tokens(payload["timeline"]["byDay"]),
            "longest_patrol":    axes["durability"]["raw_longest_streak"],
            "nproj":             axes["range"]["raw_nproj"],
            "nmodel":            axes["range"]["raw_nmodel"],
            "nagent":            axes["range"]["raw_nagent"],
        },
    }


# ─────────────────────────────────────────────────────────────────────────────
# hxh

def derive_hxh(payload: dict, axes: Dict[str, Any]) -> dict:
    composite_grade = axes["composite_grade"]
    nen_assessment = _compute_nen_affinity(axes)
    nproj  = axes["range"]["raw_nproj"]
    nmodel = axes["range"]["raw_nmodel"]
    nagent = axes["range"]["raw_nagent"]
    streak = axes["durability"]["raw_longest_streak"]
    short_pct = axes["precision"]["raw_short_pct"]

    # Pre-suggest 3 named abilities based on top-2 nen types and user characteristics.
    # The subagent can override but these are flattering defaults.
    abilities_suggestion = []

    # Ability 1: based on multi-line characteristic (high range)
    if axes["range"]["grade"] in ("A", "B"):
        abilities_suggestion.append({
            "ability_name_jp": "百器同期コネクト",
            "ability_name_cn": "百器同步连接",
            "ability_type":    f"{nen_assessment['primary_type']}・{nen_assessment['secondary_type']}複合",
            "constraint":      f"発動中、同時に把握できるプロセスは {nmodel} 件まで（モデル数準拠）",
            "vow":             "破った場合、24 時間 念使用不可",
            "effect":          f"{nproj} 件のプロジェクト・オーラを同時に維持し、各々の進行を 0.6 秒で切り替える。",
        })

    # Ability 2: based on short prompt characteristic (high precision)
    if axes["precision"]["grade"] in ("A", "B"):
        abilities_suggestion.append({
            "ability_name_jp": "短打フラッシュ",
            "ability_name_cn": "短打瞬闪",
            "ability_type":    "強化系・変化系複合",
            "constraint":      f"発動時、prompt 文字数 {_SHORT_PROMPT_CHARS} 文字以下に限定（短打 {short_pct:.0f}% 主流）",
            "vow":             "違反すると次の prompt が無効化される",
            "effect":          "短文発動による超高速念。中位の 4 倍以上の出力効率を発揮する。",
        })

    # Ability 3: based on durability (long streaks)
    if axes["durability"]["grade"] in ("A", "B", "C"):
        abilities_suggestion.append({
            "ability_name_jp": "オープンレジスタ",
            "ability_name_cn": "永続レジスタ",
            "ability_type":    f"{nen_assessment['primary_type']}系",
            "constraint":      f"最大 {streak} 日継続 オーラ 出力を維持（実績ベース）",
            "vow":             "途中で念を中断した場合、再開まで 24 時間",
            "effect":          "長期念出力。念能力者協会で「持続型」として認定されている。",
        })

    # Always have 1-3 abilities; if user is C/D, fall back to a generic one
    if not abilities_suggestion:
        abilities_suggestion.append({
            "ability_name_jp": "イニシャル念",
            "ability_name_cn": "初阶念",
            "ability_type":    nen_assessment["primary_type"],
            "constraint":      "発動には集中状態が必要",
            "vow":             "—",
            "effect":          "基础念能力。修业を続けるべし。",
        })

    return {
        "nen_assessment":   nen_assessment,
        "abilities_suggestion": abilities_suggestion[:3],
        "raw_metrics": {
            "composite_grade": composite_grade,
            "total_aura":      _total_tokens(payload["timeline"]["byDay"]),
            "n_invocations":   sum(b.get("promptCount", 0) for b in payload["timeline"]["byDay"]),
            "n_systems":       nmodel,
        },
    }


def main() -> int:
    payload = json.load(sys.stdin)
    axes = _compute_six_axes(payload)
    out = {
        "jojo":   derive_jojo(payload, axes),
        "bleach": derive_bleach(payload, axes),
        "hxh":    derive_hxh(payload, axes),
        "_shared_axes": axes,  # for debugging / reference
    }
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
