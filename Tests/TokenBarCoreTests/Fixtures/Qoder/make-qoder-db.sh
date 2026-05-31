#!/usr/bin/env bash
# Generates the Qoder Desktop mock SQLite DB for QoderUsageParser tests.
# Mirrors the real on-disk schema subset:
#   ~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db
# Tables: chat_session(session_id, workspace), chat_message(id, session_id,
#         request_id, role, token_info JSON, model_info JSON, gmt_create).
# Rows match docs CONTRACT.md Qoder table (m1/m2/m3 + 1 empty-token_info row).
#
# Usage: ./make-qoder-db.sh   (writes ./qoder-local.db next to this script)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="$DIR/qoder-local.db"
rm -f "$DB"

sqlite3 "$DB" <<'SQL'
CREATE TABLE chat_session (
  session_id TEXT,
  workspace  TEXT
);
CREATE TABLE chat_message (
  id          TEXT,
  session_id  TEXT,
  request_id  TEXT,
  role        TEXT,
  token_info  TEXT,
  model_info  TEXT,
  gmt_create  INTEGER
);

INSERT INTO chat_session (session_id, workspace) VALUES
  ('11111111-aaaa-bbbb-cccc-222222222222', '/Users/dev/workspace/demo-app');

-- m1: prompt 21512, completion 87, cached 15104, claude-sonnet-4.5
INSERT INTO chat_message VALUES (
  'm1', '11111111-aaaa-bbbb-cccc-222222222222', 'req-m1', 'assistant',
  '{"prompt_tokens":21512,"completion_tokens":87,"cached_tokens":15104}',
  '{"model":"claude-sonnet-4.5"}',
  1748600000000);

-- m2: prompt 1000, completion 200, cached 0, gpt-5
INSERT INTO chat_message VALUES (
  'm2', '11111111-aaaa-bbbb-cccc-222222222222', 'req-m2', 'assistant',
  '{"prompt_tokens":1000,"completion_tokens":200,"cached_tokens":0}',
  '{"model":"gpt-5"}',
  1748600001000);

-- m3: prompt 500, completion 50, cached 800 (cached>prompt -> min clamp), gpt-5
INSERT INTO chat_message VALUES (
  'm3', '11111111-aaaa-bbbb-cccc-222222222222', 'req-m3', 'assistant',
  '{"prompt_tokens":500,"completion_tokens":50,"cached_tokens":800}',
  '{"model":"gpt-5"}',
  1748600002000);

-- m4: empty token_info -> parser must skip (0 events)
INSERT INTO chat_message VALUES (
  'm4', '11111111-aaaa-bbbb-cccc-222222222222', 'req-m4', 'assistant',
  '',
  '{"model":"gpt-5"}',
  1748600003000);
SQL

echo "Wrote $DB"
