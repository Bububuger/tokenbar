# personas.md — 3 个 persona 的总览（v6）

v6 把 lineup 收紧到 3 个，全部是「anime 力量系统 + iconic named asset
matched flatteringly to user stats」这个 JOJO 开创的架构。

## 速查表

| Idx | Key | 显示名 | Voice 一句话 | 3 个 signature section |
|---|---|---|---|---|
| 01 | `jojo`   | JOJO   | 替身 + 心理画像 + 真实 JOJO S 级替身 | `stand_stats` / `psyche_breakdown` / `stand_card` |
| 02 | `bleach` | 死神   | 斩魄刀 + 始解 + 卍解 + 护廷十三队 | `reiatsu_stats` / `psyche_breakdown` / `zanpakuto_card` |
| 03 | `hxh`    | 猎人   | 念能力 + 六系 + 自创 named ability + 制约与誓约 | `nen_assessment` / `ability_design` / `nen_progression` |

## 核心架构 / Why this trio

三个 persona 都共享同一个抽象：**用户的使用数据反推出 6 维评级 → 这 6 维
匹配一个真实存在于该作品宇宙观里的"iconic asset"**。每个 persona 对该
6 维有不同的 vocabulary 包装，匹配出不同 universe 里的旗舰 asset：

- **JOJO** 6 维 → S 级替身（ザ・ワールド / スタープラチナ / GER / MIH / etc.）
- **死神** 6 维 → S/A 级斩魄刀（千本桜景厳 / 天鎖斬月 / 流刃若火 / etc.）
- **HxH** 6 维 → 主导念系 + 自创 named 念能力（強化系/操作系/etc.）

## 调用流程

1. 主对话计算 Python derived（compute_python_derived.py 包含 jojo +
   bleach + hxh 三个 bundle）。
2. 主对话**并行**启动 3 个 subagent，每个被指向：
   - `references/personas/_contract.md`
   - `references/personas/<key>.md`
   - `/tmp/payload.json`
   - `/tmp/shared.json.python_derived["<key>"]`
3. 每个 subagent 写出 `/tmp/tokenbar-report-personas/<key>.json`。
4. 主对话合并 → render.py → 3 个 HTML + 1 个抽卡首页。
5. 跑 `scripts/measure_overlap.py <output_dir>` —— 由于 3 个 persona 都
   是 anime 风格但 vocabulary 独占，目标重合度仍 < 0.30。

## 视觉中心 / Signature Visual

3 个 persona 都用 base64 嵌入 PNG 当 signature visual（保持离线可看）：
- JOJO: 抽到的替身真身（默认 ザ・ワールド = `assets/stands/tw.png`）
- 死神: 斩魄刀的 wielder portrait（默认 千本桜景厳 = `assets/zanpakuto/senbonzakura.png`）
- HxH: 念能力六系六芒星图 + 主导 nen type 的代表能力 portrait（默认强化系 = `assets/nen/enhancement.png`）

Renderer 按 picker 选中的 asset id 查 `assets/<dir>/<id>.png/.webp/.jpg`；
找不到则 fall back 到几何 glyph。

## Lens-isolation 评测

`scripts/measure_overlap.py` 在每次渲染后必须跑。max pairwise Jaccard < 0.30
才算合格。3-persona setup 中 anime vocab 之间的重合（"漫画" / "番队" / "念" 等）
依然要满足这个阈值。
