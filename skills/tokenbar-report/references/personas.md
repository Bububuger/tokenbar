# personas.md — 6 个 persona 的总览

这是 v4 的 6-persona 架构。每个 persona 都是一个**独立的镜头**——看同一份数据
但只关心自己镜头能放大的东西。`_contract.md` 定义共享规则；这个文件给整体地图。

## 速查表

| Idx | Key | Chinese | Voice 一句话 | 3 个 signature section |
|---|---|---|---|---|
| 01 | `comic`     | 幽默风趣 | 把数字翻译成傻气的流行文化对照 | `pop_culture` / `hall_of_shame` / `trivia_card` |
| 02 | `brutalist` | 忠言逆耳 | 报丧式审判，只看坏账和依赖     | `stale_debt` / `dependence_index` / `repeat_offenders` |
| 03 | `terminal`  | 数据极客 | 干燥的 p99/σ/异常表             | `distribution_stats` / `hourly_heatmap` / `anomaly_log` |
| 04 | `essay`     | 哲学反思 | 凝视不在场的日子与未读的长文     | `negative_space` / `recurrence_diary` / `unread_conversation` |
| 05 | `ft`        | 财经评论员 | 资本视角谈持仓、集中度与盈亏     | `capital_allocation_table` / `concentration_metrics` / `monthly_pnl` |
| 06 | `jojo`      | 人性透视 | 替身评级 + 心理画像，唯一引用 prompt 原文 | `stand_stats` / `psyche_breakdown` / `stand_card` |

## 调用流程

1. 主对话先做 Step 5b 的 `personality_profile`（这是六个 persona 共享的 dossier）。
2. 主对话计算 `clusters` + Python derived。
3. 主对话**并行**启动 6 个 subagent，每个被指向：
   - `references/personas/_contract.md`（共享规则）
   - `references/personas/<key>.md`（个人 spec）
   - `/tmp/payload.json`（全量数据）
   - `/tmp/shared.json.python_derived["<key>"]`（专属预处理）
4. 每个 subagent 写出 `/tmp/tokenbar-report-personas/<key>.json`。
5. 主对话合并 → render.py → 6 个 HTML + 1 个抽卡首页。

## 关于"为什么是 6 个而不是 7 个"

v3 有 7 个，但 `sunrise`（鸡汤励志）和 `notebook`（老朋友闲聊）在生成对比中
被发现：
- `sunrise` 的"里程碑解锁 + 周增长 + 下个里程碑"和 `ft` 的"月度盈亏 + MoM"高度重叠，
  而且鼓励性叙事在六个里读起来最弱。
- `notebook` 的"项目传记 + 本周回顾"和 `essay` 的"项目循环"+`jojo` 的"心理画像"
  正面冲突，"老朋友"的温柔叙事更被 `jojo` 的临床观察压制。

v4 砍掉这两个，新增 `jojo` 这个"人性透视"——这是用户报告里唯一**会引用 prompt 原文、
唯一会评级、唯一做人格 trait 分析**的 persona，也是这份报告的"钩子"。

## 关于 "镜头隔离"

读 `_contract.md §2` 的 number ownership 表。简单版本：每个 persona 都有
2-3 个**只属于自己**的数字类别；其他 5 个不能动。这是 v4 相对 v3 最大的改变。
v3 把"哲学反思可以引用 σ"或者"comic 也可以做循环日记"这类松绑造成了内容重叠。
v4 把这类共享渠道关掉了。
