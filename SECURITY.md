# Security Policy / 安全策略

## TokenBar's threat model in one paragraph / 一句话讲清威胁模型

TokenBar reads local AI coding-tool logs, indexes usage and captured prompt text into `~/Library/Application Support/TokenBar/tokenbar.sqlite`, and renders them in a macOS app and CLI. There is no analytics upload or TokenBar cloud-sync service. Local log indexing does not require a network connection, but the app does have network features:

- **Cursor Dashboard sync:** off by default; explicit setup stores a Cursor credential in macOS Keychain and sends authenticated requests to Cursor's private Dashboard API. Results are account-wide, not confined to this Mac. Disabling sync stops requests and retains the local snapshot; forgetting the credential removes the Keychain item.
- **Updates:** the version check contacts GitHub / raw GitHub content and can be disabled; installing an update downloads its release asset.
- **Community plugins:** opening the gallery fetches a registry; installation downloads the selected manifest and attachments. JSONL / SQLite plugins read configured local data. Executable plugins launch external processes with the user's permissions, not in an isolated sandbox. Only install code you trust.

Library can read local skills and MCP configuration and, through explicit UI actions, move skills to Trash or change MCP configuration. The current app target is not App Sandbox-enabled. The most sensitive local content includes captured prompts, source paths, and configuration; review exports and generated reports before sharing them.

> 中文：本地日志与 prompt 默认索引到本机，不做分析上传或 TokenBar 云同步。App 并非完全离线：GitHub 更新、社区插件目录/下载，以及默认关闭的 Cursor 账号同步会联网。Cursor 凭证保存在钥匙串；可执行插件拥有当前用户的进程权限，并无隔离沙箱。Library 还可在显式操作后修改 MCP 配置或将 skill 移至废纸篓；分享导出或报告前请检查敏感内容。

## What we consider a vulnerability / 我们认作漏洞的情况

- A code path that **transmits any indexed data off the user's machine** without explicit, informed user action. This includes unintended disclosure through sync, plugins, diagnostics, or exported reports — please file high-priority.
- A path traversal, symlink, or glob expansion in **Custom Sources** that lets a malicious source spec read files outside the configured directory.
- Unintended credential disclosure, or Cursor requests continuing after sync is disabled.
- Plugin installation escaping its intended directory, or untrusted plugin content causing execution outside the intended executable-plugin workflow.
- A parser (JSONL / JSON / SQLite / compressed JSONL) that can be crashed or made to consume unbounded memory by a malformed file written by a third-party CLI.
- Captured prompt text rendered into the UI without sanitization in a way that allows code execution (e.g., via a webview / `NSAttributedString` HTML).
- Pricing override input that escapes its numeric parse and corrupts the local DB.
- Any way for a non-admin user on the same machine to read another user's TokenBar index (e.g., via world-readable file modes on `~/Library/Application Support/TokenBar/`).

## What's out of scope / 不算漏洞

- An AI tool you use writes a prompt to disk that TokenBar then indexes locally. **TokenBar is not the upstream data source** — fix the upstream tool's logging, hide prompt text in `Settings → General → Prompt Text`, or wipe TokenBar's copied prompt rows from Diagnostics.
- Sharing a file you deliberately exported or a report you generated. `Settings → Sources & Data → Data & Retention → Export JSON…` exports summary totals, row counts, and custom-source configuration, not a full database backup. CLI row exports and reports may expose prompt text; review them before sharing.
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
- Whether the issue involves local prompt text, export/report generation, Cursor sync, plugin installation/execution, or Library configuration edits
- A minimal reproduction (a JSONL file, a Custom Source path glob, a Pricing override string, etc.) — **redact actual prompt text, cookies, credentials, private paths, and MCP secrets**
- Your assessment of severity, if you have one

## Response expectations / 响应预期

This is a small project with no SLA. Realistic expectations:

- **Acknowledge**: 7 days
- **Triage / first fix or workaround**: 30 days for high-severity reports that match the central invariant; best-effort for everything else
- **Disclosure**: coordinated — we'll agree on a date once a fix is ready

## Hall of fame / 致谢墙

Researchers who file valid reports will be credited here (with permission) once a fix ships.

<!-- - 2026-MM-DD — @handle — CVE-YYYY-NNNN — short description -->
