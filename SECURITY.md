# Security Policy / 安全策略

## TokenBar's threat model in one paragraph / 一句话讲清威胁模型

TokenBar reads files that AI coding tools (Claude Code, Codex, Gemini CLI, Hermes, OpenClaw, OpenCode, and any **Custom Source** you configure) write **locally** on your machine, indexes them into a local SQLite database, and renders aggregates in a macOS menu-bar app. **There is no network code in the data path.** No analytics SDK, no cloud sync, no account system. The most sensitive data on disk is **captured prompt text**, stored locally by default so project history, `tbar prompts`, and `tokenbar-report` can work.

> 中文：TokenBar 读你本机上 AI 编码工具已经写下的日志（Claude Code / Codex / Gemini CLI / Hermes / OpenClaw / OpenCode 以及你自配的 Custom Source），落到本地 SQLite，画到菜单栏 App 上 —— **数据通路里没有任何网络代码**。最敏感的本地数据是 prompt 原文；它默认本地入库，用于项目历史、`tbar prompts` 和 `tokenbar-report`，不会被自动上传。

## What we consider a vulnerability / 我们认作漏洞的情况

- A code path that **transmits any indexed data off the user's machine** without explicit user action (export). This is the central invariant — please file high-priority.
- A path traversal, symlink, or glob expansion in **Custom Sources** that lets a malicious source spec read files outside the configured directory.
- A parser (JSONL / SQLite) that can be crashed or made to consume unbounded memory by a malformed file written by a third-party CLI.
- Captured prompt text rendered into the UI without sanitization in a way that allows code execution (e.g., via a webview / `NSAttributedString` HTML).
- Pricing override input that escapes its numeric parse and corrupts the local DB.
- Any way for a non-admin user on the same machine to read another user's TokenBar index (e.g., via world-readable file modes on `~/Library/Application Support/com.javis.TokenBar/`).

## What's out of scope / 不算漏洞

- An AI tool you use writes a prompt to disk that TokenBar then indexes locally. **TokenBar is not the upstream data source** — fix the upstream tool's logging, hide prompt text in `Settings → Prompt Text`, or wipe TokenBar's copied prompt rows from Diagnostics.
- Exporting the local DB via `Settings → Data & Retention → Export` and then losing the resulting file. Export is an explicit user action; the file is yours after it leaves the app.
- Pricing inaccuracy. Per-million-token rates can be overridden in `Settings → Pricing`; if a built-in default is stale, file a regular issue, not a security report.
- Bugs that require the attacker to already have **shell access as your user** on macOS. At that point the OS is the security boundary, not TokenBar.

## Reporting / 如何上报

**Please do not file public GitHub issues for security problems.** Use one of:

1. **GitHub Security Advisories** — open a private report at  
   <https://github.com/Bububuger/tokenbar/security/advisories/new>
2. **Email** — `lshsh201@gmail.com` with `[TokenBar Security]` in the subject. PGP not required.

When reporting, please include:

- TokenBar version (`Resources/Info.plist → CFBundleShortVersionString`)
- macOS version + chip (Apple silicon / Intel)
- Whether the issue involves local prompt text rendering, export, or report generation
- A minimal reproduction (a JSONL file, a Custom Source path glob, a Pricing override string, etc.) — **redact any actual prompt text**
- Your assessment of severity, if you have one

## Response expectations / 响应预期

This is a small project with no SLA. Realistic expectations:

- **Acknowledge**: 7 days
- **Triage / first fix or workaround**: 30 days for high-severity reports that match the central invariant; best-effort for everything else
- **Disclosure**: coordinated — we'll agree on a date once a fix is ready

## Hall of fame / 致谢墙

Researchers who file valid reports will be credited here (with permission) once a fix ships.

<!-- - 2026-MM-DD — @handle — CVE-YYYY-NNNN — short description -->
