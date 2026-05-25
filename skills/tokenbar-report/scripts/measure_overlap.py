#!/usr/bin/env python3
"""measure_overlap.py — measure cross-persona content overlap on a rendered
report folder.

Reads the persona HTML files (01-*.html, 02-*.html, ...) in the report
directory, strips <style>/<script>/HTML tags + numbers/symbols, tokenizes
into character 3-grams (CJK-friendly), and computes pairwise Jaccard
similarity across every pair. Prints the matrix + max overlap, and exits
non-zero if max ≥ threshold.

This is the lens-isolation gating metric (introduced in v5, kept in v6):
max pairwise overlap must be < 0.30 for the report to be considered
"lens-isolated". v6 has 3 personas (jojo / bleach / hxh) → 3 pairs.

CLI:
    measure_overlap.py <report_dir> [--threshold 0.30] [--json]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Dict, List, Tuple


# Stripping helpers
_STYLE_RE = re.compile(r"<style\b[^>]*>.*?</style>", re.DOTALL | re.IGNORECASE)
_SCRIPT_RE = re.compile(r"<script\b[^>]*>.*?</script>", re.DOTALL | re.IGNORECASE)
_TAG_RE = re.compile(r"<[^>]+>")
_ENTITY_RE = re.compile(r"&[a-zA-Z#0-9]+;")
_NUMBER_RE = re.compile(r"[\d.,%$+\-/×x]+")
_WHITESPACE_RE = re.compile(r"\s+")

# Boilerplate that appears verbatim in every theme template (the page chrome,
# total counters etc.) — exclude these phrases so they don't inflate the
# overlap signal artificially. The whole point of measuring overlap is to
# catch *narrative* convergence; chrome convergence is by design.
_BOILERPLATE_PHRASES = [
    "INDEX", "总目", "总卷目录", "Back to deck", "总卷", "卷",
    "tokenbar-report", "TokenBar Report",
    "pricing override(s)", "default-rate models",
    "default-rate model(s)",
    "override(s)", "default",
    "events", "天", "events ·",
    "front", "back", "deck", "lens",
]


def strip_html(s: str) -> str:
    s = _STYLE_RE.sub(" ", s)
    s = _SCRIPT_RE.sub(" ", s)
    s = _TAG_RE.sub(" ", s)
    s = _ENTITY_RE.sub(" ", s)
    s = _NUMBER_RE.sub(" ", s)
    for phrase in _BOILERPLATE_PHRASES:
        s = s.replace(phrase, " ")
    s = _WHITESPACE_RE.sub(" ", s)
    return s.strip()


def char_ngrams(text: str, n: int = 3) -> set:
    """Character n-grams. CJK-friendly: each Chinese character is one position,
    so 3-grams capture phrase-level identity well."""
    text = "".join(ch for ch in text if not ch.isspace())
    if len(text) < n:
        return set()
    return {text[i:i + n] for i in range(len(text) - n + 1)}


def jaccard(a: set, b: set) -> float:
    if not a and not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def find_persona_files(report_dir: pathlib.Path) -> List[Tuple[str, pathlib.Path]]:
    """Return [(persona_key, path)] for the persona HTML files in canonical order.

    Matches `<NN>-<key>.html` (NN any 2-digit prefix). v6 ships 3 files
    (01-jojo / 02-bleach / 03-hxh); the loose glob keeps the script
    forward-compatible if the lineup ever changes.
    """
    candidates = sorted(report_dir.glob("[0-9][0-9]-*.html"))
    out = []
    for p in candidates:
        stem = p.stem  # e.g. "01-jojo"
        if "-" in stem:
            key = stem.split("-", 1)[1]
            out.append((key, p))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("report_dir", type=pathlib.Path)
    ap.add_argument("--threshold", type=float, default=0.30,
                    help="Max acceptable pairwise Jaccard (default 0.30)")
    ap.add_argument("--ngram", type=int, default=3,
                    help="Character n-gram size (default 3)")
    ap.add_argument("--json", action="store_true", help="Emit JSON matrix")
    args = ap.parse_args()

    files = find_persona_files(args.report_dir)
    if len(files) < 2:
        print(f"measure_overlap: need at least 2 persona files, found {len(files)} in {args.report_dir}",
              file=sys.stderr)
        return 2

    grams: Dict[str, set] = {}
    for key, path in files:
        raw = path.read_text(encoding="utf-8")
        text = strip_html(raw)
        grams[key] = char_ngrams(text, n=args.ngram)

    keys = [k for k, _ in files]
    pairwise: Dict[str, Dict[str, float]] = {k: {} for k in keys}
    max_pair = ("", "", 0.0)
    for i, k1 in enumerate(keys):
        for j, k2 in enumerate(keys):
            if i == j:
                pairwise[k1][k2] = 1.0
                continue
            score = jaccard(grams[k1], grams[k2])
            pairwise[k1][k2] = round(score, 4)
            if i < j and score > max_pair[2]:
                max_pair = (k1, k2, score)

    result = {
        "report_dir":   str(args.report_dir),
        "threshold":    args.threshold,
        "ngram":        args.ngram,
        "personas":     keys,
        "matrix":       pairwise,
        "max_pair":     {"a": max_pair[0], "b": max_pair[1], "overlap": round(max_pair[2], 4)},
        "pass":         max_pair[2] < args.threshold,
    }

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"Overlap matrix (Jaccard on {args.ngram}-grams, chrome stripped):")
        header = "         " + "".join(f"{k:>10s}" for k in keys)
        print(header)
        for k1 in keys:
            row = f"{k1:>9s}" + "".join(
                f"{pairwise[k1][k2]:>10.3f}" for k2 in keys
            )
            print(row)
        print()
        print(f"Max pairwise overlap: {max_pair[0]} ↔ {max_pair[1]} = {max_pair[2]:.4f}")
        print(f"Threshold: {args.threshold}")
        print(f"Result: {'PASS' if result['pass'] else 'FAIL'}")

    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
