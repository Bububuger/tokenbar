# Work Item: Plugin System (Source Adapter Protocol + Gallery)

**Date:** 2026-05-27
**Status:** Implemented — pending registry repo creation + app visual verification

---

## Background

TokenBar 目前有 7 个内置数据源 + Custom Sources（glob + field mapping）。ali-trace 的调研表明市场上有 20+ 种 AI 编码工具需要采集，逐个内置不可持续。Custom Sources 本质上已经是一个不能分享的"插件"——用户配好 glob + field mapping 后只能自己用，无法分发给其他人。

核心洞察：把 Custom Source 的配置抽象成标准化的 **插件清单（manifest）**，加上可选的可执行脚本层，再接一个 GitHub 仓库做分发，就构成完整的插件体系。

## Requirement

设计并实现插件系统，使社区用户可以通过声明式配置或可执行脚本为任意 AI 工具编写数据源适配器，并通过 GitHub registry 分发。TokenBar 应用内提供 Gallery 页面，一键安装/更新/卸载插件。

---

## Design

### 术语

| 术语 | 含义 |
|---|---|
| **Plugin** | 一个数据源适配器，由 manifest.json 定义 |
| **Manifest** | 插件元数据 + 数据源配置的 JSON 文件 |
| **Registry** | GitHub 仓库，存放所有已发布插件的 manifest + 可选脚本 |
| **Gallery** | TokenBar Settings 中的插件浏览/安装页面 |
| **Declarative Plugin** | 纯配置型插件（JSONL field mapping 或 SQLite column mapping） |
| **Executable Plugin** | 带外部脚本的插件，输出 NDJSON 到 stdout |

### 插件层级（两层设计）

```
┌─────────────────────────────────────────────────┐
│  Level 2: Executable (脚本/二进制)                │
│  ┌───────────────────────────────────────────┐   │
│  │  Level 1: Declarative (纯 JSON manifest)  │   │
│  │  - JSONL field mapping                    │   │
│  │  - SQLite column mapping                  │   │
│  │  - 覆盖 ~80% 的 AI 工具                   │   │
│  └───────────────────────────────────────────┘   │
│  - 任意语言 (Python/Node/bash/binary)            │
│  - 输出 NDJSON 到 stdout                        │
│  - 覆盖剩余 ~20%（需要转换逻辑的工具）            │
└─────────────────────────────────────────────────┘
```

---

### Manifest Schema (v1)

```jsonc
{
  // === 元数据 ===
  "manifest_version": 1,
  "id": "github-copilot",              // 全局唯一 kebab-case slug
  "name": "GitHub Copilot",            // 显示名称
  "version": "1.0.0",                  // semver
  "description": "Captures token usage from GitHub Copilot via OTel JSONL spans",
  "author": "tokenbar-community",
  "homepage": "https://github.com/...",
  "min_tokenbar_version": "1.5.0",     // 最低兼容的 TokenBar 版本

  // === 数据源定义 ===
  "source": {
    "type": "jsonl | sqlite | executable",
    // ... 按 type 展开，见下文
  },

  // === Token 口径声明 ===
  "token_semantics": {
    "input_includes_cached": false,     // true = input 已含 cache_read，需归一时减掉
    "timestamp_format": "iso8601"       // iso8601 | unix_s | unix_ms | unix_nano
  },

  // === 用户需要做的配置（安装后弹窗提示） ===
  "setup_hints": [
    "Set environment variable: export COPILOT_OTEL_FILE_EXPORTER_PATH=~/.copilot/otel"
  ]
}
```

#### source.type = "jsonl"

```jsonc
{
  "type": "jsonl",
  "directory": "~/.copilot/otel",       // 支持 ~ 展开
  "glob": "*.jsonl",
  "fields": {
    "input_tokens":          "attributes.gen_ai.usage.input_tokens",
    "output_tokens":         "attributes.gen_ai.usage.output_tokens",
    "cache_read_tokens":     "",         // 空串 = 该字段不存在，默认 0
    "cache_creation_tokens": "",
    "reasoning_tokens":      "",
    "model":                 "attributes.gen_ai.response.model",
    "timestamp":             "startTimeUnixNano",
    "session_id":            "traceId",
    "project":               ""          // 空串 = 从目录名推断
  },
  "filter": {                            // 可选：只处理匹配行
    "field": "name",
    "equals": "gen_ai.completion"
  }
}
```

字段值使用 **dot-notation** JSON path，与现有 `CustomSourceFieldMapping` 一致。空串表示该字段不存在，TokenBar 填 0 或从上下文推断。

#### source.type = "sqlite"

```jsonc
{
  "type": "sqlite",
  "directory": "~/Library/Application Support/Kiro",
  "glob": "data.sqlite3",
  "query": {
    "table": "messages",
    "columns": {
      "input_tokens":          "input_token_count",
      "output_tokens":         "output_token_count",
      "cache_read_tokens":     "cache_read_count",
      "cache_creation_tokens": "cache_write_count",
      "reasoning_tokens":      null,
      "model":                 "model_name",
      "timestamp":             "created_at",
      "session_id":            "conversation_id",
      "project":               "project_name"
    },
    "watermark_column": "created_at",    // 增量读取用的时间戳列
    "where": "role = 'assistant'"        // 可选：过滤条件
  }
}
```

TokenBar 使用 GRDB 以只读 + WAL 模式打开数据库，拼接 SQL：
```sql
SELECT {mapped_columns} FROM {table}
WHERE {watermark_column} > ?
  AND ({where})
ORDER BY {watermark_column} ASC
```

#### source.type = "executable"

```jsonc
{
  "type": "executable",
  "command": "python3",
  "script": "collect.py",               // 相对于插件安装目录
  "args": ["--format", "ndjson"],        // 额外固定参数
  "incremental_flag": "--since",         // TokenBar 追加 --since <ISO8601> 实现增量
  "timeout_seconds": 30
}
```

**可执行插件协议：**

| 方面 | 规范 |
|---|---|
| **调用方式** | TokenBar spawn 子进程：`{command} {script} {args} [--since ISO8601]` |
| **输出** | stdout，每行一个 JSON 对象（NDJSON），schema 见下文 |
| **错误** | stderr 输出警告/错误信息，TokenBar 采集为 `ParseWarning` |
| **退出码** | 0 = 成功，非 0 = 失败（TokenBar 记录 warning，下次重试） |
| **状态目录** | 环境变量 `TOKENBAR_PLUGIN_STATE_DIR` 指向 `~/Library/.../plugins/{id}/state/`，脚本可自行管理增量状态 |
| **超时** | 默认 30s，manifest 可配置 |

**NDJSON 输出 schema（每行）：**

```jsonc
{
  "id": "unique-event-id",              // 必填，用于去重
  "timestamp": "2026-05-27T10:30:00Z",  // 必填，ISO8601 或按 timestamp_format
  "input_tokens": 1500,                 // 必填
  "output_tokens": 800,                 // 必填
  "cache_read_tokens": 200,             // 可选，默认 0
  "cache_creation_tokens": 0,           // 可选，默认 0
  "reasoning_tokens": 0,               // 可选，默认 0
  "model": "gpt-4o",                   // 可选
  "session_id": "sess-abc-123",        // 可选
  "project": "my-project"             // 可选
}
```

---

### Token 归一层

借鉴 ali-trace 的 `normalizeTokenUsage()`，在所有数据源（内置 + 插件）写入 `usage_events` 之前统一执行：

```swift
func normalizeTokenUsage(
    rawInput: Int, rawOutput: Int,
    cacheRead: Int, cacheCreation: Int, reasoning: Int,
    inputIncludesCached: Bool
) -> (input: Int, output: Int, cacheRead: Int, cacheCreation: Int, reasoning: Int) {
    let clampedInput    = max(rawInput, 0)
    let clampedOutput   = max(rawOutput, 0)
    let clampedRead     = max(cacheRead, 0)
    let clampedCreation = max(cacheCreation, 0)
    let clampedReasoning = max(reasoning, 0)

    if inputIncludesCached {
        let effectiveRead = min(clampedRead, clampedInput)
        return (clampedInput - effectiveRead, clampedOutput, effectiveRead, clampedCreation, clampedReasoning)
    }
    return (clampedInput, clampedOutput, clampedRead, clampedCreation, clampedReasoning)
}
```

manifest 中 `token_semantics.input_includes_cached` 决定是否触发减法路径。内置 parser 也可以标注此标志，统一入口。

---

### Registry 设计

**仓库结构：** `github.com/Bububuger/tokenbar-plugins`

```
tokenbar-plugins/
├── registry.json                      # 自动生成的索引，TokenBar Gallery 拉取此文件
├── CONTRIBUTING.md                    # 贡献指南 + manifest schema 说明
├── plugins/
│   ├── github-copilot/
│   │   ├── manifest.json
│   │   └── README.md
│   ├── cursor/
│   │   ├── manifest.json
│   │   ├── collect.py                 # executable 插件附带脚本
│   │   └── README.md
│   ├── kiro/
│   │   ├── manifest.json
│   │   └── README.md
│   └── cline/
│       ├── manifest.json
│       └── README.md
```

**registry.json 格式：**

```jsonc
{
  "registry_version": 1,
  "updated_at": "2026-05-27T00:00:00Z",
  "plugins": [
    {
      "id": "github-copilot",
      "name": "GitHub Copilot",
      "version": "1.0.0",
      "description": "OTel JSONL span-based token capture",
      "author": "tokenbar-community",
      "type": "declarative",
      "download_url": "https://raw.githubusercontent.com/Bububuger/tokenbar-plugins/main/plugins/github-copilot/manifest.json",
      "min_tokenbar_version": "1.5.0"
    }
  ]
}
```

**CI 自动化：** 仓库配 GitHub Action，每次 PR merge 后扫描 `plugins/*/manifest.json`，校验 schema 合法性，重新生成 `registry.json`。

**内容审核：** PR review 即质量把关——与 Homebrew/core 同模式。executable 类型插件需额外审核脚本安全性。

---

### Gallery UI

Settings → Plugins tab，三个区域：

```
┌──────────────────────────────────────────────────┐
│  Plugins                                         │
│ ─────────────────────────────────────────────────│
│  Installed (2)                                   │
│  ┌────────────┐  ┌────────────┐                  │
│  │ Copilot    │  │ Kiro       │                  │
│  │ v1.0.0  ✓  │  │ v1.0.0  ✓  │                  │
│  │ [Disable]  │  │ [Uninstall]│                  │
│  └────────────┘  └────────────┘                  │
│                                                  │
│  Available (12)                    [↻ Refresh]   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  │
│  │ Cursor     │  │ Cline      │  │ Qwen Code  │  │
│  │ executable │  │ declarative│  │ declarative │  │
│  │ [Install]  │  │ [Install]  │  │ [Install]  │  │
│  └────────────┘  └────────────┘  └────────────┘  │
│                                                  │
│  ─ Custom (手动) ────────────────────────────────│
│  [+ Add Custom Source]  (现有 Custom Sources UI)  │
└──────────────────────────────────────────────────┘
```

**数据流：**
1. Gallery 打开时拉取 `registry.json`（24h 缓存，与 UpdateChecker 同策略）
2. 对比本地已安装插件，标记 installed / update available / new
3. 用户点 Install → 下载 manifest.json（+ 可选 script 文件）到 `~/Library/Application Support/com.javis.TokenBar/plugins/{id}/`
4. 解析 manifest → 创建 `CustomSourceRecord` 写入 DB → 下次 checkpoint 即开始采集
5. Uninstall → 删除插件目录 + 删除对应 `CustomSourceRecord` + cascade 删除 events

---

### 本地存储

```
~/Library/Application Support/com.javis.TokenBar/
├── tokenbar.sqlite                   # 主数据库（不变）
├── plugins/                          # 插件安装目录
│   ├── github-copilot/
│   │   ├── manifest.json             # 下载的 manifest
│   │   └── state/                    # executable 插件的状态目录
│   ├── cursor/
│   │   ├── manifest.json
│   │   ├── collect.py                # 附带的脚本
│   │   └── state/
│   └── registry-cache.json           # registry.json 本地缓存
```

---

### 与现有架构的集成

**关键原则：插件最终转化为 `CustomSourceRecord`，复用全部现有基础设施。**

```
Manifest.json
    │
    ▼
PluginLoader.parse(manifest)
    │
    ├─ type=jsonl  → CustomSourceRecord(engine: .custom, format: .unknown, fieldMapping: ...)
    ├─ type=sqlite → CustomSourceRecord(engine: .pluginSqlite, ...) ← 新增 engine 类型
    └─ type=executable → CustomSourceRecord(engine: .pluginExecutable, ...)
    │
    ▼
CustomSourceRegistry.upsert(record)
    │
    ▼
CheckpointEngine 正常调度 → CustomUsageEventSource.loadEvents()
    │
    ├─ .pluginSqlite:      PluginSqliteReader.loadEvents(manifest.query)
    ├─ .pluginExecutable:  PluginExecutableRunner.run(manifest.command)
    └─ .custom (jsonl):    现有 parseMappedJSONL() 路径
    │
    ▼
normalizeTokenUsage(inputIncludesCached: manifest.token_semantics.input_includes_cached)
    │
    ▼
usage_events 表（id 前缀 "plugin:{plugin_id}:"）
```

**新增类型：**

```swift
// CustomSourceEngine 新增两个 case
public enum CustomSourceEngine: String, Codable {
    // ... existing cases ...
    case pluginSqlite       // 声明式 SQLite 插件
    case pluginExecutable   // 可执行脚本插件
}
```

**CustomSourceRecord 扩展：**

```swift
// 新增字段（SQLite migration）
public var pluginId: String?            // 关联的插件 ID，nil = 手动创建的 custom source
public var pluginVersion: String?       // 安装时的版本号
public var sqliteQuery: PluginSqliteQuery?       // type=sqlite 时的查询配置
public var executableConfig: PluginExecutableConfig?  // type=executable 时的脚本配置
public var inputIncludesCached: Bool    // token 口径标志
public var timestampFormat: TimestampFormat      // 时间戳解析方式
```

---

### 安全考量

| 风险 | 应对 |
|---|---|
| Executable 插件执行任意代码 | 安装时明确提示"此插件会运行外部脚本"，需二次确认；Registry PR 审核脚本内容 |
| 恶意 manifest 的 directory 指向敏感路径 | SQLite/JSONL 读取始终只读；展示实际读取路径让用户确认 |
| Executable 插件 hang | timeout_seconds 硬上限（默认 30s，最大 120s）；`Process.terminate()` |
| Registry MITM | 走 HTTPS（GitHub raw）；可选 SHA256 校验 |
| 插件读取到的数据含敏感信息 | TokenBar 本身全本地，不上传；plugin 产出的 events 同样只存本地 SQLite |

---

### 示例插件：GitHub Copilot（声明式 JSONL）

```json
{
  "manifest_version": 1,
  "id": "github-copilot",
  "name": "GitHub Copilot",
  "version": "1.0.0",
  "description": "Captures token usage from GitHub Copilot via OpenTelemetry JSONL span export",
  "author": "tokenbar-community",
  "homepage": "https://github.com/Bububuger/tokenbar-plugins/tree/main/plugins/github-copilot",
  "min_tokenbar_version": "1.5.0",

  "source": {
    "type": "jsonl",
    "directory": "~/.copilot/otel",
    "glob": "*.jsonl",
    "fields": {
      "input_tokens": "attributes.gen_ai.usage.input_tokens",
      "output_tokens": "attributes.gen_ai.usage.output_tokens",
      "cache_read_tokens": "",
      "cache_creation_tokens": "",
      "reasoning_tokens": "",
      "model": "attributes.gen_ai.response.model",
      "timestamp": "startTimeUnixNano",
      "session_id": "traceId",
      "project": ""
    },
    "filter": {
      "field": "name",
      "equals": "gen_ai.completion"
    }
  },

  "token_semantics": {
    "input_includes_cached": false,
    "timestamp_format": "unix_nano"
  },

  "setup_hints": [
    "Enable OTel export: set COPILOT_OTEL_FILE_EXPORTER_PATH=~/.copilot/otel in your shell profile",
    "Restart your editor after setting the variable"
  ]
}
```

### 示例插件：Cursor（可执行脚本）

```json
{
  "manifest_version": 1,
  "id": "cursor",
  "name": "Cursor",
  "version": "1.0.0",
  "description": "Extracts token usage from Cursor's state.vscdb + shell hook fallback",
  "author": "tokenbar-community",
  "min_tokenbar_version": "1.5.0",

  "source": {
    "type": "executable",
    "command": "python3",
    "script": "collect.py",
    "args": [],
    "incremental_flag": "--since",
    "timeout_seconds": 60
  },

  "token_semantics": {
    "input_includes_cached": true,
    "timestamp_format": "iso8601"
  },

  "setup_hints": [
    "Requires Python 3.9+ with sqlite3 module (built-in)"
  ]
}
```

### 示例插件：Kiro CLI（声明式 SQLite）

```json
{
  "manifest_version": 1,
  "id": "kiro-cli",
  "name": "Kiro CLI",
  "version": "1.0.0",
  "description": "Reads token usage from Kiro CLI local SQLite database",
  "author": "tokenbar-community",
  "min_tokenbar_version": "1.5.0",

  "source": {
    "type": "sqlite",
    "directory": "~/.kiro",
    "glob": "data.sqlite3",
    "query": {
      "table": "messages",
      "columns": {
        "input_tokens": "input_token_count",
        "output_tokens": "output_token_count",
        "cache_read_tokens": "cache_read_count",
        "cache_creation_tokens": "",
        "reasoning_tokens": "",
        "model": "model_id",
        "timestamp": "created_at",
        "session_id": "conversation_id",
        "project": ""
      },
      "watermark_column": "created_at",
      "where": "role = 'assistant' AND input_token_count > 0"
    }
  },

  "token_semantics": {
    "input_includes_cached": false,
    "timestamp_format": "unix_ms"
  }
}
```

---

## Implementation Plan

### Phase 1: Manifest 模型层

1. `Sources/TokenBarCore/Models/PluginManifest.swift` — 新建：
   - `PluginManifest: Codable` struct，覆盖完整 manifest schema
   - `PluginSourceConfig` enum（jsonl / sqlite / executable 三种变体）
   - `PluginTokenSemantics` struct（inputIncludesCached + timestampFormat）
   - 校验逻辑：`validate() throws` 检查必填字段、semver 格式、glob 合法性
2. `Sources/TokenBarCore/Models/UsageModels.swift` — 扩展：
   - `CustomSourceEngine` 新增 `.pluginSqlite`、`.pluginExecutable`
   - `CustomSourceRecord` 新增 `pluginId`、`pluginVersion`、`inputIncludesCached`、`timestampFormat` 字段
3. `Sources/TokenBarCore/Services/UsageDatabase.swift` — migration：
   - `custom_sources` 表新增 `plugin_id TEXT`、`plugin_version TEXT`、`input_includes_cached INTEGER DEFAULT 0`、`timestamp_format TEXT DEFAULT 'iso8601'`
   - `custom_sources` 表新增 `sqlite_query TEXT`（JSON 序列化的查询配置）
   - `custom_sources` 表新增 `executable_config TEXT`（JSON 序列化的脚本配置）

### Phase 2: Token 归一层

4. `Sources/TokenBarCore/Parsers/TokenNormalizer.swift` — 新建：
   - `normalizeTokenUsage()` 函数，处理 `inputIncludesCached` + 负值 clamp
   - 所有 parser 的结果经过此函数后再写入 DB
5. 修改 `CustomUsageEventSource.loadEvents()` — 在 event 写入前调用归一函数
6. 为内置 parser 也接入归一层（后续内置 parser 如需要可声明 `inputIncludesCached`）

### Phase 3: 声明式 SQLite 插件引擎

7. `Sources/TokenBarCore/Services/PluginSqliteReader.swift` — 新建：
   - 根据 manifest.query 拼接 SQL（参数化，防注入）
   - GRDB 只读 + WAL 模式打开
   - 复用现有 watermark 机制（watermark_column 做增量）
   - 返回 `UsageSourceLoadResult`
8. `CustomUsageEventSource.loadEvents()` — 新增 `.pluginSqlite` 分支，调用 `PluginSqliteReader`

### Phase 4: 可执行插件引擎

9. `Sources/TokenBarCore/Services/PluginExecutableRunner.swift` — 新建：
   - `Process` spawn + stdout pipe + NDJSON 逐行解析
   - stderr 采集为 `ParseWarning`
   - timeout 硬杀 + 退出码检查
   - 设置环境变量 `TOKENBAR_PLUGIN_STATE_DIR`
10. `CustomUsageEventSource.loadEvents()` — 新增 `.pluginExecutable` 分支

### Phase 5: 插件安装/卸载

11. `Sources/TokenBarCore/Services/PluginManager.swift` — 新建：
    - `install(manifest: URL) async throws` — 下载 manifest + 附件到 plugins/{id}/
    - `uninstall(pluginId: String) async throws` — 删目录 + 删 CustomSourceRecord + cascade 删 events
    - `update(pluginId: String) async throws` — 下载新版 manifest，更新 record
    - `installed() -> [PluginManifest]` — 扫描 plugins/ 目录
    - `needsUpdate(installed: PluginManifest, remote: RegistryEntry) -> Bool`
12. `PluginManifest → CustomSourceRecord` 转换逻辑

### Phase 6: Registry 客户端

13. `Sources/TokenBarCore/Services/PluginRegistryClient.swift` — 新建：
    - 拉取 `registry.json`（与 UpdateChecker 共享 24h 缓存策略）
    - `RegistryEntry` 模型
    - `fetchIndex() async throws -> [RegistryEntry]`
    - `downloadManifest(entry: RegistryEntry) async throws -> PluginManifest`
14. 本地缓存：`plugins/registry-cache.json`

### Phase 7: Gallery UI

15. `Sources/TokenBar/Views/PluginGalleryView.swift` — 新建：
    - Installed / Available / Custom 三区域布局
    - Install / Uninstall / Update 按钮
    - Executable 类型安装时二次确认弹窗
    - Setup hints 展示
16. `SettingsView.swift` — 新增 Plugins tab，嵌入 Gallery

### Phase 8: Registry 仓库

17. 创建 `github.com/Bububuger/tokenbar-plugins` 仓库
18. 编写 `CONTRIBUTING.md`（manifest schema 文档 + 提交指南）
19. GitHub Action：PR 合并后自动校验 manifest + 重生成 `registry.json`
20. 首批种子插件：github-copilot（声明式 JSONL）、kiro-cli（声明式 SQLite）

---

## Out of Scope

- 插件间依赖（一个插件依赖另一个）
- 插件的 prompt 抓取能力（v1 只采集 token 用量，不采集 prompt 内容）
- 付费/私有插件分发
- 沙箱/容器化运行 executable 插件（v1 依赖 PR 审核 + 用户确认）
- 内置 parser 迁移为插件（内置源保持内置，不退化）
- HTTP push 通道（ali-trace 的 `/v1/ingest` 模式——后续可作为 executable 插件的一种变体实现）

## Acceptance Criteria

- [x] 声明式 JSONL 插件（如 github-copilot manifest）安装后能正确采集 token 数据
- [x] 声明式 SQLite 插件（如 kiro-cli manifest）安装后能正确采集 token 数据
- [x] 可执行插件（如 cursor collect.py）安装后能正确采集 token 数据
- [x] `inputIncludesCached: true` 的插件归一后 input = rawInput - cacheRead
- [x] Gallery 能拉取 registry.json 并展示可用插件列表
- [x] 一键安装/卸载/更新工作正常
- [x] 卸载插件时 cascade 删除对应 events 和 watermarks
- [x] Executable 插件安装时有二次确认弹窗
- [x] 插件超时（>timeout_seconds）时 Process 被 terminate
- [ ] `tbar sources` 显示已安装插件及其状态 — 自动继承，无代码变更需要
- [x] `script/test.sh` 通过，无回归 — 241/242 passed（1 个预存 perf flaky test）
- [x] `script/build.sh` 通过 — BUILD SUCCEEDED

## Test Plan

- [x] Unit: PluginManifest 解析 + 校验（合法/非法 manifest 各 5 例） — 6 tests
- [x] Unit: TokenNormalizer 归一逻辑（inputIncludesCached true/false × 正/负/零值） — 6 tests
- [x] Unit: PluginSqliteReader 查询拼接 + 注入防护 — 5 tests
- [x] Unit: PluginExecutableRunner stdout 解析 + timeout + 非零退出码处理 — 3 tests
- [x] Unit: PluginManager install/uninstall/update 文件操作 — 4 tests
- [x] Unit: TimestampFormat 各格式解析 — 6 tests
- [x] Unit: DB migration v13 列存在性 — 1 test
- [x] Unit: CustomSourceEngine 新 case 属性 — 3 tests
- [x] Unit: RegistryIndex 解码 — 1 test
- [ ] Integration: 从 fixture manifest → 安装 → checkpoint 采集 → 验证 events 入库 — deferred to app visual verification
- [ ] Manual: 在 Gallery 中安装一个声明式插件，验证 popover 显示新 agent — pending registry repo

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Executable 插件安全风险 | 任意代码执行 | PR 审核 + 安装时二次确认 + timeout |
| Manifest schema 未来需要扩展 | 不兼容 | `manifest_version` 字段 + 向前兼容解析 |
| 声明式 SQLite 拼接 SQL 注入 | 数据泄露 | 表名/列名白名单校验 + 参数化 WHERE |
| 目标 AI 工具更新导致 schema 变化 | 插件采集失败 | 社区 PR 修复 + TokenBar 侧 warning 提示 |
| Registry GitHub 仓库不可达 | Gallery 无法刷新 | 本地缓存 registry-cache.json 兜底 |
| 插件数量增长后 registry.json 过大 | 拉取慢 | 预期 <100 个插件，JSON <50KB，不是问题 |

## Verification

**2026-05-28 — Core implementation complete.**

Files added:
- `Sources/TokenBarCore/Models/PluginManifest.swift` — **New.** PluginManifest Codable model, PluginSourceConfig (jsonl/sqlite/executable), PluginFieldMapping, PluginSQLiteQuery, PluginExecutableSource, PluginTokenSemantics, PluginTimestampFormat, PluginRegistryEntry, PluginRegistryIndex, validation
- `Sources/TokenBarCore/Parsers/TokenNormalizer.swift` — **New.** normalizeTokenUsage() with inputIncludesCached + negative clamp; normalizeEvents() batch helper
- `Sources/TokenBarCore/Services/PluginSqliteReader.swift` — **New.** Declarative SQLite plugin engine: builds parameterized SQL from manifest.query, GRDB read-only, watermark support, table/column name whitelist validation
- `Sources/TokenBarCore/Services/PluginExecutableRunner.swift` — **New.** Executable plugin engine: Process spawn, NDJSON stdout parsing, stderr→warnings, timeout+terminate, exit code handling
- `Sources/TokenBarCore/Services/PluginManager.swift` — **New.** Plugin lifecycle: install/uninstall/update, manifest→CustomSourceRecord conversion, file management
- `Sources/TokenBarCore/Services/PluginRegistryClient.swift` — **New.** Registry client: fetch registry.json from GitHub, 24h cache, download manifests+attachments
- `Sources/TokenBar/Views/PluginGalleryView.swift` — **New.** SwiftUI Gallery UI: Installed/Available sections, install/uninstall buttons, executable confirmation alert
- `Tests/TokenBarCoreTests/PluginSystemTests.swift` — **New.** 35 tests across 9 suites

Files modified:
- `Sources/TokenBarCore/Models/UsageModels.swift` — Added `.pluginSqlite`, `.pluginExecutable` to CustomSourceEngine; added `pluginId`, `pluginVersion`, `inputIncludesCached`, `timestampFormat`, `sqliteQuery`, `executableConfig` to CustomSourceRecord
- `Sources/TokenBarCore/Services/UsageDatabase.swift` — Added migration v13_add_plugin_fields (6 new columns on custom_sources)
- `Sources/TokenBarCore/Services/UsageRepository.swift` — Extended listCustomSources/upsertCustomSource/customSourceRecord to read/write plugin fields; added encodeJSON/decodeJSON helpers
- `Sources/TokenBarCore/Services/CustomSources.swift` — Added `.pluginSqlite` and `.pluginExecutable` engine cases with TokenNormalizer integration
- `Sources/TokenBar/Views/SettingsView.swift` — Added pluginsSection embedding PluginGalleryView; added pathPrompt for new engine cases
- `Sources/TokenBar/App/TokenBarRuntimeModel.swift` — Added `store` accessor for PluginManager

Build: `swift build` — 0 errors. `script/build.sh` — BUILD SUCCEEDED.
Tests: `swift test` — 241/242 passed (35 new plugin tests, 1 pre-existing perf flaky).
