# TokenBar history rebuild runbook

> `tbar rebuild` 是 CLI 显式触发用量索引全量重建的命令，对应 App 的
> “Reparse all”。它重建 SQLite 中的本地日志索引，不修改上游 agent 日志。

## 何时使用

- 首次索引历史数据；
- parser 或 source 规则变化后重算；
- Diagnostics 显示索引不完整；
- 需要验证全历史重建的资源占用、warning 或 source 可读性。

普通查询不要先 rebuild；优先直接运行 `tbar summary`、`events`、
`sources`、`checkpoints` 或 `warnings`。这些命令不重新解析日志，但打开数据库时
仍可能创建数据库或执行 schema migration，并非文件系统层面的只读访问。

CLI 重建扫描全部内置本地数据源，以及所选数据库中已启用的 custom sources。
它保留已有的 Cursor 远端用量快照、自定义源配置和 saved prompts；不会发起 Cursor
账号同步，也不会刷新 Library 的 skills、MCP 或 plugins 快照。

## 执行前

1. 记录当前数据库路径、summary、source 状态和最近 checkpoint。默认数据库为
   `~/Library/Application Support/TokenBar/tokenbar.sqlite`。
2. 确认磁盘空间足够；退出使用同一数据库的 App，避免自动刷新与 CLI 重建同时写入，
   并确认没有另一个 CLI rebuild 正在运行。
3. 大历史量默认使用后台限流；不要通过删 SQLite 或直接改表来“修复”索引。
4. 验证性重建可用 `--db <path>` 指向任务专用数据库，避免覆盖日常索引。
   全新数据库没有日常索引中的 custom sources 配置或 Cursor 远端快照，计数不能直接
   与日常库等同。`--db` 只切换输出数据库，不会隔离或替换上游日志路径。
5. 重建会先清空可从本地重解析的用量事件、采集的 prompts、watermarks、warnings
   和 checkpoints，再重新扫描。已从上游删除的历史无法靠重建恢复；需要保留时，
   先在所有写入进程退出后备份数据库。

## 推荐命令

```bash
tbar rebuild --background --json
```

从源码检出目录运行时，可把 `tbar` 替换为 `script/tbar`（通过 SwiftPM 构建并运行）。
`--background` 降低进程优先级并采用当前默认 3% 的协作式限流预算；它仍在前台运行，
不是后台任务启动器。预算是工作/休眠比例估算，不是操作系统保证的 CPU 上限。

需要明确 CPU 预算时：

```bash
tbar rebuild --cpu-percent 25 --json
```

`--cpu-percent` 只接受 1–100；设置它会启用资源限流。完整参数以
`tbar rebuild --help` 和 `tbar schema --json` 的当前输出为准。

任务专用数据库的重建与查询必须使用同一路径，例如：

```bash
# DB 必须是已确认的任务专用路径；不要在这里填入日常数据库。
DB="/path/to/task/tokenbar.sqlite"
tbar rebuild --db "$DB" --background --json
tbar summary --db "$DB" --days 30 --json
tbar checkpoints --db "$DB" --json
tbar warnings --db "$DB" --json
```

## 验收

保存 JSON 输出并核对：

- `sourceWindow` 为 `all-history`；
- `rebuildError` 为空；
- 每个预期 source 的 `isReadable` 与 `discoveredFileCount` 合理；
- `eventCount`、`promptCount`、token 分项和 `warningCount` 没有异常归零；
- checkpoint 的新增事件/提示数量与全量重导入相符（不是相对重建前数据库的增量）；
- 后续 `tbar summary --days 30`、`tbar checkpoints` 和 `tbar warnings`
  能读取同一数据库。

命令退出成功但 source 不可读、计数异常归零或 `rebuildError` 非空，都不能算
重建成功。保留执行前后 JSON 和数据库路径；任务专用数据库在证据收口后按精确
路径清理，不触碰默认索引或上游日志。
