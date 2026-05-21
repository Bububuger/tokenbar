#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" != "--xcode" ]]; then
  cd "$ROOT_DIR"
  swift test "$@"
  exit 0
fi

shift
source "$ROOT_DIR/script/xcode_env.sh"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version | tr -cd '[:alnum:]._-')"
XCODE_DERIVED_DATA_DIR="${TMPDIR:-/tmp}/tokenbar-xcodebuild-tests-$SDK_VERSION"
XCODE_SOURCE_PACKAGES_DIR="${TMPDIR:-/tmp}/tokenbar-source-packages-$SDK_VERSION"

cd "$ROOT_DIR"
xcodegen generate --spec project.yml --project "$ROOT_DIR" >/dev/null
xcodebuild \
  -project "$ROOT_DIR/TokenBar.xcodeproj" \
  -scheme TokenBarTests \
  -configuration Debug \
  -derivedDataPath "$XCODE_DERIVED_DATA_DIR" \
  -clonedSourcePackagesDirPath "$XCODE_SOURCE_PACKAGES_DIR" \
  -skipMacroValidation \
  test \
  "$@"
