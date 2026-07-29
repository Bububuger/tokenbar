# TokenBar release runbook

> 仅在明确执行版本发布时读取。日常 build/test 不走此流程。

## 前置门禁

1. 工作区只包含本次 release 变更，目标版本为 `x.y.z`。
2. `script/test.sh` 通过；涉及 Xcode 工程配置时先运行
   `xcodegen generate --spec project.yml --project .` 并确认生成结果。
3. `xcodegen`、Xcode toolchain、`codesign` 和 `hdiutil` 可用。
4. tag、GitHub Release、上传资产和 Homebrew tap 都是外部写操作；执行前确认
   版本、远端和目标仓，不把构建成功当成已发布。

## 构建唯一入口

```bash
script/release.sh <version>
```

不要手工复刻脚本里的版本修改、Xcode build、CLI 嵌入、签名或 DMG 打包。
该入口会修改 `Resources/Info.plist`、`latest-version.json` 和生成的
`TokenBar.xcodeproj`，并生成 `dist/TokenBar-<version>.dmg`。

## 本地产物验收

1. 核对脚本输出的版本、DMG 路径、SHA-256 和嵌入式 CLI 路径。
2. 挂载 DMG，确认 `TokenBar.app` 可打开且
   `TokenBar.app/Contents/MacOS/tbar schema --json` 可执行。
3. 核对 App 与 CLI 来自同一个 bundle；记录 DMG SHA-256。
4. 检查 git diff，只提交预期版本文件和 Cask 模板更新，不提交
   `dist/`、DerivedData 或临时日志。

## 发布顺序

1. 提交版本变更并确认目标 commit。
2. 创建并推送 `v<version>` tag。
3. 在对应 GitHub Release 上传同一 SHA-256 的 DMG。
4. 更新 `script/release/Casks/tokenbar.rb` 的 `version` 与 `sha256`，再同步到
   Homebrew tap。
5. 从发布地址重新下载并核对 SHA-256；用 Homebrew Cask 安装后验证 App 和
   `tbar` 两个入口。

任一步缺少可核对的 commit、tag、资产或 SHA-256 时停止，不用后续步骤的表象
反推前一步成功。
