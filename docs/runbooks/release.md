# TokenBar release runbook

> 仅在明确执行版本发布时读取。日常 build/test 不走此流程。

## 前置门禁

1. 工作区只包含本次 release 变更，目标版本为 `x.y.z`。
2. `script/test.sh` 通过；涉及 Xcode 工程配置时先运行
   `xcodegen generate --spec project.yml --project .` 并确认生成结果。
3. 在 macOS 上确认 `xcodegen`、支持 Swift 6 的完整 Xcode toolchain、`codesign`
   和 `hdiutil` 可用。先检查全部前置条件：脚本在检查 `xcodegen` 前就会修改版本文件。
4. tag、GitHub Release、上传资产和 Homebrew tap 都是外部写操作；执行前确认
   版本、远端和目标仓，不把构建成功当成已发布。

## 构建唯一入口

```bash
script/release.sh <version>
```

不要手工复刻脚本里的版本修改、Xcode build、CLI 嵌入、签名或 DMG 打包。
该入口会修改 `Resources/Info.plist`、`latest-version.json` 和生成的
`TokenBar.xcodeproj`，并生成 `dist/TokenBar-<version>.dmg`。
`CFBundleVersion` 使用当前 Unix 时间戳；重复构建会重新修改它。

这是 Release 配置的 build，包含嵌入式 CLI 和 ad-hoc 签名；不执行 Xcode archive、
Developer ID 签名或 notarization，也不生成 ZIP。脚本不提交代码、不创建或推送 tag、
不上传 GitHub Release，也不自动更新 Cask。失败后先检查版本文件和构建日志，
不要把留下的文件当作成功发布的证据。

## 本地产物验收

1. 核对脚本输出的版本、DMG 路径、SHA-256 和嵌入式 CLI 路径。
2. 挂载 DMG，确认 `TokenBar.app` 可打开且
   `TokenBar.app/Contents/MacOS/tbar schema --json` 可执行。
3. 核对 App 与 CLI 来自同一个 bundle；记录 DMG SHA-256。
4. 用本次版本和已验收 DMG 的 SHA-256 更新 `script/release/Casks/tokenbar.rb`。
5. 检查 git diff，只提交预期版本文件和 Cask 模板更新，不提交
   `dist/`、DerivedData 或临时日志。

## 发布顺序

1. 提交版本变更并确认目标 commit。
2. 创建并推送 `v<version>` tag。
3. 在对应 GitHub Release 上传同一 SHA-256 的 DMG。
4. 将已核对的 `script/release/Casks/tokenbar.rb` 同步到独立的 Homebrew tap 仓库；
   当前仓库中的文件只是模板，不会自动发布到 tap。
5. 从发布地址重新下载并核对 SHA-256；用 Homebrew Cask 安装后验证 App 和
   `tbar` 两个入口。

任一步缺少可核对的 commit、tag、资产或 SHA-256 时停止，不用后续步骤的表象
反推前一步成功。
