# AGENTS.md — TokenBar 项目合同

## 项目与架构

TokenBar 是原生 macOS 应用，使用 SwiftUI 构建菜单栏、popover、窗口和设置体验，并通过独立 Core 层发现、解析、聚合和持久化各类 Agent 用量。

- `Sources/TokenBar`：应用入口、SwiftUI views、运行时模型和资源。
- `Sources/TokenBarCore`：数据源、parser、用量模型、聚合、存储、索引与诊断服务。
- `Sources/TokenBarCLI`：命令行入口与过滤、library 等子命令。
- `Sources/TokenBarProbe`：探针入口。
- `Tests/TokenBarCoreTests`：Core 回归测试。
- `script/`：构建、运行、测试和本地验证脚本。
- `project.yml`：XcodeGen 项目定义；`TokenBar.xcodeproj` 为生成后的 Xcode 工程。

优先使用 SwiftUI 的 `MenuBarExtra`、`Window`、`WindowGroup`、`Settings`、`NavigationSplitView`、toolbar、快捷键和系统材质；仅在状态栏控制、窗口激活、焦点、hover、文件面板、拖放或诊断等 SwiftUI 无法可靠表达的行为上使用窄 AppKit bridge。

## macOS 构建与运行

使用 shell 与 Xcode toolchain 驱动本地开发：

```bash
xcodegen generate --spec project.yml --project .
script/test.sh
script/build_and_run.sh --verify
```

- Xcode 工程配置变化后，先重新生成工程。
- SDK 变化时使用 SDK 隔离的 build cache，避免复用陈旧 SwiftSyntax 或 package 预编译产物。
- App Store archive、notarization 和最终签名属于独立发布阶段。

## 按需操作入口

| 触发 | 读取 |
| --- | --- |
| 版本发布、DMG、tag、GitHub Release、Homebrew Cask | [`docs/runbooks/release.md`](docs/runbooks/release.md) |
| 全量重建本地历史索引、`tbar rebuild`、重建性能或失败排查 | [`docs/runbooks/history-rebuild.md`](docs/runbooks/history-rebuild.md) |

入口合同只保留日常开发约束；发布和全历史重建步骤不在这里重复。

## UI 验收

- UI 改动必须经过真实 build/run；静态代码检查不能证明 macOS 行为可用。
- 视觉验收可使用明确标注的 mock 数据；可见数字需说明数据来源和时间窗口。
- 菜单栏空间有限，优先紧凑图标或图表指示，不直接增加数值文本。
- Details、Diagnostics 等窗口重复打开时聚焦既有窗口，不创建重复实例。
- Today、30d、Total 等不同时间窗口不得无标签混用。
- 视觉改动在可行时保留截图证据。

## 日志与诊断

- 运行时诊断使用 Swift `Logger`。
- 调查运行行为时使用 `log stream` 或脚本收集日志。
- 隐私、Accessibility、文件访问和自动化权限若影响用户行为，应在 `Info.plist`、entitlements 或 Diagnostics UI 中显式呈现。

## 交付报告

报告包括产品层变化、实际修改文件、构建/测试与 UI 验证证据，以及仍存在的限制或待决项。
