# Snapshot baselines

> CL-XS-010. Reference screenshots for visual regression. Six screens × two
> appearances = 12 PNG baselines.

## Capture matrix

| Screen | Light | Dark |
| --- | --- | --- |
| Menubar Popover | `popover-light.png` | `popover-dark.png` |
| Overview | `overview-light.png` | `overview-dark.png` |
| Project Detail | `project-light.png` | `project-dark.png` |
| Settings | `settings-light.png` | `settings-dark.png` |
| Diagnostics | `diagnostics-light.png` | `diagnostics-dark.png` |
| Add Custom Source | `addsource-light.png` | `addsource-dark.png` |

## Generation

Launch with deterministic sample data and route override (see
`docs/development/testing.md` for the env-var contract):

```bash
TOKENBAR_USE_SAMPLE_DATA=1 \
  TOKENBAR_OPEN_WINDOW_ON_LAUNCH=main \
  swift run TokenBar
```

Use macOS `screencapture` against the foreground window. CI diffs the
captured PNG against the baseline using `imagemagick compare` and fails the
PR when the per-pixel delta exceeds the per-screen threshold listed in
`Tests/Snapshots/thresholds.json` (to be added).
