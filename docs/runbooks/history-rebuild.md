# TokenBar history rebuild runbook

> `tbar rebuild` 是 CLI 唯一写入本地索引的命令，等价于 App 的
> “Reparse all”。它重建 SQLite 索引，不修改上游 agent 日志。

## 何时使用

- 首次索引历史数据；
- parser 或 source 规则变化后重算；
- Diagnostics 显示索引不完整；
- 需要验证全历史重建的资源占用、warning 或 source 可读性。

普通查询不要先 rebuild；优先直接运行只读的 `tbar summary`、`events`、
`sources`、`checkpoints` 或 `warnings`。

## 执行前

1. 记录当前数据库路径、只读 summary、source 状态和最近 checkpoint。
2. 确认磁盘空间足够，且没有另一个 App/CLI rebuild 正在运行。
3. 大历史量默认使用后台限流；不要通过删 SQLite 或直接改表来“修复”索引。
4. 验证性重建可用 `--db <path>` 指向任务专用数据库，避免覆盖日常索引。

## 推荐命令

```bash
tbar rebuild --background --json
```

需要明确 CPU 预算时：

```bash
tbar rebuild --cpu-percent 25 --json
```

`--cpu-percent` 只接受 1–100；设置它会启用资源限流。完整参数以
`tbar rebuild --help` 和 `tbar schema --json` 的当前输出为准。

## 验收

保存 JSON 输出并核对：

- `sourceWindow` 为 `all-history`；
- `rebuildError` 为空；
- 每个预期 source 的 `isReadable` 与 `discoveredFileCount` 合理；
- `eventCount`、`promptCount`、token 分项和 `warningCount` 没有异常归零；
- checkpoint 的新增事件/提示数量与本次变化相符；
- 后续 `tbar summary --days 30`、`tbar checkpoints` 和 `tbar warnings`
  能读取同一数据库。

命令退出成功但 source 不可读、计数异常归零或 `rebuildError` 非空，都不能算
重建成功。保留执行前后 JSON 和数据库路径；任务专用数据库在证据收口后按精确
路径清理，不触碰默认索引或上游日志。
