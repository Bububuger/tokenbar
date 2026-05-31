# Kiro CLI — 接入文档

## 来源与形态
- **形态**: native(SQLite 直读)。Kiro CLI 把整段会话(含每个 assistant turn 的 usage)序列化为 JSON 存进 SQLite,token 口径结构化、稳定,适合 native parser/DataSource。
- **canonical 路径**:
  `~/Library/Application Support/kiro-cli/data.sqlite3`
  (Linux: `$XDG_DATA_HOME/kiro-cli/data.sqlite3`)

## 数据库 schema
- `conversations_v2(id TEXT, conversation TEXT, updated_at INTEGER)`
  - `conversation` 是一段 JSON(单条会话的完整历史)。
  - `updated_at` 用于增量(`lastMaxUpdatedAt`),本测试不依赖。

## `conversation` JSON 形状(本 fixture 定义,parser 据此解析)
```json
{
  "conversation_id": "33333333-dddd-eeee-ffff-444444444444",
  "model": "claude-sonnet-4.5",
  "history": [
    { "role": "user", "content": "..." },
    { "role": "assistant", "content": "k1",
      "usage": {
        "input_tokens": 900,
        "output_tokens": 150,
        "cache_read_input_tokens": 200,
        "cache_creation_input_tokens": 80
      }
    },
    ...
  ]
}
```
- 解析路径: `history[]` 中所有 `role == "assistant"` 且带 `usage` 对象的 turn。
- `model` 取顶层 `conversation.model`(fixture 中为 `claude-sonnet-4.5`)。
- session 标识取 `conversation_id`(= `conversations_v2.id`)。

## 字段口径 → 归一 6 元组映射
| 原始字段 (usage JSON) | 归一 provider 入参 |
|---|---|
| `input_tokens` | input |
| `output_tokens` | output |
| `cache_read_input_tokens` | cacheRead |
| `cache_creation_input_tokens` | cacheCreation |
| (无) | reasoning = 0 |

## inputIncludesCached
**false**。cache_read / cache_creation 与 input 分列上报(Anthropic-style 已分离),原样保留,不做 min-clamp。

## 跳过规则
所有 usage 字段都为 0(或 turn 无 `usage`)的 assistant turn 不产出事件。

## 测试 fixture
- 生成脚本(已提交): `Tests/TokenBarCoreTests/Fixtures/Kiro/make-kiro-db.sh`
- 产物(已生成并提交): `Tests/TokenBarCoreTests/Fixtures/Kiro/kiro-data.sqlite3`
- 内容: 1 条 `conversations_v2` 记录,`history` 含 3 个 assistant turn —— k1/k2 非零、k3 全零(应跳过)。

重新生成: `bash Tests/TokenBarCoreTests/Fixtures/Kiro/make-kiro-db.sh`
