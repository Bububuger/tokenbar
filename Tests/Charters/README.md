# TokenBar exploratory charters

> Living charters for QA-led exploration. Each charter targets a single
> hypothesis with a fixed time-box. Findings go into Linear with the
> charter ID as the issue prefix.

## CL-P2-019 · EXP-001 multi-agent write storm
- **Time-box:** 30–60 min
- **Setup:** launch with `TOKENBAR_USE_SAMPLE_DATA=0`; run Codex,
  Claude Code, and Hermes session generators in parallel, each emitting one
  event per second for an hour.
- **Hypothesis:** the FSEvents debounce holds total CPU < 5 % and the indexed
  event count diverges from raw line count by < 0.1 %.
- **Capture:** Activity Monitor CPU sample every 5 min; final
  `tokenbarctl export json` diffed against the raw jsonl tail.

## CL-P2-020 · EXP-004 visual alignment audit
- **Time-box:** 60 min
- **Setup:** open each screen against the 9 design canvas screenshots in
  `docs/design-prd/tokenbar/uploads/`.
- **Hypothesis:** every spacing/alignment delta is documented or filed.
- **Capture:** mind map of issues; one CL-P0/CL-P1/CL-P2 issue per finding.

## CL-P2-021 · EXP-005 keyboard-only operation
- **Time-box:** 30 min
- **Setup:** trackpad disabled.
- **Hypothesis:** "open today → drill into a project → change retention
  window → close" is achievable using only `Tab`, `Return`, arrow keys, and
  `Esc`.
- **Capture:** any control without a logical Tab stop or focus ring.

## CL-P2-022 · EXP-007 cross-device visual parity
- **Time-box:** 45 min
- **Setup:** identical sample data on a 13″ MacBook Air, 16″ MacBook Pro
  (Retina), and a 27″ Studio Display (1× scale).
- **Hypothesis:** Popover and Overview render without truncation, with
  matching baseline alignment, on all three devices.
- **Capture:** screenshots from all three, grouped under
  `Tests/Charters/exp-007/<device>/`.
