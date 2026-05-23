# Contributing to TokenBar / 参与 TokenBar

Thanks for considering a contribution. TokenBar is intentionally small — the bar for accepting changes is **"does it still feel like a glance, not a tab?"**. This file is the short version; the full collaboration workflow lives in [`AGENTS.md`](AGENTS.md).

> 中文摘要：TokenBar 刻意保持「轻量」，所有改动的衡量标准都是**「它还像不像一眼可看的菜单栏工具，而不是又一个标签页？」**。完整的协作工作流在 [`AGENTS.md`](AGENTS.md)，本文是精简版。

## Before you start / 动手之前

1. **Open an issue first** for anything bigger than a typo or a one-line fix.
   *小到改 typo / 一行修 bug 直接发 PR；大到加功能 / 加数据源，请先开 issue。*
2. **Read [`AGENTS.md`](AGENTS.md)** — especially the *UI And macOS App Work* section if you're touching SwiftUI.
3. **Pick the right shape**:
   - New data source? — try the **Custom Sources** flow in `Settings → Custom Sources` first. If that's not enough, add an engine under [`Sources/TokenBarCore/Services/`](Sources/TokenBarCore/Services/) and a parser under [`Sources/TokenBarCore/Parsers/`](Sources/TokenBarCore/Parsers/).
   - New CLI command? — register it in [`Sources/TokenBarCLI/CommandRegistry.swift`](Sources/TokenBarCLI/CommandRegistry.swift) and the `dispatch()` switch in [`Sources/TokenBarCLI/Entry.swift`](Sources/TokenBarCLI/Entry.swift).
   - New `tokenbar-report` persona? — drop a `references/personas/<key>.md` and a matching theme HTML; the dispatch is in [`skills/tokenbar-report/SKILL.md`](skills/tokenbar-report/SKILL.md).

## Local setup / 本地搭建

```bash
git clone https://github.com/Bububuger/tokenbar.git
cd tokenbar
xcodegen generate --spec project.yml --project .   # regenerate Xcode project from project.yml
script/test.sh                                     # swift-testing — fast, no signing
script/build_and_run.sh --verify                   # build + launch + assert the popover renders
```

Requirements: **macOS 14+**, **Xcode 15+** toolchain, **xcodegen** (`brew install xcodegen`).

## How we work / 怎么写代码

**Shell-first, not Xcode-button-first.**

- Build & test via `script/build.sh` and `script/test.sh` — *not* the Xcode Run button.
- Regenerate `TokenBar.xcodeproj` with `xcodegen generate --spec project.yml --project .` whenever `project.yml` changes.
- AI-produced macOS code **must build** before it's treated as usable.

**SwiftUI first, AppKit only where SwiftUI can't reach.**

- Prefer `MenuBarExtra`, `Window`, `Settings`, `NavigationSplitView`, system materials, keyboard shortcuts.
- Drop into AppKit bridges only for: status item control, window activation/focus, hover timing, file panels, drag & drop, diagnostics.

**For UI changes, define the visible behavior *before* writing the code change.** A screenshot in the PR is worth more than a paragraph in the description.

## What we look for in a PR / PR 验收标准

- [ ] **`script/test.sh` is green.**
- [ ] **`script/build_and_run.sh --verify` is green for UI-facing changes.**
- [ ] **No new network code** in the data path. The "0 upload" invariant is load-bearing — if you genuinely need a network call (e.g., to refresh model pricing from an upstream catalog), call it out in the PR description and we'll discuss.
- [ ] **No silent number changes.** If your PR changes how a token / cost is computed, link the corresponding test fixture (under `Tests/TokenBarCoreTests/Fixtures/`) and explain the delta in plain words.
- [ ] **Time-windowed metrics are labeled.** Never mix Today / 30d / Total numbers without explicit labels.
- [ ] **Screenshot or screen recording** for UI changes.

## Coding style / 代码风格

- Swift 6, strict concurrency.
- Use Swift `Logger` for runtime diagnostics; avoid ad-hoc `print`.
- Don't add comments that explain *what* the code does — the code's identifiers do that. Only comment when the *why* is non-obvious (a workaround, an invariant, a constraint).
- Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code; only validate at system boundaries (user input, file parsing, external APIs).

## Filing a bug / 上报 Bug

Use the bug-report template at <https://github.com/Bububuger/tokenbar/issues/new/choose>. The template asks which of the 6 sources is affected and pre-empts the "TokenBar shows a number, my AI tool shows a different number" class of report.

## Security / 安全问题

Please **do not** open public issues for security problems. See [`SECURITY.md`](SECURITY.md).

## License of contributions / 贡献的许可

TokenBar is licensed under the **[Apache License 2.0](LICENSE)**. By submitting a contribution, you agree it will be licensed under the same terms — this is the standard inbound=outbound rule that Apache 2.0's §5 already implies (no separate CLA required).

> 中文：TokenBar 采用 **[Apache License 2.0](LICENSE)**。提交 PR 即表示你的贡献也按 Apache 2.0 授权 —— 即 Apache 2.0 §5 默认的 inbound = outbound 原则，**不需要单独签 CLA**。
