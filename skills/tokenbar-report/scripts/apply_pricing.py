#!/usr/bin/env python3
"""apply_pricing.py — recompute per-model and total costs honoring the user's
`tokenbar.pricingOverrides` from the TokenBar app.

Pipe collect.sh output in, get the same JSON back out with two adjustments:

* Each row in `models` gains `costMethod` ("override" | "default-flat") and an
  `estimatedCostUSD` recomputed from the override's split input/output/cache
  rates when an override is present. Rows without an override keep tbar's
  flat-rate number unchanged.
* A top-level `cost` block: { totalUSD, overriddenModels, defaultModels }.

The override schema stored in @AppStorage is:

    { "<modelName>": { "input": <USD/M>, "output": <USD/M>, "cache": <USD/M> }, ... }

Models present in the data but absent from the override dict keep the default
flat rate. Models present in the override dict but absent from the data are
ignored.
"""
from __future__ import annotations

import json
import sys


def recompute_with_override(row: dict, rates: dict) -> float:
    inp = row.get("inputTokens", 0) / 1_000_000.0 * float(rates.get("input", 0))
    out = row.get("outputTokens", 0) / 1_000_000.0 * float(rates.get("output", 0))
    cache = row.get("cacheTokens", 0) / 1_000_000.0 * float(rates.get("cache", 0))
    return inp + out + cache


def main() -> int:
    payload = json.load(sys.stdin)
    overrides = payload.get("pricingOverrides") or {}

    overridden = 0
    default_models = 0
    total_usd = 0.0

    for row in payload.get("models", []):
        name = row.get("name")
        if name in overrides:
            row["estimatedCostUSD"] = recompute_with_override(row, overrides[name])
            row["costMethod"] = "override"
            overridden += 1
        else:
            row.setdefault("costMethod", "default-flat")
            default_models += 1
        total_usd += row.get("estimatedCostUSD", 0.0)

    payload["cost"] = {
        "totalUSD": total_usd,
        "overriddenModels": overridden,
        "defaultModels": default_models,
        "note": (
            "Default-flat: tbar's per-agent flat rate × totalTokens. "
            "Override: per-model input/output/cache split rates from the "
            "TokenBar Settings → Pricing override panel."
        ),
    }

    json.dump(payload, sys.stdout, indent=2, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
