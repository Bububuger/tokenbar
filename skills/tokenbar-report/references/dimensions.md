# dimensions.md — 报告维度 → tbar 查询 → 推导算法（v5）

> 每条维度告诉你：哪个 tbar 查询提供数据、在 `collect.sh` 里叫什么、在
> `payload.json` 哪个字段、谁的 lens 用它。

## 1. 总量维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| total tokens | `summary --group-by day` 求和 | `timeline.byDay[].totalTokens` 求和 | hero 区共享（每个 persona 用题材语言重命名） |
| total prompts | `summary --group-by agent` 求和 | `agents[].promptCount` 求和 | hero 区共享 |
| total cost USD | apply_pricing.py 计算 | `cost.totalUSD` | hero 区共享 |
| event count | `schema` | `dataWindow.eventCount` | hero 区共享 |

## 2. 时间维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| 日 timeline | `timeline --bucket day` | `timeline.byDay[]` | xiuxian（渡劫日）/ wuxia（大事日）/ santi（civ span）/ shuihu（大事记）/ talk（翻车日）/ jojo（破坏力 + 速度） |
| 时 timeline | `timeline --bucket hour-of-day` | `timeline.byHour[]` | xiuxian（日精/月华时辰）/ jojo（速度维度） |
| day × hour | `summary --group-by day,hour-of-day` | `summary.byDayHour[]` | jojo（仪式型工作 trait） |

## 3. 实体维度

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| 模型表 | `models` | `models[]` | hero 共享（model 表格）/ shuihu（108 排位之一） |
| Agents | `agents` | `agents[]` | hero 共享（agent chart）/ shuihu（108 排位之一）/ jojo（射程） |
| 项目 | `projects` | `projects[]` | hero 共享（top 列表）/ xiuxian（洞府）/ wuxia（门派）/ santi（暴露 vs 隐匿坐标）/ shuihu（108 排位主力）/ talk（翻车现场素材）/ jojo（射程） |
| sources | `sources` | `sources[]` | 仅元数据，不进 lens |

## 4. Prompt 维度（jojo 重要）

| 项 | 来源 | payload 字段 | 谁的 lens |
|---|---|---|---|
| prompt 抽样 | `prompts --limit N --sort timestamp:desc` | `prompts[]` | jojo（**唯一引用原文 + 动词 + 重复簇**）/ wuxia, santi, talk（拿 verb signal 但不引用原文） |
| prompt 总数 | 同上 | `promptsTotalCount` | jojo（session 模型） |

## 5. 推导维度（compute_python_derived.py 输出）

每个 persona 一个 key，对应 `python_derived.<key>` 字段：

### `xiuxian` — 仙路修真录
- `current_realm` / `current_realm_en` — 按总 tokens 落到 9 档境界
- `next_realm` / `next_realm_distance_tokens` — 下一档 + 距离
- `total_qi_compact` / `total_breaths` — 灵气总量 / 吐纳次数
- `peak_hour` / `peak_shichen` — 日精时辰
- `valley_hour` / `valley_shichen` — 月华时辰
- `longest_meditation_days` — 最长连续入定日数（streak）
- `tribulations_raw` — z-score ≥ 2.0 的渡劫候选日

### `wuxia` — 江湖列传
- `schools` — projects 按 token 排序的"门派录"
- `school_count` / `main_school` — 总门派数 + 总舵
- `move_signals` — verb cluster 计数（destruction_rewriting / querying / fixing / exploring）
- `longest_meditation_days` — 最长 streak（武侠用"内功 N 日不辍"）
- `big_days` — z-score ≥ 2.0 的"江湖大事"候选日

### `santi` — 黑暗森林档案
- `civilization_type` / `civilization_label` — Kardashev type 映射
- `total_broadcast_strength` / `broadcast_count` — 文明能级 / 广播次数
- `exposed_coordinates` — share ≥ 10% 的高暴露项目
- `concealed_coordinates` — 低活跃但非零的隐匿项目
- `civilization_span_days` / `first_broadcast_date` — 文明跨度
- `seal_signals` — 5 类 verb cluster 计数（restart / query / fix / explore / destruction）

### `shuihu` — 梁山泊聚义录
- `tiers` — 4 档分级的 108 排位（tiangang_zheng/fu/dishai/dishai_mo）
- `total_chieftains` — projects + models + agents 合并后的座次总数
- `total_household` / `gathering_count` — 内力家底 / 聚义次数
- `big_event_days` — z-score ≥ 2.0 的"聚义大事"候选日

### `talk` — 脱口秀
- `total_material` / `stage_appearances` — 段子库存 / 上台次数
- `callback_signals` — 5 类 verb cluster（供 callback 梗命名）
- `near_duplicate_clusters` — 近似重复 prompt 簇（仅 count + first/last seen，不引用原文）
- `bombings` — 弃置 > 60 天的"翻车"项目 top 5
- `total_bomb_count` — 翻车总数

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
- `stand_suggestion` ⭐ — 默认从 S-tier 白名单挑出的一只替身（id / name_cn / name_jp / master / type / tier），subagent 可覆盖但**必须留在白名单内**

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

## 16. personality_profile（深度档案，v5 不再共享渲染）

6 个 sub-object 必填，schema 同 SKILL.md Step 5b。这是 6 个 persona 共享的
**raw data**，但 v5 删除了它的共享渲染槽位 —— 每个 persona 必须在自己的
`identity_card` 字段里用**自己题材的语言**重新叙述这些数据，不允许照搬
"mastery: senior" 之类的 raw 字段。

题材化身世模板示例：
- `xiuxian` → "道友自 X 入道，至今 Y 日，灵气总量 Z……"
- `wuxia` → "江湖人称……，自 X 出道，纵横江湖 Y 日……"
- `santi` → "▍档案 #PDC-X · 已解密 / 目标个体：…… / 文明等级：……"
- `shuihu` → "▍梁山泊水寨头领档案 · 第 N 位天罡正星 / 江湖人称……"
- `talk` → "大家好，我叫……。我在这行——就是 AI 编程这行——干了 X 天。……"
- `jojo` → "「ザ・ワールド」型替身使者档案 #X / 你的精神能量已经达到……"

## 17. 镜头隔离硬标准（v5 新增）

`scripts/measure_overlap.py` 在每次渲染后必须跑一次。它会：
1. 读 `01-xiuxian.html` 到 `06-jojo.html` 6 个文件
2. 剥掉 `<style>` / `<script>` / HTML 标签 / 数字 / 标点 / 渲染样板词
3. 把剩下的内容切成 3-char n-grams
4. 计算 6 个之间的 15 对 Jaccard 相似度
5. 报告最大值 + 整张矩阵
6. **`< 0.30` 才能 exit 0**

如果跑挂了，意味着某两个 persona 借用了对方的题材语言。看哪一对，再 inspect
两个 HTML 的 narrative 部分找词汇泄漏，重派那两个 subagent。
