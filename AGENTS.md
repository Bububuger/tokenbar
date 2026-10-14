# AGENTS.md — TokenBar 项目合同

## 项目与架构

TokenBar 是原生 macOS 应用，使用 SwiftUI 构建菜单栏、popover、窗口和设置体验，并通过独立 Core 层发现、解析、聚合和持久化各类 Agent 用量。

- `Sources/TokenBar`：应用入口、SwiftUI views、运行时模型和资源。
- `Sources/TokenBarCore`：数据源、parser、用量模型、聚合、存储、索引与诊断服务。
- `Sources/TokenBarCLI`：命令行入口与过滤、library 等子命令。
- `Sources/TokenBarProbe`：无 UI 的本地用量探针入口。
- `Sources/Czstd`：随仓库提供的 zstd 解压器，用于 DeepSeek Harness 压缩日志。
- `Tests/TokenBarCoreTests`：parser、聚合、存储和服务回归测试。
- `Tests/TokenBarCLITests`：CLI 参数、过滤、输出和分发回归测试；由 SwiftPM 测试入口覆盖。
- `script/`：构建、运行、测试和本地验证脚本。
- `project.yml`：XcodeGen 项目定义；`TokenBar.xcodeproj` 为生成后的 Xcode 工程。

优先使用 SwiftUI 的 `MenuBarExtra`、`Window`、`WindowGroup`、`Settings`、`NavigationSplitView`、toolbar、快捷键和系统材质；仅在状态栏控制、窗口激活、焦点、hover、文件面板、拖放或诊断等 SwiftUI 无法可靠表达的行为上使用窄 AppKit bridge。

## macOS 构建与运行

需要 macOS 14+、Xcode 16+（Swift 6）及 XcodeGen。使用 shell 与 Xcode toolchain 驱动本地开发：

```bash
xcodegen generate --spec project.yml --project .
script/test.sh                     # SwiftPM：Core + CLI 测试
script/build_and_run.sh --verify    # 启动进程检查，不等于 UI 验收
```

- Xcode 工程配置变化后，先重新生成工程；检查 `project.yml`、生成工程与 `Package.swift` 的 target / 依赖保持一致。
- `script/test.sh --xcode` 使用 Xcode `TokenBarTests` scheme，仅覆盖 Core；不能替代 CLI 回归测试。
- 非 macOS 环境可做文档、静态引用与 shell 语法检查，不得将其报告为原生 build/test/UI 通过。
- SDK 变化时使用 SDK 隔离的 build cache，避免复用陈旧 SwiftSyntax 或 package 预编译产物。
- App Store archive、notarization 和最终签名属于独立发布阶段。

## 按需操作入口

| 触发 | 读取 |
| --- | --- |
| CLI 用法、JSON envelope、Library 清单与输出限制 | [`docs/cli.md`](docs/cli.md) |
| 版本发布、DMG、tag、GitHub Release、Homebrew Cask | [`docs/runbooks/release.md`](docs/runbooks/release.md) |
| 全量重建本地历史索引、`tbar rebuild`、重建性能或失败排查 | [`docs/runbooks/history-rebuild.md`](docs/runbooks/history-rebuild.md) |

入口合同只保留日常开发约束；发布和全历史重建步骤不在这里重复。

## 数据与扩展约束

- 内置来源以 `BuiltInSources.all()` / `catalog()` 为共同入口；当前 17 个来源用于 App、CLI rebuild、Probe、Settings 和 Diagnostics，避免在文档和 UI 另维护不一致清单。
- 来源报告的 cost（包括明确的 `0`）优先；仅缺失时估算。CLI 的 `costSource` 区分 `actual` / `defaults` / `mixed`，其默认估价不读取 App 的 UserDefaults 自定义价格。不要把用量账本描述成账单核对结果。
- Cursor 本地来源保留 human prompts，不生成本地 token 用量事件；账号用量来自默认关闭、显式启用的 Dashboard 同步，凭证存于 Keychain。不得把远端账号范围标成这台 Mac 的活动。
- `tbar rebuild` 重建用量索引，不负责扫描 Library；`skills` / `mcp` / `plugins` 读取 App 写入的 Library 快照。查询打开数据库也可能触发初始化或迁移。
- 本地用量索引默认位于 `~/Library/Application Support/TokenBar/tokenbar.sqlite`。Settings 的 JSON 导出仅含汇总、行数和自定义来源配置，不是完整数据库备份。
- 网络边界包含 GitHub 更新检查/下载、社区插件目录/安装，以及可选 Cursor 同步。可执行插件以用户权限运行；不得声称整个 App 无网络或插件已沙箱隔离。具体隐私边界见 [`SECURITY.md`](SECURITY.md)。
- 保留历史 work-items / release 文档的时间语境；当前使用说明更新 README、CONTRIBUTING 和 runbooks，不把规划中的功能写成已实现。

## UI 验收

- UI 改动必须经过真实 build/run；静态代码检查不能证明 macOS 行为可用。
- 视觉验收可使用明确标注的 mock 数据；可见数字需说明数据来源和时间窗口。
- 菜单栏空间有限，默认紧凑图标；现有可选 mirror 文本须保持长度预算（超过 14 字符退回图标），不要无条件增加数值。
- Details、Diagnostics 等窗口重复打开时聚焦既有窗口，不创建重复实例。
- Today、30d、Total 等不同时间窗口不得无标签混用。
- 视觉改动在可行时保留截图证据。

## 日志与诊断

- 运行时诊断使用 Swift `Logger`。
- 调查运行行为时使用 `log stream` 或脚本收集日志。
- 隐私、Accessibility、文件访问和自动化权限若影响用户行为，应在 `Info.plist`、entitlements 或 Diagnostics UI 中显式呈现。

## 交付报告

报告包括产品层变化、实际修改文件、构建/测试与 UI 验证证据，以及仍存在的限制或待决项。
