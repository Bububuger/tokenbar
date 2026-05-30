# Work Item: Library Real-Data Integration (Scanner + Cache + Watcher)

**Date:** 2026-05-28
**Status:** Plan — pending review & approval

---

## Background

侧边栏 **Library 路由**（`LibraryView`, 1461 行）在 commit `8f5c6fe` 一次性落地了三 tab UI（Skills / Plugins / MCP），含 Graph + List 两种视图。但 **所有数据都是写死的 fixture**（`LibraryView.swift` 顶部的 `skillDirs / mcpDirs / plugins` 三个数组），跟用户磁盘实际状态完全脱钩。

随后 commit `9f8c52a` 加入了完整的 Plugin System（`PluginManager` + `PluginGalleryView` 在 Settings 内），但 Library 的 Plugins tab 跟它没打通。

通过对 8 个开源项目（4 个 Claude skill 管理器 + Helix / chezmoi / VS Code / Homebrew）的扫描机制 research，得出三条关键判断：

1. **4 个 Claude skill 管理器都是 CLI / hook 触发，没人做过常驻 watch** —— 没有现成 Swift 可抄
2. **VS Code 的"启动读 cache 秒出 UI + FSEvents 双订阅 + ThrottledDelayer 异步 revalidate"** 是常驻 app 唯一靠谱模式
3. **aclemen/claude-skill-manager 的 conflict matrix** 是 6 类诊断的最佳参考（user-plugin / scope-overlap / orphan-plugin 等）

## Requirement

把 Library 三 tab 从 fixture 切换到磁盘真实数据，建立一套可被 **MCP / Plugins** 复用的扫描 + watch + cache 通用基础设施。**用户最高价值**：在 macOS 菜单栏常驻应用里看到 `~/.claude/skills` + 项目 `.claude/skills` 的真实状态，包括 broken symlink、跨 scope 同名覆盖、size/token 估算。

---

## Design

### 术语

| 术语 | 含义 |
|---|---|
| **Scope** | `user` (`~/.claude/skills`) / `project` (`./.claude/skills`) / `shared` (用户配置的自定义路径) |
| **Real** | 实体目录（非 symlink） |
| **Symlink** | 软链接目录，`resolved_target` 指向真实路径 |
| **Broken** | symlink，但 `resolved_target` 不存在或不可读 |
| **Duplicate** | 同一 `name` 跨多个 scope 同时存在（real-only），优先级低的被影子覆盖 |
| **Conflict Class** | 命名冲突的诊断类型（参考 aclemen 6 类）|

### 四层架构

```
┌─────────────────────────────────────────────────┐
│  Layer 4: SnapshotPublisher                      │
│   - LibrarySnapshot (struct, immutable)          │
│   - rebuildLibrarySnapshot(trigger: String)      │  ← 复用 popoverSnapshot pattern
│   - @Published 给 LibraryView                    │
├─────────────────────────────────────────────────┤
│  Layer 3: LibraryCache (GRDB)                    │
│   - library_skills 表 + library_mcp 表           │  ← migration v14
│   - 启动 LibraryView 立即 SELECT (0ms IO)        │
│   - Scanner 完成后 diff + upsert                 │
├─────────────────────────────────────────────────┤
│  Layer 2: LibraryWatcher (FSEventStream)         │
│   - watch scope roots                            │
│   - 对每个 symlink 额外订阅 resolved target      │  ← VS Code 模式
│   - debounce 3s → 触发 Scanner                   │
├─────────────────────────────────────────────────┤
│  Layer 1: LibraryScanner                         │
│   - walk roots, parse SKILL.md frontmatter       │  ← aclemen 模式
│   - if symlink: resolve + 二次 Stat (broken 判定) │  ← chezmoi 模式
│   - size_bytes / 4 → est tokens                  │  ← scarlett 模式
│   - compute conflicts (6 类)                     │
└─────────────────────────────────────────────────┘
```

### 数据模型

#### Layer 1 — Scanner 输出

```swift
public struct ScannedSkill: Codable, Equatable {
    public let scope: LibraryScope          // .user | .project | .shared
    public let scopeRoot: URL               // 该 scope 的根目录
    public let name: String                 // 目录名
    public let path: URL                    // 实际路径（含 root + name）
    public let isSymlink: Bool
    public let resolvedTarget: URL?         // symlink ? canonicalized target : nil
    public let isBroken: Bool               // symlink && target 不可 stat
    public let sizeBytes: Int64             // SKILL.md + 整目录递归大小
    public let estimatedTokens: Int         // sizeBytes / 4
    public let description: String?         // SKILL.md frontmatter `description`
    public let allowedTools: [String]?      // frontmatter `allowed-tools`
    public let modifiedAt: Date             // SKILL.md mtime (fallback: dir mtime)
    public let scannedAt: Date
}

public struct ScannedMcpServer: Codable, Equatable {
    public let scope: LibraryScope          // .user | .project
    public let sourceFile: URL              // mcp_servers.json 来源
    public let name: String                 // JSON object key
    public let command: String              // 启动命令
    public let args: [String]
    public let env: [String: String]
    public let estimatedTokens: Int         // 暂用静态表，未来 introspect tools
    public let scannedAt: Date
}

public struct LibraryConflict: Equatable {
    public enum Kind { case userPlugin, scopeOverlap, brokenSymlink, orphanPlugin, duplicateReal }
    public let kind: Kind
    public let skillName: String
    public let scopes: [LibraryScope]       // 涉及的 scope 集合
    public let severity: Severity           // .warning | .error
}
```

#### Layer 3 — DB Schema (migration v14)

```sql
CREATE TABLE library_skills (
    scope TEXT NOT NULL,                    -- 'user' | 'project' | 'shared'
    scope_root TEXT NOT NULL,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    is_symlink INTEGER NOT NULL DEFAULT 0,
    resolved_target TEXT,
    is_broken INTEGER NOT NULL DEFAULT 0,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    estimated_tokens INTEGER NOT NULL DEFAULT 0,
    description TEXT,
    allowed_tools TEXT,                     -- JSON array
    modified_at REAL NOT NULL,              -- epoch seconds
    scanned_at REAL NOT NULL,
    PRIMARY KEY (scope, name)
);

CREATE TABLE library_mcp (
    scope TEXT NOT NULL,
    source_file TEXT NOT NULL,
    name TEXT NOT NULL,
    command TEXT NOT NULL,
    args TEXT,                              -- JSON array
    env TEXT,                               -- JSON object
    estimated_tokens INTEGER NOT NULL DEFAULT 0,
    scanned_at REAL NOT NULL,
    PRIMARY KEY (scope, name)
);

CREATE TABLE library_scan_state (
    scope TEXT PRIMARY KEY,
    last_scan_at REAL NOT NULL,
    last_error TEXT,
    skill_count INTEGER NOT NULL DEFAULT 0,
    mcp_count INTEGER NOT NULL DEFAULT 0
);
```

> Conflicts 不入库，每次 snapshot 重算（输入小，复杂度 O(n)）。

#### Layer 4 — Snapshot

```swift
public struct LibrarySnapshot: Equatable {
    public let skillsByScope: [LibraryScope: [ScannedSkill]]
    public let mcpByScope: [LibraryScope: [ScannedMcpServer]]
    public let plugins: [InstalledPluginInfo]   // 复用 PluginManager.installedManifests()
    public let conflicts: [LibraryConflict]
    public let scopeRoots: [LibraryScope: URL]
    public let lastFullScanAt: Date?
    public let isScanning: Bool
}
```

### Scope 路径策略

| Scope | 默认路径 | 可配置 |
|---|---|---|
| `user` | `~/.claude/skills`（写死，匹配 Claude Code 官方约定）| ❌ |
| `project` | 优先 active project root + `.claude/skills`，否则 cwd | ❌ |
| `shared` | 通过 `@AppStorage("tokenbar.library.sharedRoots")` 维护的 `[String]` | ✅ |

> 不抄 Helix 的 5 路径优先级链（过度），但保留扩展点。

### 冲突诊断（参考 aclemen，简化到 4 类）

```
.duplicateReal     —— 同名 real 出现在 ≥2 个 scope（user + project 都有 frontend-design）
                       优先级：project > user > shared（first-wins）
.scopeOverlap      —— 同名跨 scope，但其中至少一个是 symlink（可能是有意 override）
.brokenSymlink     —— symlink target 不存在
.userPlugin        —— skill 名与已安装 plugin id 撞名（plugin 总赢，user skill 被屏蔽）
```

去掉 aclemen 的 `orphanPlugin / marketplaceOverlap` 等暂时不需要的类目。

### Token 估算

- **Skills**: `sizeBytes / 4`（包含 SKILL.md + 子目录所有文件递归），粗估但够用
- **MCP**: v1 用静态表（已在 fixture 里：filesystem=8.4K, github=21K, postgres=6.2K…），后续 v2 通过 spawn server 调 `tools/list` introspect 真实 token

### Watch 策略

```swift
final class LibraryWatcher {
    private var eventStreams: [FSEventStreamRef] = []
    private let debouncer = ThrottledDelayer(milliseconds: 3000)  // 学 VS Code

    func start(roots: [URL]) {
        // 1. 主 watch：scope roots
        for root in roots { addStream(root, recursive: true) }

        // 2. Symlink target watch：扫描后对每个 symlink 的 resolvedTarget 额外订阅
        //    （VS Code issue #118134 的做法，防止用户在 ~/dev/skills-repo/foo 改动
        //     而 ~/.claude/skills/foo -> 那里 收不到事件）
        for symlinkTarget in scanner.collectSymlinkTargets() {
            addStream(symlinkTarget, recursive: true)
        }
    }

    private func onChange(_ paths: [String]) {
        debouncer.schedule { Task { await scanner.rescanAffected(paths: paths) } }
    }
}
```

### 与现有架构集成

```
LibraryView (现有 fixture)
        │
        ▼
@EnvironmentObject runtimeModel.librarySnapshot   ← 新增
        │
        ▼
TokenBarRuntimeModel.rebuildLibrarySnapshot(trigger:)   ← 新增，仿 rebuildPopoverSnapshot
        │
        ├─ LibraryScanner.scanAll() async → [ScannedSkill] / [ScannedMcpServer]
        ├─ store.upsertLibrarySkills(...) / upsertLibraryMcp(...)
        ├─ PluginManager.installedManifests() → 接入 Plugins tab
        └─ ConflictDetector.compute(...) → [LibraryConflict]
        │
        ▼
LibrarySnapshot (immutable struct, @Published)
        │
        ▼
LibraryView.body → 读 snapshot 替代 fixture
```

**关键复用**：
- `actor LibraryScanner` ← 模仿 `actor PluginManager` 结构
- `UsageStore.upsertLibrarySkills(...)` ← 模仿 `upsertCustomSource(...)`
- `Migration v14` ← 模仿 v13 同款 SQL DDL 方式
- `rebuildLibrarySnapshot(trigger:)` ← 复用 `rebuildPopoverSnapshot(trigger:)` 的 trigger 字符串规约（"watcher.fs_event" / "manual.rescan" / "appear" / "plugin-install"）

### LibraryView 改动范围

**仅替换数据源，不改 UI 结构。**

- 删除：`LibraryView.swift` 顶部的 `skillDirs / mcpDirs / plugins` fixture 常量（约 75 行）
- 新增：`@EnvironmentObject runtimeModel` + 把 `LibrarySkillItem/LibrarySkillDir` 等结构改成由 `LibrarySnapshot` 投影的 view model
- Toolbar 增加 "Rescan" 按钮触发 `runtimeModel.rebuildLibrarySnapshot(trigger: "manual.rescan")`
- "Add symlink…" 按钮接入 `sharedRoots` 编辑

### 安全考量

| 风险 | 应对 |
|---|---|
| Scanner walk 进入符号链接环 | 在 `LibraryScanner` 内部维护 visited `Set<URL>`（canonical path），跳过已访问 |
| SKILL.md frontmatter 过大撑爆内存 | 只读前 8KB；frontmatter 解析失败降级为 description=nil 不报错 |
| MCP json 含敏感 env（API keys） | snapshot 只存 env keys 不存 values；UI 显示 `KEY=***` |
| sharedRoots 用户配错路径 | scope state 表记 `last_error`，UI 在 Library 顶部显示 banner |
| Watch 对 `/` 等危险路径 | sharedRoots 校验：拒绝深度 ≤2 的路径 |

---

## Implementation Plan

### Phase 1 — Data Model & Migration

1. `Sources/TokenBarCore/Models/LibraryModels.swift` — **新建**：
   - `ScannedSkill`, `ScannedMcpServer`, `LibraryConflict`, `LibrarySnapshot`, `LibraryScope` (从 `LibraryView` 提出来到 Core)
2. `Sources/TokenBarCore/Services/UsageDatabase.swift` — **migration v14**：
   - 新建 `library_skills`, `library_mcp`, `library_scan_state` 三张表
3. `Sources/TokenBarCore/Services/UsageRepository.swift` — **扩展**：
   - `upsertLibrarySkills([ScannedSkill]) async throws`
   - `upsertLibraryMcp([ScannedMcpServer]) async throws`
   - `loadLibrarySnapshot() async throws -> (skills: [ScannedSkill], mcp: [ScannedMcpServer], scanState: [LibraryScope: LibraryScanState])`
   - 老的 diff 删除策略：upsert 时按 `scope` 分组 DELETE then INSERT（避免遗留）

### Phase 2 — Scanner

4. `Sources/TokenBarCore/Services/SkillScanner.swift` — **新建**：
   - `actor SkillScanner`
   - `scanScope(_ scope: LibraryScope, root: URL) async throws -> [ScannedSkill]`
   - 内部用 `FileManager.contentsOfDirectory + .isSymbolicLinkKey + .canonicalPath`
   - SKILL.md frontmatter 解析（自写，`---\n...\n---` 之间按 `key: value` 解析）
   - size 递归用 `URL.fileResourceValues(forKeys: [.fileSizeKey])` + DirectoryEnumerator
   - visited Set 防环
5. `Sources/TokenBarCore/Services/McpScanner.swift` — **新建**：
   - `actor McpScanner`
   - `scanScope(_ scope: LibraryScope, configFile: URL) async throws -> [ScannedMcpServer]`
   - 解析 `mcp_servers.json` (user) 和 `.claude/mcp.json` (project)
6. `Sources/TokenBarCore/Services/LibraryConflictDetector.swift` — **新建**：
   - `static func compute(skills: [ScannedSkill], plugins: [PluginManifest]) -> [LibraryConflict]`
   - 4 类诊断 + first-wins 优先级判定

### Phase 3 — Watcher

7. `Sources/TokenBarCore/Services/LibraryWatcher.swift` — **新建**：
   - 封装 `FSEventStreamCreate`（macOS only，加 `#if os(macOS)`）
   - `start(roots: [URL], symlinkTargets: [URL])` / `stop()`
   - 内部 `ThrottledDelayer` (3s, 仿 VS Code)
   - 回调通过 `AsyncStream<[String]>` 暴露
8. `Sources/TokenBarCore/Services/ThrottledDelayer.swift` — **新建（小工具）**：
   - 简单的 task cancellation + sleep 3s 模式

### Phase 4 — Runtime Integration

9. `Sources/TokenBar/App/TokenBarRuntimeModel.swift` — **扩展**：
   - 新增 `@Published var librarySnapshot: LibrarySnapshot`
   - 新增 `var isScanningLibrary: Bool`
   - `rebuildLibrarySnapshot(trigger: String) async`
     - 启动时先从 DB 读，立即 publish
     - 然后并行触发 SkillScanner + McpScanner
     - 写回 DB → 重算 conflicts → publish 新 snapshot
   - 在 `bootstrapIfNeeded()` 内启动 LibraryWatcher
10. `Sources/TokenBar/Views/LibraryView.swift` — **改造**：
    - 删除 fixture 常量
    - 改用 `@EnvironmentObject runtimeModel.librarySnapshot`
    - Toolbar `Rescan` 按钮接 trigger
    - `Add symlink…` 按钮触发 sharedRoots 编辑（弹 NSOpenPanel）
11. `Sources/TokenBar/Views/LibraryView.swift` Plugins tab — **接入 PluginManager**：
    - `PluginsBody` 读 `runtimeModel.librarySnapshot.plugins`
    - `LibraryPluginItem` 从 `PluginManifest` 投影

### Phase 5 — Settings 入口

12. `Sources/TokenBar/Views/SettingsView.swift` — **新增** `librarySection`：
    - 显示 user/project/shared 各 scope 的 last scan / count / error
    - "Add custom skill root…" 按钮编辑 `sharedRoots` AppStorage
    - "Rescan now" 按钮

### Phase 6 — Telemetry

13. `Sources/TokenBarCore/Telemetry/...` — **打点**：
    - `library.scan.begin` / `library.scan.end` (含 duration, skill_count, mcp_count)
    - `library.watch.event` (含 path 数量, debounce 命中)
    - `library.conflict.detected` (按 kind 分组计数)
    - `library.rebuild.trigger` (含 trigger 字符串)

---

## Out of Scope

- Library Plugins tab 的 marketplace 浏览 / 安装（Settings 已有，不在 Library 内重复）
- Skill 内容（SKILL.md 正文）的预览面板
- MCP server 的实时 health 探测（`McpHealthStatus` 字段保留，统一返回 `.unchecked`）
- 编辑 skill 文件能力（read-only 浏览）
- Graph 视图的力导向布局重写（现有 Canvas 静态布局保留）
- Skill 真实 tokenizer 估算（v1 用 `sizeBytes/4`，v2 才考虑接 GPT-2 tokenizer）
- 同步 / 推送 skill 到团队（dotfiles 工作流交给用户自己的 git）
- Watch Linux/Windows（`#if os(macOS)`，其它平台降级为手动 rescan）

## Acceptance Criteria

- [ ] LibraryView Skills tab 显示真实 `~/.claude/skills` 与项目 `.claude/skills` 数据
- [ ] LibraryView MCP tab 显示真实 `~/.config/claude/mcp_servers.json` 与项目 `.claude/mcp.json` 数据
- [ ] LibraryView Plugins tab 显示 `PluginManager.installedManifests()` 真实数据
- [ ] symlink skill 显示为虚线圈（Graph）/ symlink chip（List），broken symlink 红色 `broken` 标
- [ ] 跨 scope 同名 skill 显示 duplicate / override 标记（first-wins：project > user > shared）
- [ ] 在 `~/.claude/skills` 新建一个目录，**3 秒内** Library 出现新条目（watcher debounce）
- [ ] 删除一个 skill 目录，**3 秒内** Library 移除该条目
- [ ] symlink 的 target 在另一个磁盘位置改动（如 `~/dev/skills-repo/foo`），Library mtime 也更新（symlink target watch）
- [ ] 应用冷启动 → LibraryView 首屏渲染 **< 100ms**（读 DB cache，不等扫描）
- [ ] 用户配置 `sharedRoots` 后立即生效（即使 watcher 还没启动）
- [ ] sharedRoots 配错路径不崩，UI banner 显示错误
- [ ] 卸载 plugin 后 LibraryView Plugins tab 立即更新
- [ ] `script/test.sh` 通过，无回归
- [ ] `script/build.sh` 通过

## Test Plan

### Unit Tests — Scanner (`SkillScannerTests.swift`)

- [ ] `scanScope_emptyDir_returnsEmpty` — 空目录返回 `[]`
- [ ] `scanScope_realSkill_parsesFrontmatter` — 含 SKILL.md 的真实目录正确解析 name + description
- [ ] `scanScope_skillWithoutFrontmatter_descriptionIsNil` — 无 frontmatter 仍能列出，description = nil
- [ ] `scanScope_symlinkToExisting_marksIsSymlink` — symlink 指向有效目录：`isSymlink=true, isBroken=false, resolvedTarget != nil`
- [ ] `scanScope_symlinkToMissing_marksBroken` — symlink target 不存在：`isBroken=true`
- [ ] `scanScope_symlinkCycle_doesNotInfiniteLoop` — A → B → A 不死循环
- [ ] `scanScope_sizeCalculation_recursiveSum` — 含子目录的 skill 大小累加
- [ ] `scanScope_estimatedTokens_isSizeBytesOverFour` — `estimatedTokens == sizeBytes / 4`
- [ ] `scanScope_frontmatterTruncatedAt8KB` — SKILL.md 巨大也只读前 8KB
- [ ] `scanScope_frontmatterMalformed_doesNotThrow` — 损坏的 YAML 不抛错，degrade 为 description=nil
- [ ] `scanScope_modifiedAtFallsBackToDirMtime` — 无 SKILL.md 时用目录 mtime

### Unit Tests — McpScanner (`McpScannerTests.swift`)

- [ ] `scanScope_validJson_returnsServers` — 标准 `mcp_servers.json` 解析正确
- [ ] `scanScope_missingFile_returnsEmpty` — 配置文件不存在返回 `[]`，不抛错
- [ ] `scanScope_malformedJson_returnsEmptyWithError` — 损坏的 JSON 不崩，`last_error` 被记录
- [ ] `scanScope_envValuesRedacted` — env 的 value 不返回（snapshot 只存 keys）

### Unit Tests — ConflictDetector (`LibraryConflictDetectorTests.swift`)

- [ ] `compute_noDuplicates_returnsEmpty` — 无同名 skill 时返回 `[]`
- [ ] `compute_userAndProjectSameName_returnsDuplicateReal` — 检测 duplicate
- [ ] `compute_firstWinsProjectOverUser` — project 出现在 conflict 的 winner scope
- [ ] `compute_brokenSymlink_returnsBrokenSymlink` — broken symlink 单独成为 conflict
- [ ] `compute_skillNameMatchesPluginId_returnsUserPlugin` — skill 与 plugin 同名报警
- [ ] `compute_symlinkOverride_returnsScopeOverlap` — symlink 覆盖 real 的 override 关系

### Unit Tests — Watcher (`LibraryWatcherTests.swift`)

- [ ] `start_emitsEventWhenFileAdded` — 新建文件触发回调
- [ ] `start_debouncesMultipleEvents` — 1 秒内 10 次事件合并为一次回调
- [ ] `symlinkTargetWatch_emitsWhenTargetChanges` — 改动 resolved target 也能收到
- [ ] `stop_releasesAllStreams` — `stop()` 后无内存泄漏（用 `FSEventStreamRelease` 计数）

### Unit Tests — Repository (`LibraryRepositoryTests.swift`)

- [ ] `migration_v14_createsTables` — 三张表 + 索引存在
- [ ] `upsertLibrarySkills_replacesByScope` — 同 scope 重复 upsert 不留旧数据
- [ ] `loadLibrarySnapshot_returnsAllScopes` — 多 scope 数据正确回读
- [ ] `loadLibrarySnapshot_emptyDb_returnsEmptySnapshot` — 空库不崩

### Unit Tests — Runtime (`TokenBarRuntimeModelTests.swift`)

- [ ] `rebuildLibrarySnapshot_publishesNewSnapshot` — `@Published` 触发观察者
- [ ] `rebuildLibrarySnapshot_isIdempotent` — 短时间内多次调用不重复扫描（in-flight 去重）
- [ ] `bootstrap_startsLibraryWatcher` — `bootstrapIfNeeded()` 启动 watcher
- [ ] `sharedRootsChange_triggersRescan` — `AppStorage` 变更触发新扫描

### Integration Tests

- [ ] `endToEnd_freshDb_firstScan_visibleInSnapshot` — fixture skill 目录从 fixture → scan → DB → snapshot 通路
- [ ] `endToEnd_watcherTriggersRescan_within5s` — 创建文件 → 5 秒内 snapshot 包含新条目
- [ ] `endToEnd_pluginInstall_appearsInLibraryPluginsTab` — 通过 PluginManager.install 后 Library Plugins tab 立即出现

### Manual Tests

- [ ] 启动 app，打开 Library Skills tab，看到自己 `~/.claude/skills` 真实列表
- [ ] 在 `~/.claude/skills` 新建 `test-skill/SKILL.md`，3 秒内 Library 出现
- [ ] 删除该目录，3 秒内 Library 消失
- [ ] 创建 symlink `ln -s ~/dev/skills-repo/foo ~/.claude/skills/foo`，Library 显示 symlink chip
- [ ] 删除 symlink target，Library 显示 broken
- [ ] 在项目 `./.claude/skills` 创建同名 skill，Library 显示 duplicate 标记
- [ ] Settings 添加自定义 `sharedRoots`，rescan 后该 scope 出现
- [ ] 把 `sharedRoots` 改成不存在路径，Library banner 显示 error
- [ ] 安装一个 plugin (PluginGalleryView)，Library Plugins tab 立即更新
- [ ] Cold start 计时：Library tab 首屏渲染时间 < 100ms（DB cache 命中）

### Performance Tests

- [ ] `scanScope_1000Skills_under500ms` — 1000 个 skill 目录全扫 < 500ms
- [ ] `scanScope_avgSkillSize_100KB_noStallOnMain` — 大 skill 不阻塞主线程（actor 在 utility queue）

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| FSEvents 对 symlink target 的事件投递不稳定 | broken 检测延迟 | 双订阅 + 每 5 分钟兜底全量 rescan |
| `~/.claude/skills` 的非 Claude Code 文件污染 | 误报 skill | 只把含 SKILL.md 的目录视为 skill；其他目录在 conflict tab 单独列 |
| SKILL.md frontmatter 多种方言（YAML / TOML / 简单 KV） | 解析失败 | v1 只支持 YAML-like `key: value`，失败 fallback 为 nil |
| 用户的 sharedRoots 含 `~/Downloads` 或 `/` 等海量目录 | watcher 爆内存 | sharedRoots 校验：拒绝 `$HOME` / `/` / 顶层路径 |
| Migration v14 在已有 sqlite 上失败 | 启动崩溃 | 在 staging 用真实 prod DB clone 跑一遍 migration |
| Library tab 在 watch 启动前打开 | 首屏空 | 启动时即从 DB cache 读，UI 永远有数据；scanning 状态用 inline spinner |
| 同时多 scope 扫描竞争 actor | 慢 | 各 scanner 独立 actor，并行 `async let` 触发 |
| LibraryView 改成订阅 snapshot 引入大改 | 回归风险 | Phase 4 单独拆 PR，UI 行为做 snapshot diff 对比 |

---

## File Inventory

**新建：**

```
Sources/TokenBarCore/Models/LibraryModels.swift             (~150 行)
Sources/TokenBarCore/Services/SkillScanner.swift            (~200 行)
Sources/TokenBarCore/Services/McpScanner.swift              (~120 行)
Sources/TokenBarCore/Services/LibraryConflictDetector.swift (~100 行)
Sources/TokenBarCore/Services/LibraryWatcher.swift          (~180 行)
Sources/TokenBarCore/Services/ThrottledDelayer.swift        (~40 行)
Tests/TokenBarCoreTests/SkillScannerTests.swift             (~250 行)
Tests/TokenBarCoreTests/McpScannerTests.swift               (~120 行)
Tests/TokenBarCoreTests/LibraryConflictDetectorTests.swift  (~150 行)
Tests/TokenBarCoreTests/LibraryWatcherTests.swift           (~120 行)
Tests/TokenBarCoreTests/LibraryRepositoryTests.swift        (~100 行)
```

**修改：**

```
Sources/TokenBarCore/Services/UsageDatabase.swift      (+~60, migration v14)
Sources/TokenBarCore/Services/UsageRepository.swift    (+~120, library CRUD)
Sources/TokenBar/App/TokenBarRuntimeModel.swift        (+~80, librarySnapshot + watcher 启停)
Sources/TokenBar/Views/LibraryView.swift               (-75 fixture, +~120 snapshot 投影, +~40 sharedRoots UI)
Sources/TokenBar/Views/SettingsView.swift              (+~80, librarySection)
```

**预计总变更：**~1600 行新增，~80 行删除，~280 行修改。

## Verification

待实现完成后回填，参照 `2026-05-27-plugin-system.md` 的 Verification 段格式：
- Files added / modified 明细
- `swift build` / `swift test` 结果
- 关键 manual test 截图或日志

---

## References

- [docs/work-items/2026-05-27-plugin-system.md](./2026-05-27-plugin-system.md) — Plugin System 实现，本工作复用其 schema / migration / actor pattern
- [aclemen1/claude-skill-manager](https://github.com/aclemen1/claude-skill-manager) — `discovery.py` / `conflicts.py` 是 Scanner + ConflictDetector 的主要参照
- [microsoft/vscode `extensionsScannerService.ts`](https://github.com/microsoft/vscode) — Cache + ThrottledDelayer + symlink 双订阅模式
- [chezmoi `sourcestate.go`](https://github.com/twpayne/chezmoi) — walk 中 broken symlink 检测
- [Homebrew `formula.rb` / `keg.rb`](https://github.com/Homebrew/brew) — `linked?` 三重校验 symlink
