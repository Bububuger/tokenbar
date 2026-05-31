# Antigravity — 验收文档

## Fixture
`Tests/TokenBarCoreTests/Fixtures/Antigravity/9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6/session.jsonl`
- 行数: 2(第 1 行非零,第 2 行全零 → 跳过)
- sessionId 取自目录 UUID `9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6`

## 各 mock 行 RAW 输入 → EXPECTED 归一 6 元组
`inputIncludesCached = false`,各值原样保留; `total = input+output+cacheRead+cacheCreation+reasoning`。

| input_tokens | output_tokens | cache_read_tokens | cache_write_tokens | → input | output | cacheRead | cacheCreation | reasoning | total |
|---|---|---|---|---|---|---|---|---|---|---|
| 800 | 120 | 60 | 40 | 800 | 120 | 60 | 40 | 0 | 1020 |
| 0 | 0 | 0 | 0 | (跳过 — 全零无事件) |

### 逐行推导(与 CONTRACT.md 一致)
- 行1: total = 800 + 120 + 60 + 40 = **1020** ✓
- 行2: 全零 → 跳过,无事件。

## 如何跑测试
```
swift test --filter AntigravityUsageParserTests
```

## 验收标准
parser 读取 `session.jsonl`,对第 1 行产出 1 个事件,归一 6 元组与上表一致;全零行(第 2 行)不产出事件(共 1 个事件)。
