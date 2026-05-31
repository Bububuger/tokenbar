# Kimi Code — 验收文档

## Fixture
`Tests/TokenBarCoreTests/Fixtures/Kimi/0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d/wire.jsonl`
- 行数: 2(均为非全零 assistant turn)
- sessionId 取自目录 UUID `0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d`; project fallback = `kimi`

## 各 mock 行 RAW 输入 → EXPECTED 归一 6 元组
`inputIncludesCached = false`,各值原样保留; `total = input+output+cacheRead+cacheCreation+reasoning`。

| input_other | output | input_cache_read | input_cache_creation | → input | output | cacheRead | cacheCreation | reasoning | total |
|---|---|---|---|---|---|---|---|---|---|---|
| 1200 | 300 | 400 | 100 | 1200 | 300 | 400 | 100 | 0 | 2000 |
| 50 | 10 | 0 | 0 | 50 | 10 | 0 | 0 | 0 | 60 |

### 逐行推导(与 CONTRACT.md 一致)
- 行1: total = 1200 + 300 + 400 + 100 = **2000** ✓
- 行2: total = 50 + 10 + 0 + 0 = **60** ✓

## 如何跑测试
```
swift test --filter KimiUsageParserTests
```

## 验收标准
parser 读取 `wire.jsonl`,对 2 行各产出 1 个事件,归一 6 元组与上表一致;若存在全零行则不产出事件(本 fixture 无全零行,共 2 个事件)。
