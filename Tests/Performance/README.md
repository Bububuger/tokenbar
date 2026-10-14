# TokenBar performance acceptance

> Single source of truth for the four PERF acceptance items
> (CL-P2-014 ~ CL-P2-018). Each line below is a hard gate measured against
> the current `main` build.

## CL-P2-014 · 30-day stacked bar chart 60 fps
- **Harness:** Instruments → Animation → CADisplayLink + GPU drivers.
- **Recipe:** launch with sample data, open Overview, hold a window-resize
  for 5 s while the chart redraws.
- **Pass:** dropped frames < 1 % of the 5 s window.

## CL-P2-015 · Prompt list 60 fps with 10 000 rows
- **Harness:** Instruments → Time Profiler.
- **Recipe:** point Settings at a Claude prompt directory with ≥ 10 000
  rows, open Project Detail, fling-scroll for 4 s.
- **Pass:** main-thread time per frame < 16 ms (P95), zero hitches > 32 ms.

## CL-P2-016 · 100 k events aggregate < 200 ms
- **Harness:** `script/test.sh --filter Sprint10PerfTests`
  (`aggregator100kEventsCompletesWithinBudget_CL_P2_016`).
- **Pass:** the automated debug smoke-test threshold is 1.0 s. CI first runs
  Core + CLI functional tests with `--skip Sprint10PerfTests`, then runs this
  suite alone with `--skip-build --filter Sprint10PerfTests`. Both invocations must
  pass; isolation avoids measuring contention from unrelated parallel suites.
  Elapsed time uses a monotonic clock. Running `script/test.sh` without arguments
  uses the same split locally; explicit SwiftPM arguments are passed through.
- **Release acceptance:** 200 ms, measured separately under
  `swift test -c release --filter Sprint10PerfTests`; the debug smoke-test
  assertion does not itself enforce or demonstrate the release target.

## CL-P2-017 · Steady-state RSS ≤ 120 MB
- **Harness:** Instruments → Allocations + Leaks.
- **Recipe:** launch with sample data, idle for 1 hour with the Popover
  closed.
- **Pass:** RSS at t = 1h ≤ 120 MB and the curve has no monotonic upward
  trend over the second half-hour.

## CL-P2-018 · Steady-state CPU < 1 % (peak < 5 %)
- **Harness:** Activity Monitor → `top -pid <tokenbar>` sampled every 5 s.
- **Recipe:** as above, but actively generate fresh jsonl rows at 1 / s.
- **Pass:** 5-minute trailing average CPU < 1 %; peak < 5 %.

## OSSignpost subsystem

See `Sources/TokenBar/App/Performance.swift` for the
`com.tokenbar.app · performance` subsystem and the `bootstrap-*` /
`refresh-*` events used by Instruments Points of Interest.
