# Kiro CLI — 验收文档

## Fixture
`Tests/TokenBarCoreTests/Fixtures/Kiro/kiro-data.sqlite3`(由 `make-kiro-db.sh` 生成)。

已验证(`sqlite3` 实测):
- `conversations_v2` 行数: **1**
- `history` 数组长度: **5**(2 个 user + 3 个 assistant)
- assistant turn: k1=900/150/200/80, k2=300/60/0/0, k3=0/0/0/0

## 各 assistant turn RAW 输入 → EXPECTED 归一 6 元组
`inputIncludesCached = false`,各值原样保留; `total = input+output+cacheRead+cacheCreation+reasoning`。

| turn | input_tokens | output_tokens | cache_read_input_tokens | cache_creation_input_tokens | → input | output | cacheRead | cacheCreation | reasoning | total |
|---|---|---|---|---|---|---|---|---|---|---|
| k1 | 900 | 150 | 200 | 80 | 900 | 150 | 200 | 80 | 0 | 1330 |
| k2 | 300 | 60 | 0 | 0 | 300 | 60 | 0 | 0 | 0 | 360 |
| k3 | 0 | 0 | 0 | 0 | (跳过,全零无事件) |

### 逐行推导
- **k1**: total = 900 + 150 + 200 + 80 = **1330** ✓
- **k2**: total = 300 + 60 + 0 + 0 = **360** ✓
- **k3**: 全零 → 跳过,无事件。

> 注: CONTRACT.md 对 Kiro 未给定具体期望数值表(由 Subagent A 定义 JSON 形状与 mock 值),上述数值为本 fixture 的口径,Subagent B 的测试断言须与此表一致。inputIncludesCached=false 符合 CONTRACT "treat as false unless mock proves otherwise"。

## 如何跑测试
```
swift test --filter KiroUsageParserTests
```

## 验收标准
parser 读取 `kiro-data.sqlite3`,解析 `conversation` JSON 的 `history[]`,对 k1/k2 各产出 1 个事件,归一 6 元组与上表一致;全零 turn(k3)不产出事件(共 2 个事件)。
