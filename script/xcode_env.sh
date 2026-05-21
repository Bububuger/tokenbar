#!/usr/bin/env bash
set -euo pipefail

DEFAULT_XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ -d "$DEFAULT_XCODE_DEVELOPER_DIR" ]] && {
  [[ -z "${DEVELOPER_DIR:-}" ]] || [[ "$DEVELOPER_DIR" == "/Library/Developer/CommandLineTools" ]]
}; then
  export DEVELOPER_DIR="$DEFAULT_XCODE_DEVELOPER_DIR"
fi
