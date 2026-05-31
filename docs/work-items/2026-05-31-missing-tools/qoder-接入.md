# Qoder Desktop — 接入文档

## 来源与形态
- **形态**: native（SQLite 直读）。Qoder Desktop 把 token 用量结构化写在本地 SQLite 库的 `chat_message.token_info` JSON 里,字段口径稳定、可直接 SQL 取,因此走 native parser/DataSource,而非通用 declarative JSONL 路径。
- **canonical 路径**:
  `~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db`

## 数据库 schema(测试用最小子集,与真实库一致)
- `chat_session(session_id TEXT, workspace TEXT)`
- `chat_message(id TEXT, session_id TEXT, request_id TEXT, role TEXT, token_info TEXT, model_info TEXT, gmt_create INTEGER)`

真实读取 SQL(来自调研 4.4 / `qoder-desktop-token-reader.js`):
```sql
SELECT ... FROM chat_message m
LEFT JOIN chat_session s ON m.session_id = s.session_id
```

## 字段口径 → 归一 6 元组映射
`token_info` 是一段 JSON: `{"prompt_tokens":N,"completion_tokens":N,"cached_tokens":N,...}`

| 原始字段 (token_info JSON) | 归一 provider 入参 |
|---|---|
| `prompt_tokens` | input |
| `completion_tokens` | output |
| `cached_tokens` | cacheRead |
| (无) | cacheCreation = 0 |
| (无) | reasoning = 0 |

model 解析优先级(来自 `model_info` JSON): `model` → `model_key` → `preferred_model_info.preferred_model`。

## inputIncludesCached
**true**(OpenAI/Anthropic-style: `prompt_tokens` 已把 cache_read 算进去了)。
归一时执行: `clampedCached = min(cached, input)`,`input -= clampedCached`,`cacheRead = clampedCached`。

## 跳过规则
`token_info` 为空字符串(或无法解析为含 token 字段的 JSON)的行不产出事件。

## 测试 fixture
- 生成脚本(已提交): `Tests/TokenBarCoreTests/Fixtures/Qoder/make-qoder-db.sh`
- 产物(已生成并提交): `Tests/TokenBarCoreTests/Fixtures/Qoder/qoder-local.db`
- 内容: 3 条有效 `chat_message`(m1/m2/m3)+ 1 条空 `token_info`(m4,应跳过),均挂在同一 `chat_session`(workspace=`/Users/dev/workspace/demo-app`)下。

重新生成: `bash Tests/TokenBarCoreTests/Fixtures/Qoder/make-qoder-db.sh`
