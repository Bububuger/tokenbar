# Antigravity — 接入文档

## 来源与形态
- **形态**: declarative(通用 JSONL reader)。每行一个 assistant turn,token 字段扁平(多 alias),走 declarative manifest + 通用 JSONL 解析路径。display 上按 CONTRACT 决策尝试以独立 AgentKind(`antigravity`)标记;若 declarative 路径无法携带自定义 AgentKind,则回退 native(由 Subagent B 确认)。
- **canonical 路径**(递归扫 `*.jsonl`):
  - `~/.gemini/antigravity/**/*.jsonl`
  - `~/Library/Application Support/Antigravity/**`

## 格式
JSONL,每行一个 assistant turn。token 字段扁平,且兼容多 alias。

## 字段口径 → 归一 6 元组映射
本 fixture 使用 canonical 别名 `input_tokens / output_tokens / cache_read_tokens / cache_write_tokens`。parser 应兼容以下 alias 组(来自调研 4.5):

| 归一入参 | 兼容 alias |
|---|---|
| input | `inputTokens` / `input_tokens` / `promptTokens` / `prompt_tokens` |
| output | `outputTokens` / `output_tokens` |
| cacheRead | `cacheReadTokens` / `cache_read_tokens` |
| cacheCreation | `cacheWriteTokens` / `cache_write_tokens` |
| reasoning | `reasoningTokens` / `reasoning_tokens`(本 fixture 不带,= 0) |

## inputIncludesCached
**false**。各值原样保留,不做 min-clamp。

## session
sessionId 取自路径 segment(最后含 UUID 的目录名,本 fixture = `9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6`);fallback `sha1(filePath)[:16]`。

## 跳过规则
所有 token 字段为 0 的行不产出事件(本 fixture 第 2 行全零 → 跳过)。

## 测试 fixture
- 路径(已提交): `Tests/TokenBarCoreTests/Fixtures/Antigravity/9f8e7d6c-5b4a-3c2d-1e0f-a1b2c3d4e5f6/session.jsonl`
- 内容: 2 个 assistant turn —— 第 1 行非零,第 2 行全零(应跳过)。
