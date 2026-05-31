#!/usr/bin/env bash
# Generates the Kiro CLI mock SQLite DB for KiroUsageParser tests.
# Mirrors the real on-disk schema subset:
#   ~/Library/Application Support/kiro-cli/data.sqlite3
# Table: conversations_v2(id, conversation TEXT(JSON), updated_at INTEGER).
#
# The `conversation` JSON shape (defined by this fixture; documented in
# kiro-接入.md) is an object with a "history" array. Each assistant turn is
# an object with role "assistant" and a "usage" object carrying:
#   { "input_tokens", "output_tokens",
#     "cache_read_input_tokens", "cache_creation_input_tokens" }
# Cache tokens are reported separately from input (Anthropic-style split),
# so inputIncludesCached = false.
#
# Usage: ./make-kiro-db.sh   (writes ./kiro-data.sqlite3 next to this script)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="$DIR/kiro-data.sqlite3"
rm -f "$DB"

# conversation JSON for the single mock conversation: 2 non-zero assistant
# turns (k1, k2) + 1 zero-usage assistant turn (k3, must be skipped).
CONV='{"conversation_id":"33333333-dddd-eeee-ffff-444444444444","model":"claude-sonnet-4.5","history":[{"role":"user","content":"build the parser"},{"role":"assistant","content":"k1","usage":{"input_tokens":900,"output_tokens":150,"cache_read_input_tokens":200,"cache_creation_input_tokens":80}},{"role":"user","content":"now add tests"},{"role":"assistant","content":"k2","usage":{"input_tokens":300,"output_tokens":60,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},{"role":"assistant","content":"k3","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}]}'

sqlite3 "$DB" <<SQL
CREATE TABLE conversations_v2 (
  id           TEXT,
  conversation TEXT,
  updated_at   INTEGER
);
INSERT INTO conversations_v2 (id, conversation, updated_at) VALUES (
  '33333333-dddd-eeee-ffff-444444444444',
  '$CONV',
  1748600100000);
SQL

echo "Wrote $DB"
