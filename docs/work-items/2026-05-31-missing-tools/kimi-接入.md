# Kimi Code — 接入文档

## 来源与形态
- **形态**: declarative(通用 JSONL reader)。每行一个 assistant turn,token 字段扁平,无需结构化 SQL,走 declarative manifest + 通用 JSONL 解析路径。display 上按 CONTRACT 决策尝试以独立 AgentKind(`kimi`)标记;若 declarative 路径无法携带自定义 AgentKind,则回退 native(由 Subagent B 确认)。
- **canonical 路径**:
  `~/.kimi/sessions/**/wire.jsonl`

## 格式
JSONL,每行一个 assistant turn。token 字段扁平(flat),无嵌套 usage 对象。

## 字段口径 → 归一 6 元组映射
| 原始字段 (flat) | 归一 provider 入参 |
|---|---|
| `input_other` | input |
| `output` | output |
| `input_cache_read` | cacheRead |
| `input_cache_creation` | cacheCreation |
| (无) | reasoning = 0 |

## inputIncludesCached
**false**。`input_other` 即"不含缓存的 input",cache 字段独立,原样保留,不做 min-clamp。

## session / project
- sessionId 从路径 UUID 提取(本 fixture 目录名 = `0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d`)。
- project fallback = `"kimi"`。

## 跳过规则
所有 token 字段为 0 的行不产出事件(本 fixture 第 2 行非全零,仍产出)。

## 测试 fixture
- 路径(已提交): `Tests/TokenBarCoreTests/Fixtures/Kimi/0a1b2c3d-4e5f-6a7b-8c9d-0e1f2a3b4c5d/wire.jsonl`
- 内容: 2 个 assistant turn(均非全零)。
