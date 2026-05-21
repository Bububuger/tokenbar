# Performance baselines

> CL-XS-009. Drop `xcrun xctrace record` output here per release tag.

## Capture

```bash
xcrun xctrace record \
  --template 'Points of Interest' \
  --output Tests/Performance/baselines/v0.1.0.trace \
  --launch .build/debug/TokenBar
```

## Naming

`v<MAJOR>.<MINOR>.<PATCH>.trace` aligned with the `Info.plist`
`CFBundleShortVersionString`. CI rejects PRs whose Popover open P95 grows
more than 5 % vs the previous tag's baseline.

## CL-XS-007 signposts

The trace captures `bootstrap-start`/`bootstrap-end` and
`refresh-start`/`refresh-end` signposts (see `Sources/TokenBar/App/Performance.swift`).
