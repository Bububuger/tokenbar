# dimensions.md — 报告维度 → tbar 查询 → 推导算法（v6）

> 每条维度告诉你：哪个 tbar 查询提供数据、在 `collect.sh` 里叫什么、在
> `payload.json` 哪个字段、谁的 lens 用它。v6 lineup 是 `jojo / bleach / hxh`。

## 1. 总量维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| total tokens | `summary --group-by day` 求和 | `timeline.byDay[].totalTokens` 求和 | hero 区共享（每个 persona 用题材语言重命名：jojo 不重命名 / bleach=灵压 / hxh=オーラ容量） |
| total prompts | `summary --group-by agent` 求和 | `agents[].promptCount` 求和 | hero 区共享（jojo / bleach=斩击数 / hxh=念発動回数） |
| total cost USD | apply_pricing.py 计算 | `cost.totalUSD` | hero 区共享（bleach=任务俸禄 / hxh=修业报酬） |
| event count | `schema` | `dataWindow.eventCount` | hero 区共享 |

## 2. 时间维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| 日 timeline | `timeline --bucket day` | `timeline.byDay[]` | jojo（破坏力 + 速度的 top day / median 比）/ bleach（出勤巡邏频次）/ hxh（念能力修业进度） |
| 时 timeline | `timeline --bucket hour-of-day` | `timeline.byHour[]` | jojo（速度维度 peak hour share）/ bleach + hxh 各自借用为题材表达 |
| day × hour | `summary --group-by day,hour-of-day` | `summary.byDayHour[]` | jojo（仪式型工作 trait） |

## 3. 实体维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| 模型表 | `models` | `models[]` | hero 共享（model 表格） |
| Agents | `agents` | `agents[]` | hero 共享（agent chart）/ jojo（射程） |
| 项目 | `projects` | `projects[]` | hero 共享（top 列表）/ jojo（射程）/ bleach（番队所辖）/ hxh（修业道场） |
| sources | `sources` | `sources[]` | 仅元数据，不进 lens |

## 4. Prompt 维度（jojo 独占引用原文）

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| prompt 抽样 | `prompts --limit N --sort timestamp:desc` | `prompts[]` | jojo（**唯一引用原文 + 动词频次表 + 重复簇**）/ bleach + hxh（仅可读 contentLength 等元数据，不引用原文） |
| prompt 总数 | 同上 | `promptsTotalCount` | jojo（session 模型） |

## 5. 推导维度（compute_python_derived.py 输出）

每个 persona 一个 key，对应 `python_derived.<key>` 字段。

### `jojo` ⭐
- `stand_stats` — 6 个维度的 grade（A-E）+ primary metric + secondary（射程额外有 nproj/nmodel/nagent）
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
- `stand_suggestion` — 默认从 S-tier 白名单挑出的一只替身（id / name_cn / name_jp / master / type / tier），subagent 可覆盖但**必须留在白名单内**

### `bleach`
- `reiatsu_stats` — 6 维 grades 的 bleach 化包装（同一 6 维数据 + 武士道命名）
- `axes` — 同一份 6 维信号（与 jojo 共用底层计算，但 grade 标签换成「队长級 / 副隊長級 / 席官級 / 准死神」等武士道阶位）
- `total_reiatsu` — total tokens 的灵压改名（仍是 hero 区共享数据）
- `zanpakuto_suggestion` — 默认从「真实斩魄刀白名单」挑出的一支（id / name_jp / name_cn / wielder / tier）。subagent 可覆盖，但必须留在白名单
- 番队路由 / 始解/卍解 staging 信号（subagent 用来写 narrative 段落，无固定字段名，由 spec 在 `references/personas/bleach.md` 决定）

### `hxh`
- `nen_assessment` — 6 维 grade 反推出的「水占い」结果：
  - `primary_type` — 主导念系（強化系 / 操作系 / 具現化系 / 放出系 / 変化系 / 特質系）
  - `secondary_type` — 次主导
  - 每系的 affinity 分数（0-100）
  - 等级标签（修业生 / 中級 / 上級 / 特級）
- `ability_type` — primary + secondary 复合的念能力分类（`{primary}・{secondary}複合` 或 `{primary}系`）
- `ability_design` —— **空槽**，由 subagent 现场创作 named ability + 制约と誓约（必须匹配 primary_type）
- `nen_progression` — 念能力修业时间线信号

> JOJO / BLEACH / HxH 三个 persona 共享同一份 6 维信号（compute_python_derived
> 内部叫 `axes`，由 `_compute_axes()` 计算）；不同的是每个 persona 用自己的
> vocabulary 包装、各自挑各自宇宙观里的旗舰资产（替身 / 斩魄刀 / 念系 + 自创能力）。

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

> 这是给 orchestrator 自己的内部 short tag，**不会**出现在最终报告里
> （v5 起就删除了共享 dossier 槽位）。每个 persona 在自己的 `identity_card`
> 里用题材语言重新叙述同一份 personality_profile。

## 16. personality_profile（深度档案，v5 起不再共享渲染）

6 个 sub-object 必填，schema 同 SKILL.md Step 5b。这是 3 个 persona 共享的
**raw data**，但 v5 起就删除了它的共享渲染槽位 —— 每个 persona 必须在自己的
`identity_card` 字段里用**自己题材的语言**重新叙述这些数据，不允许照搬
"mastery: senior" 之类的 raw 字段。

题材化身世模板示例：
- `jojo`   → "「ザ・ワールド」型替身使者档案 #X / 你的精神能量已经达到……"
- `bleach` → "▍護廷十三隊档案 · 隊員番号 NNNN / 所属：第 N 番隊 · 副隊長 / 灵压等级：……"
- `hxh`    → "▍念能力者の証 · ハンター協会登録 #NNNN / 主導系：……"

## 17. 镜头隔离硬标准（v6 仍沿用，3 persona 版本）

`scripts/measure_overlap.py` 在每次渲染后必须跑一次。它会：
1. 读 `01-jojo.html` / `02-bleach.html` / `03-hxh.html` 3 个文件
2. 剥掉 `<style>` / `<script>` / HTML 标签 / 数字 / 标点 / 渲染样板词
3. 把剩下的内容切成 3-char n-grams
4. 计算 3 个之间的 **3 对** Jaccard 相似度（C(3,2)=3，比 v5 的 15 对少很多）
5. 报告最大值 + 整张矩阵
6. **`< 0.30` 才能 exit 0**

3-pair setup 比 6-pair 更敏感 —— 单个泄漏词就会把 max 推上去。如果跑挂了，
意味着某两个 persona 借用了对方的题材语言。看哪一对，再 inspect 两个 HTML
的 narrative 部分找词汇泄漏，重派那两个 subagent。
