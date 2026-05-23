# dimensions.md — 报告维度 → tbar 查询 → 推导算法

> 这是 v3 → v4 的统一引用书。每条维度告诉你：哪个 tbar 查询提供数据、
> 在 `collect.sh` 里叫什么、在 `payload.json` 哪个字段、谁的 lens 用它。

## 1. 总量维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| total tokens | `summary --group-by day` 求和 | `timeline.byDay[].totalTokens` 求和 | hero 区共享 |
| total prompts | `summary --group-by agent` 求和 | `agents[].promptCount` 求和 | hero 区共享 |
| total cost USD | apply_pricing.py 计算 | `cost.totalUSD` | hero 区共享 |
| event count | `schema` | `dataWindow.eventCount` | hero 区共享 |

## 2. 时间维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| 日 timeline | `timeline --bucket day` | `timeline.byDay[]` | comic（heaviest）/ terminal（分布）/ essay（不在场）/ ft（每月聚合）/ jojo（破坏力 + 速度） |
| 时 timeline | `timeline --bucket hour-of-day` | `timeline.byHour[]` | terminal（heatmap）/ jojo（速度维度） |
| day × hour | `summary --group-by day,hour-of-day` | `summary.byDayHour[]` | terminal（heatmap）/ jojo（仪式型工作 trait） |

## 3. 实体维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| 模型表 | `models` | `models[]` | hero 共享（model 表格）/ brutalist（依赖）/ ft（HHI） |
| Agents | `agents` | `agents[]` | hero 共享（agent chart）/ brutalist（依赖）/ jojo（射程） |
| 项目 | `projects` | `projects[]` | hero 共享（top 列表）/ brutalist（陈债）/ essay（弃置）/ ft（持仓）/ jojo（射程） |
| sources | `sources` | `sources[]` | 仅元数据，不进 lens |

## 4. Prompt 维度（jojo 重要）

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| prompt 抽样 | `prompts --limit N --sort timestamp:desc` | `prompts[]` | comic（笨问题）/ essay（长 prompt 数字）/ jojo（**原文引用 + 动词 + 重复簇**） |
| prompt 总数 | 同上 | `promptsTotalCount` | jojo（session 模型） |

## 5. 推导维度（compute_python_derived.py 输出）

每个 persona 一个 key，对应 `python_derived.<key>` 字段：

### `comic`
- `first_prompt` — 最早一条 prompt 的 timestamp + weekday
- `longest_prompt` — 最长一条 prompt 的字符数 + 项目
- `quietest_hour` — 在 timeline.byHour 里 totalTokens 最低的非零小时

### `brutalist`
- `stale_projects` — projects 中 lastSeen ≥ 14d 前的列表（带 days_idle / status 分级）
- `dependence` — top 1 model / agent / project 的 share 百分比 + long-tail count

### `terminal`
- `distribution_stats` — daily_tokens / daily_prompts / content_length 的 p50/p90/p99/σ/max/mean
- `hourly_heatmap` — 7×24 grid + peak_cell + deadzone
- `anomalies` — |z| ≥ 3 的日子（top 8）

### `essay`
- `negative_space.inactive_days` — 窗口内无活动日（前 20）
- `negative_space.weekday_gaps` — 每个 weekday 的缺席计数
- `negative_space.stalled_projects` — 弃置 > 30 天的项目
- `long_prompts` — long_prompt_pct / avg_long_chars / longest_chars

### `ft`
- `capital_allocation` — top 10 项目的 tokens / cost / weight_pct
- `herfindahl` — projects / models / agents 三轴 HHI + 四档分级
- `monthly_pnl` — 每月 tokens / cost / mom_delta_pct

### `jojo` ⭐ (新增)
- `stand_stats` — 6 个维度的 grade（A-E）+ primary metric
- `prompt_intel.short_prompt_pct` — < 200 字符 prompt 占比
- `prompt_intel.long_prompt_pct` — > 5000 字符 prompt 占比
- `prompt_intel.ultra_long_prompts` — top 5 ≥ 5000 字符 prompt 摘要（含 200 字符 excerpt）
- `prompt_intel.near_duplicate_clusters` — 重复 prompt 簇（首末出现 + samples）
- `prompt_intel.verb_frequency` — 中英文动词频次表
- `prompt_intel.first/last_prompts_each_day` — 每日首/末 prompt 抽样
- `prompt_intel.session_stats` — session 数 / 平均 / 最大 prompt 数
- `behavioral_extremes.first/last_active_hour` — 数据窗口里出现过的极端时段
- `behavioral_extremes.weekday_consistency` — 周内分布的 cv（越低越仪式化）
- `behavioral_extremes.weekend_intensity` — 周末 token 占比

## 14. Cluster 命名约定

主对话在 Step 4 给 prompts 聚类。可用类别：

- `bug-fix` — 「为什么 X 不工作 / 报错 Y」
- `refactor` — 「能不能改成 / 重写 / 调整」
- `new-feature` — 「实现 / 加上 / 新建」
- `explore-explain` — 「解释一下 / 这是什么意思 / 看下」
- `learn-research` — 「X 和 Y 的区别 / 学习」
- `design-architecture` — 「设计 / 架构 / 选型」
- `ops-deploy` — 「部署 / 上线 / 配置」
- `data-query` — 「查一下 / 拿到 / SQL / 数据」

可以发明新类别，但每个类别名 ≤ 24 字符。

## 15. 短人格 tag 示例

4-8 字中文：深夜重构师 / 谨慎实验家 / 项目纵火犯 / 周末码农 / 多线程作业员

## 16. personality_profile（深度档案）

6 个 sub-object 必填，schema 同 SKILL.md Step 5b。这是 6 个 persona 共享的
dossier，每个 persona 在 `profile_narrative` 字段加 1-2 句自己镜头的评论即可，
不要重复 dossier 里的数字。
