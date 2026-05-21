# Codex Collaboration Workflow

## Default Development Split

For non-trivial product or code implementation work, use this division of labor:

- GPT-5.5 owns product discussion, technical planning, scope control, and final acceptance.
- GPT-5.3-Codex-Spark (`gpt-5.3-codex-spark`, referred to as `codex-spark`) owns concrete code execution when implementation work is needed.

Do not delegate every small task. For one-line fixes, quick inspections, simple command output, or low-risk text edits, handle the work directly.

Prefer delegating token-heavy but lower-reasoning execution work to `codex-spark`, such as repeated build/test runs, log collection, screenshot attempts, UI automation probes, and broad mechanical verification. GPT-5.5 should define the concrete target and acceptance criteria first, then judge the result.

## Workflow

1. Discuss the product or engineering intent with the user first.
2. Convert the agreed direction into explicit acceptance criteria before implementation.
3. Delegate bounded code changes to a `codex-spark` worker when the task is implementation-heavy.
4. Tell the worker the exact files or modules it owns, that it is not alone in the codebase, and that it must not revert unrelated edits.
5. Require the worker to edit files directly, run relevant build/test commands, and report changed paths plus verification results.
6. GPT-5.5 reviews the worker result, checks diffs and screenshots/logs where relevant, and performs final acceptance.
7. If the worker result misses the product intent, GPT-5.5 either sends a precise follow-up to the worker or applies a small integration fix directly.

## macOS App Workflow

Use a shell-first workflow for TokenBar. Xcode is the required toolchain for this native macOS app, but the Xcode GUI should not be the default development driver.

- Build and test from scripts or `xcodebuild`, not the Xcode Run button.
- Regenerate the project with `xcodegen generate --spec project.yml --project .` before Xcode-target builds when project settings may have changed.
- Use `script/test.sh` for the standard test path.
- Use `script/build_and_run.sh --verify` for the standard local app build/run verification path.
- Keep development signing scriptable, but treat App Store archive, notarization, and final signing as a separate release phase requiring explicit human acceptance.
- Prefer SwiftUI scenes and views first: `MenuBarExtra`, `Window`, `WindowGroup`, `Settings`, `NavigationSplitView`, toolbars, keyboard shortcuts, and system materials.
- Use narrow AppKit bridges when SwiftUI cannot reliably express macOS behavior, especially status item control, window activation, focus, hover timing, file panels, drag and drop, and diagnostics.
- Do not accept generated Swift/macOS APIs without building. AI-produced macOS code must pass a real build before it is treated as usable.
- Keep SDK and DerivedData cache issues isolated in scripts. If Xcode SDK changes, avoid stale SwiftSyntax or package prebuilt artifacts by using SDK-specific build cache paths.

## UI And macOS App Work

For UI-facing work, especially macOS status bar, popover, or window changes:

- Define the visible user-facing behavior before code changes.
- State the visible acceptance criteria before delegating implementation.
- Use mocked data when the user explicitly allows it or when visual validation would otherwise be blocked.
- Explain which data is mocked, which data is real, and the time window behind every visible number.
- Verify with a real build/run path, not just static code inspection.
- Capture screenshots for visual acceptance when possible.
- For status bar work, validate against menu-bar space constraints. Prefer a compact icon or chart indicator over adding numeric text to the menu-bar item.
- For popover and window work, validate singleton behavior. Repeated clicks on Details or Diagnostics should focus an existing window instead of creating duplicates.
- For time-windowed metrics, avoid mixing Today, 30d, and Total numbers without labels. The UI must make the time window explicit.

## Logging And Diagnostics

- Use Swift `Logger` for runtime diagnostics that may matter during local verification.
- Prefer `log stream` or script-collected logs over ad hoc print debugging when investigating app runtime behavior.
- Privacy, accessibility, file access, and automation permissions should be represented explicitly in `Info.plist`, entitlements, or diagnostics UI when they affect user-facing behavior.

## Final Reporting

Final responses should be concise and include:

- What changed at the product level.
- The key files changed.
- The verification performed.
- Any remaining caveat or follow-up decision.
