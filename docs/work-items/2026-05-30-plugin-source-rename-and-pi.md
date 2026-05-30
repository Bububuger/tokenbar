# Plan: 新增 pi 解析器 + engine→plugin 重命名 + Settings 重构

状态:已规划,待实施。Working dir: `/Users/travis/Documents/TeamFile/claude-workspace/tokenbar`

## Context

TokenBar 现状:`CustomSourceEngine`(枚举,持久化为 `custom_sources.engine` 列)= 解析器选择;当前 **7 个**内置 agent(claude/codex/gemini/opencode/openclaw/hermes/warp)硬编码在 `BuiltInSources.all()`,在 Settings「Sources & Data」以静态 tile 展示;「Plugins」tab 是社区 marketplace(`PluginGalleryView` + `PluginManager` + 远程 `registry.json`)。

> **本轮目标:内置 plugin 从 7 个增加到 8 个**(加 pi,保留 warp)。下文凡提到「8 个内置 plugin」即指最终结果。

用户要的新模型:**plugin = 提供解析器,source = 提供目录**。本轮交付(均已确认,**plugin market 本轮不动**):

1. 新增 **pi**(开源 agent,代码在 `/Users/travis/Documents/TeamFile/claude-workspace/pi`)作为第 8 个内置 native 解析器/agent。保留 warp。
2. 「engine」概念**连代码 + DB**重命名为「plugin」。
3. Settings:General 去掉 plugin teaser;**Plugins tab = 8 个内置 plugin(解析器,只读展示)+ 保留现有社区 gallery**;Sources tab 文案 engine→plugin 并加 Pi tile。
4. prompt-template 删除二次确认(上一轮已写入 `SavedPromptsListView.swift`,**尚未构建验证**,本计划末尾一并验证)。

> 明确**不做**:把 8 个 native 解析器上传 market / 改成 declarative manifest / 默认安装机制 —— native Swift 解析器无法表达成 market 的 jsonl manifest,留待后续。

## pi 数据格式(已确认,写解析器依据)

- 目录:`~/.pi/agent/sessions/--<encoded-cwd>--/<ts>_<sessionId>.jsonl`(agent dir 默认 `~/.pi/agent`)。
- 每个 `.jsonl`:第 1 行 header `{type:"session",version:3,id,timestamp,cwd}`(`cwd`=项目路径);后续行 entry `{type,id,parentId,timestamp,...}`。
- `type:"message"` 且 `message.role=="assistant"` 带:`message.model:string`、`message.usage:{input,output,cacheRead,cacheWrite,totalTokens}`、`message.timestamp`(ms)、`message.stopReason`。
- 映射:`input→inputTokens`、`output→outputTokens`、`cacheRead→cacheReadTokens`、`cacheWrite→cacheCreationTokens`、`model→modelName`、projectPath=header `cwd`、sessionID=header `id`、时间戳=message.timestamp(ms→Date);跳过 `stopReason∈{aborted,error}` 的空 usage。

## 实施步骤

### A. 新增 pi 内置解析器 + agent(第 8 个)

1. **`Sources/TokenBarCore/Models/UsageModels.swift`**:`AgentKind` 加 `case pi`(`displayName "Pi"`、`defaultCostPerMillionTokens` 取通用默认);`CustomSourceEngine`(B 步改名)加 `case pi`(`displayName "Pi"`、`defaultGlobPattern "sessions/**/*.jsonl"`、`agentKind .pi`)。
2. **新建 `Parsers/PiUsageParser.swift`** — 镜像 `OpenClawUsageParser`:解析 JSONL,识别 version-3 header(取 cwd/id),对 assistant message 行产出 `UsageEvent`;ms 时间戳 `Date(timeIntervalSince1970: ms/1000)`。
3. **新建 `Services/PiDataSource.swift`** — 镜像 `OpenClawDataSource`:`discoverSessionFiles` 走 `<root>/sessions/**/*.jsonl`、`expandHome`、session context。
4. **新建 `Services/PiUsageEventSource.swift`** — 镜像 `OpenClawUsageEventSource`:`sourceName="Pi"`、`agent=.pi`、`rootPath="~/.pi/agent"`、`JSONLWatermarkLoader.load` + `PiUsageParser`。
5. **`Services/BuiltInSources.swift`**:`all()` 加 `PiUsageEventSource()` → 内置变 **8 个**(claude / codex / gemini / opencode / openclaw / hermes / warp / **pi**)。
6. **`Services/CustomSources.swift`**:`switch record.plugin` 加 `case .pi:`(参照 `.openclaw` 分支走 `PiUsageParser`)。
7. **周边**:`TokenBarStyle.agentColor("Pi")` 配色;`DiagnosticsView` 若枚举 agent 补 pi。

### B. engine → plugin 重命名(代码 + DB)

1. **代码符号**:`CustomSourceEngine`→`CustomSourcePlugin`;`CustomSourceRecord.engine`→`.plugin`;`AddCustomSourceOverlay` 的 `engine` state/`enginePicker`→`pluginPicker`;CLI(`tbar sources`)输出字段 `engine`→`plugin`。**枚举 rawValue 不变**("claudeCode" 等保持,防数据失配)。
2. **DB v18 migration(append-only)**:`UsageDatabase.swift` 末尾加
   `registerMigration("v18_rename_custom_sources_engine_to_plugin")`:`ALTER TABLE custom_sources RENAME COLUMN engine TO plugin;`。同步 `UsageRepository`/`CustomSources` 里所有读写 `custom_sources` 的 SQL 列名 `engine`→`plugin`。
3. `PluginManager.manifestToRecord` 的 `engine:` 参数→`plugin:`。

### C. Settings 重构(`Sources/TokenBar/Views/SettingsView.swift`)

1. **General**:`.general` 分支去掉 `pluginsTeaserSection`,删其定义。
2. **Plugins tab**:`pluginsSection` 顶部新增「内置 plugin」区——列 8 个内置解析器(名称 + 默认 glob + agent 颜色,只读);下方保留 `PluginGalleryView()`(社区 market 装/卸不变)。tab 角标计数维持 `installedManifests().count`(实现时如简单可改 8+installed,PR 注明)。
3. **Sources tab**:`editableCustomSourceTile` 的 `source.engine.displayName`→`source.plugin.displayName`;`AddCustomSourceOverlay`「Engine」label→「Plugin」;内置 source tile 加 Pi(`~/.pi/agent`)。

### D. prompt-template 删除二次确认

`Sources/TokenBar/Views/SavedPromptsListView.swift` 已加 `promptPendingDelete`+`.alert`,Delete 按钮置位 pending。本步随整体构建验证。

## 关键复用点

- 解析器模板:`Services/OpenClawUsageEventSource.swift`、`Parsers/OpenClawUsageParser.swift`、`Services/OpenClawDataSource.swift`。
- JSONL 增量:`Services/JSONLWatermarkLoader.swift`。
- 迁移范式:`UsageDatabase.swift` v13(ADD COLUMN)/v17(ALTER),append-only。
- 加 agent 全量 touch-point 参照 warp:`grep -rln "warp\|\.warp\|Warp" Sources/`。
- pbxproj 加新文件参照本会话加 `McpConfigEditor.swift` 的 4 处(PBXBuildFile/PBXFileReference/group/Sources phase)。

## 风险/取舍

- **DB 列 rename** 风险中等(改全部 custom_sources 读写 SQL);rawValue 不动防失配。
- pi 解析器本机暂无真实 `.jsonl`(`~/.pi/agent` 无 session),以单测兜底。
- 内置 source 仍硬编码、不迁进 DB(全量统一超本次范围)。

## 验收 Checklist

### A. pi 内置解析器
- [x] `AgentKind.pi` + `CustomSourcePlugin.pi`(displayName "Pi"、glob `sessions/**/*.jsonl`、agentKind `.pi`)
- [x] 新建 `PiUsageParser.swift` / `PiDataSource.swift` / `PiUsageEventSource.swift`
- [x] `BuiltInSources.all()` 含 pi → **内置 8 个**(CLI `tbar sources` 确认 8 个 builtin agent)
- [x] `CustomSources.swift` 的 `switch` 有 `.pi` 分支
- [x] `PiUsageParser` 单测(4 个):header+assistant→token 映射、cwd 项目名、aborted/error/非 assistant 跳过、零 usage 跳过、缺时间戳告警、多轮累加
- [x] 3 个新文件已加进 `TokenBar.xcodeproj/project.pbxproj`(4 处)→ xcodebuild 通过

### B. engine → plugin 重命名
- [x] 代码符号全改:`CustomSourcePlugin` 类型、`CustomSourceRecord.plugin`、`pluginPicker`、CLI 输出字段 `plugin`(`tbar sources --help` 显示 `plugin`)
- [x] 枚举 rawValue **未变**("claudeCode" 等;DB 迁移后值保持)
- [x] v18 migration `ALTER TABLE custom_sources RENAME COLUMN engine TO plugin`
- [x] `UsageRepository`/`CustomSources` 所有 custom_sources SQL 列名已改
- [x] `tbar rebuild` 后 `PRAGMA table_info(custom_sources)` 见 `plugin`、无 `engine`;`grdb_migrations` 含 v18

### C. Settings 重构
- [x] General tab 无 plugin teaser(`pluginsTeaserSection` 定义已删)
- [x] Plugins tab:8 个内置 plugin 只读展示(`builtInPluginTile`)+ 下方保留社区 `PluginGalleryView`
- [x] Sources tab:tile 徽标显示 `plugin.displayName`、Add 弹窗 label "Plugin"、内置 tile 含 Pi(`~/.pi/agent`)

### D. 删除二次确认
- [x] prompt template 删除弹确认框(`SavedPromptsListView` `promptPendingDelete` + `.alert`)
- [x] 复核其它删除路径均已有二次确认:skill(alert)、mcp(alert)、custom source(alert)、pricing reset(confirmationDialog)、reset-all(alert+RESET)、reparse(confirmationDialog)、wipe prompts(alert+WIPE)

### 构建 & 测试
- [x] `swift build` + `swift build --target TokenBar` + `xcodebuild ... build` 全绿
- [x] `swift test` 全过(253 tests,含新增 PiUsageParser 4 个单测)
- [x] App 重启:DB `plugin` 列 + 2 条 custom_sources 完好;v18 已落库

