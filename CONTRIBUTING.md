# Contributing to TokenBar / 参与 TokenBar

Thanks for considering a contribution. TokenBar is intentionally small — the bar for accepting changes is **"does it still feel like a glance, not a tab?"**. This file is the short version; the full collaboration workflow lives in [`AGENTS.md`](AGENTS.md).

> 中文摘要：TokenBar 刻意保持「轻量」，所有改动的衡量标准都是**「它还像不像一眼可看的菜单栏工具，而不是又一个标签页？」**。完整的协作工作流在 [`AGENTS.md`](AGENTS.md)，本文是精简版。

## Before you start / 动手之前

1. **Open an issue first** for anything bigger than a typo or a one-line fix.
   *小到改 typo / 一行修 bug 直接发 PR；大到加功能 / 加数据源，请先开 issue。*
2. **Read [`AGENTS.md`](AGENTS.md)** — especially the *项目与架构* and *UI 验收* sections if you're touching SwiftUI.
3. **Pick the right shape**:
   - New data source? — try the **Custom Sources** flow in `Settings → Sources & Data → Custom Sources` first. If that's not enough, add an engine under [`Sources/TokenBarCore/Services/`](Sources/TokenBarCore/Services/) and a parser under [`Sources/TokenBarCore/Parsers/`](Sources/TokenBarCore/Parsers/).
   - New CLI command? — register it in [`Sources/TokenBarCLI/CommandRegistry.swift`](Sources/TokenBarCLI/CommandRegistry.swift) and the `dispatch()` switch in [`Sources/TokenBarCLI/Entry.swift`](Sources/TokenBarCLI/Entry.swift).
   - New `tokenbar-report` persona? — drop a `references/personas/<key>.md` and a matching theme HTML; the dispatch is in [`skills/tokenbar-report/SKILL.md`](skills/tokenbar-report/SKILL.md).

## Local setup / 本地搭建

```bash
git clone https://github.com/Bububuger/tokenbar.git
cd tokenbar
xcodegen generate --spec project.yml --project .   # regenerate Xcode project from project.yml
script/test.sh                                   # SwiftPM Core + CLI tests, no app signing
script/build_and_run.sh --verify                 # build + launch + check the process is running
```

Requirements: **macOS 14+**, an **Xcode toolchain with Swift 6 support**, and **xcodegen** (`brew install xcodegen`). `Package.swift` requires Swift tools 6.0; check the selected toolchain with `swift --version` and `xcodebuild -version`. CI currently runs on `macos-26`.

The app build scripts use Apple Development signing and automatic provisioning. Configure a signed-in Xcode account and set `TOKENBAR_DEVELOPMENT_TEAM` to your own team ID; the scripts otherwise use the repository's default team. `script/test.sh` does not require app signing.

`--verify` checks that TokenBar has a running process. Open the popover and affected windows yourself to verify rendering and interactions. If launch is blocked, the script tries an existing Xcode-managed debug bundle; if none exists, follow its instruction to run the TokenBar scheme once in Xcode and retry.

## How we work / 怎么写代码

**Shell-first, not Xcode-button-first.**

- Use `script/build.sh` for an app build, `script/test.sh` for the SwiftPM Core and CLI tests, and `script/build_and_run.sh` to build and launch the app. The build scripts regenerate the Xcode project automatically.
- `script/test.sh --xcode` runs the `TokenBarTests` Xcode scheme, which includes the Core tests only. It does not replace the default SwiftPM run's CLI test coverage.
- CI runs the default tests and checks that XcodeGen regeneration leaves `TokenBar.xcodeproj` unchanged. Documentation-only pushes/PRs are skipped by its path filters; CI does not perform UI acceptance or release packaging.
- Regenerate `TokenBar.xcodeproj` with `xcodegen generate --spec project.yml --project .` whenever `project.yml` changes.
- AI-produced macOS code **must build** before it's treated as usable.

**SwiftUI first, AppKit only where SwiftUI can't reach.**

- Prefer `MenuBarExtra`, `Window`, `Settings`, `NavigationSplitView`, system materials, keyboard shortcuts.
- Drop into AppKit bridges only for: status item control, window activation/focus, hover timing, file panels, drag & drop, diagnostics.

**For UI changes, define the visible behavior *before* writing the code change.** A screenshot in the PR is worth more than a paragraph in the description.

## What we look for in a PR / PR 验收标准

- [ ] **`script/test.sh` is green.**
- [ ] **`script/build_and_run.sh --verify` passes for UI-facing changes, and the affected UI has been checked manually.**
- [ ] **No undisclosed uploads.** Keep local logs and indexed prompts on-device unless the user explicitly chooses to share them. Describe any new network destination, transmitted data, and consent flow in the PR. Follow the existing Cursor sync, plugin download/execution, and update boundaries documented in [`SECURITY.md`](SECURITY.md).
- [ ] **No silent number changes.** If your PR changes how a token / cost is computed, link the corresponding test fixture (under `Tests/TokenBarCoreTests/Fixtures/`) and explain the delta in plain words.
- [ ] **Time-windowed metrics are labeled.** Never mix Today / 30d / Total numbers without explicit labels.
- [ ] **Screenshot or screen recording** for UI changes.

## Coding style / 代码风格

- Swift 6, strict concurrency.
- Use Swift `Logger` for runtime diagnostics; avoid ad-hoc `print`.
- Don't add comments that explain *what* the code does — the code's identifiers do that. Only comment when the *why* is non-obvious (a workaround, an invariant, a constraint).
- Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code; only validate at system boundaries (user input, file parsing, external APIs).

## Filing a bug / 上报 Bug

Use the bug-report template at <https://github.com/Bububuger/tokenbar/issues/new/choose>. The template asks which source is affected; if it is missing from the dropdown, name it in the description. Include enough detail to investigate the "TokenBar shows a number, my AI tool shows a different number" class of report.

## Security / 安全问题

Please **do not** open public issues for security problems. See [`SECURITY.md`](SECURITY.md).

## License of contributions / 贡献的许可

TokenBar is licensed under the **[Apache License 2.0](LICENSE)**. By submitting a contribution, you agree it will be licensed under the same terms — this is the standard inbound=outbound rule that Apache 2.0's §5 already implies (no separate CLA required).

> 中文：TokenBar 采用 **[Apache License 2.0](LICENSE)**。提交 PR 即表示你的贡献也按 Apache 2.0 授权 —— 即 Apache 2.0 §5 默认的 inbound = outbound 原则，**不需要单独签 CLA**。
