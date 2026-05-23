<!--
TokenBar PR — keep it tight. The product bar is "does it still feel like a glance, not a tab?".
See AGENTS.md for the shell-first workflow and UI verification expectations.
-->

## Summary / 概要

<!-- 1-3 bullets, product-level. What changes for the user? -->

-
-

## Why / 为什么

<!-- The motivation. If this is a bug fix, link the issue. If it's a feature, what acceptance criterion does it land? -->

## Verification / 验证

<!-- Required for UI-facing or aggregation changes. -->

- [ ] `script/test.sh` passes locally
- [ ] `script/build_and_run.sh --verify` passes locally (UI changes only)
- [ ] Screenshot or screen recording attached (UI changes only)
- [ ] No new network code added to the data path (privacy invariant)
- [ ] If a new data source or parser was added: real fixture(s) added under `Tests/TokenBarCoreTests/Fixtures/`

## Notes for the reviewer / 给 reviewer 的备注

<!-- Anything tricky, any risk you want a second pair of eyes on. -->
