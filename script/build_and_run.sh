#!/bin/bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TokenBar"
BUNDLE_ID="com.javis.TokenBar"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/xcode_env.sh"
DERIVED_DATA_DIR="${TOKENBAR_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData/TokenBar-Codex}"
XCODE_SOURCE_PACKAGES_DIR="$DERIVED_DATA_DIR/SourcePackages"
BUILD_PRODUCTS_DIR="$DERIVED_DATA_DIR/Build/Products/Debug"
APP_BUNDLE="$BUILD_PRODUCTS_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
XCODE_PROJECT="$ROOT_DIR/TokenBar.xcodeproj"
DEFAULT_DEVELOPMENT_TEAM="${TOKENBAR_DEVELOPMENT_TEAM:-MNTV7AH6PF}"
SIGNING_IDENTITY="${TOKENBAR_CODE_SIGN_IDENTITY:-Apple Development}"

reset_derived_data() {
  local attempt
  for attempt in 1 2 3 4 5; do
    rm -rf "$DERIVED_DATA_DIR" >/dev/null 2>&1 || true
    if [[ ! -e "$DERIVED_DATA_DIR" ]]; then
      return 0
    fi
    sleep 0.25
  done

  echo "error: failed to clear DerivedData at $DERIVED_DATA_DIR" >&2
  return 1
}

if ! security find-identity -p codesigning -v | grep -Eq '^[[:space:]]*[1-9][0-9]* valid identities found'; then
  echo "warning: no local signing identity found yet; asking xcodebuild to provision via the signed-in Xcode account." >&2
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
if pids="$(pgrep -x "$APP_NAME" 2>/dev/null)" && [[ -n "$pids" ]]; then
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    parent_pid="$(ps -o ppid= -p "$pid" | tr -d '[:space:]')"
    parent_comm=""
    [[ -n "$parent_pid" ]] && parent_comm="$(ps -o comm= -p "$parent_pid" 2>/dev/null | xargs basename 2>/dev/null || true)"
    if [[ -n "$parent_pid" && "$parent_pid" != "1" && "$parent_comm" == "debugserver" ]]; then
      kill -9 "$parent_pid" >/dev/null 2>&1 || true
    fi
    kill -9 "$pid" >/dev/null 2>&1 || true
  done <<<"$pids"
  sleep 1
fi

xcodegen generate --spec project.yml --project "$ROOT_DIR" >/dev/null
if [[ "${TOKENBAR_CLEAN_DERIVED_DATA:-0}" == "1" ]]; then
  reset_derived_data
fi
mkdir -p "$DERIVED_DATA_DIR"
xcodebuild \
  -project "$XCODE_PROJECT" \
  -scheme TokenBar \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -clonedSourcePackagesDirPath "$XCODE_SOURCE_PACKAGES_DIR" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEFAULT_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  build >/dev/null

# Local development bundles can inherit provenance/quarantine metadata from the
# invoking shell or generated build tree. Gatekeeper may kill those bundles even
# when they are correctly Apple Development signed, so strip metadata before run.
xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true

codesign_output="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
if [[ "$codesign_output" != *"Authority=Apple Development"* ]]; then
  echo "error: expected a development-signed app bundle at $APP_BUNDLE, but the build output is not signed with Apple Development." >&2
  echo "$codesign_output" >&2
  exit 1
fi

developer_mode_enabled() {
  DevToolsSecurity -status 2>/dev/null | grep -q 'enabled'
}

tokenbar_running() {
  local pids pid stat
  pids="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  [[ -n "$pids" ]] || return 1

  while read -r pid; do
    [[ -z "$pid" ]] && continue
    stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$stat" && "$stat" != T* && "$stat" != Z* ]]; then
      return 0
    fi
  done <<<"$pids"

  return 1
}

wait_for_tokenbar() {
  local attempts="${1:-30}"
  local delay="${2:-0.2}"
  for _ in $(seq 1 "$attempts"); do
    if tokenbar_running; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

kill_tokenbar_processes() {
  local pids pid parent_pid parent_comm
  pids="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  [[ -n "$pids" ]] || return 0

  while read -r pid; do
    [[ -z "$pid" ]] && continue
    parent_pid="$(ps -o ppid= -p "$pid" | tr -d '[:space:]')"
    parent_comm=""
    [[ -n "$parent_pid" ]] && parent_comm="$(ps -o comm= -p "$parent_pid" 2>/dev/null | xargs basename 2>/dev/null || true)"
    if [[ -n "$parent_pid" && "$parent_pid" != "1" && "$parent_comm" == "debugserver" ]]; then
      kill -9 "$parent_pid" >/dev/null 2>&1 || true
    fi
    kill -9 "$pid" >/dev/null 2>&1 || true
  done <<<"$pids"
}

latest_xcode_app_bundle() {
  find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/Build/Products/Debug/TokenBar.app' \
    -type d \
    -prune \
    -print 2>/dev/null |
    while IFS= read -r candidate; do
      [[ "$candidate" == *"/Index.noindex/"* ]] && continue
      [[ "$candidate" == "$APP_BUNDLE" ]] && continue
      printf '%s\t%s\n' "$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)" "$candidate"
    done |
    sort -rn |
    head -n 1 |
    cut -f 2-
}

open_app() {
  if developer_mode_enabled; then
    /usr/bin/open -n "$APP_BUNDLE"
    if wait_for_tokenbar 15 0.2; then
      return 0
    fi

    echo "note: direct launch was blocked or exited; trying the latest Xcode-managed debug app bundle." >&2
    kill_tokenbar_processes
  else
    echo "note: Developer Mode is disabled for terminal-launched developer apps; trying the latest Xcode-managed debug app bundle." >&2
  fi

  local xcode_app
  xcode_app="$(latest_xcode_app_bundle)"
  if [[ -n "$xcode_app" ]]; then
    rm -rf "$xcode_app"
    /usr/bin/ditto "$APP_BUNDLE" "$xcode_app"
    xattr -cr "$xcode_app" >/dev/null 2>&1 || true
    /usr/bin/open -n "$xcode_app"
    wait_for_tokenbar 25 0.2
  else
    echo "error: launch was blocked and no Xcode-managed TokenBar.app was found. Run the TokenBar scheme once in Xcode, then rerun this script." >&2
    return 1
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    wait_for_tokenbar 15 0.2
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
