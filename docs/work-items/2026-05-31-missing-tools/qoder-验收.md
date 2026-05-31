# Qoder Desktop — 验收文档

## Fixture
`Tests/TokenBarCoreTests/Fixtures/Qoder/qoder-local.db`(由 `make-qoder-db.sh` 生成)。

已验证的行数(`sqlite3` 实测):
- `chat_message` 总行数: **4**
- 非空 `token_info` 行数: **3**
- m4 的 `token_info` = `''`(空字符串,model_info 仍为 gpt-5,但应跳过)

## 各 mock 行 RAW 输入 → EXPECTED 归一 6 元组
`inputIncludesCached = true`,归一规则: `clampedCached=min(cached,input)`; `input -= clampedCached`; `cacheRead=clampedCached`; `total = input+output+cacheRead+cacheCreation+reasoning`。

| id | prompt (RAW input) | completion (output) | cached (RAW) | model | → input | output | cacheRead | cacheCreation | reasoning | total |
|---|---|---|---|---|---|---|---|---|---|---|
| m1 | 21512 | 87 | 15104 | claude-sonnet-4.5 | 6408 | 87 | 15104 | 0 | 0 | 21599 |
| m2 | 1000 | 200 | 0 | gpt-5 | 1000 | 200 | 0 | 0 | 0 | 1200 |
| m3 | 500 | 50 | 800 | gpt-5 | 0 | 50 | 500 | 0 | 0 | 550 |
| m4 | — (empty token_info) | — | — | gpt-5 | (跳过,无事件) |

### 逐行重新推导(独立复核,与 CONTRACT.md 一致)
- **m1**: clampedCached = min(15104, 21512) = 15104; input = 21512 − 15104 = **6408**; cacheRead = **15104**; output = **87**; total = 6408 + 87 + 15104 + 0 + 0 = **21599** ✓
- **m2**: clampedCached = min(0, 1000) = 0; input = 1000 − 0 = **1000**; cacheRead = **0**; output = **200**; total = 1000 + 200 = **1200** ✓
- **m3**(min-clamp 用例): clampedCached = min(800, 500) = **500**; input = 500 − 500 = **0**; cacheRead = **500**; output = **50**; total = 0 + 50 + 500 = **550** ✓
- **m4**: token_info 为空 → 跳过,不产出事件。

## 如何跑测试
```
swift test --filter QoderUsageParserTests
```

## 验收标准
parser 读取 `qoder-local.db` 后,对 m1/m2/m3 各产出 1 个事件,且归一 6 元组与上表完全一致(尤其 m3 的 `min(cached,input)` 截断 → input 0 / cacheRead 500);空 `token_info` 行(m4)不产出任何事件(共 3 个事件)。
