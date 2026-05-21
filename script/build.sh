#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/xcode_env.sh"
XCODE_DERIVED_DATA_DIR="${TMPDIR:-/tmp}/tokenbar-xcodebuild-app"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version | tr -cd '[:alnum:]._-')"
XCODE_SOURCE_PACKAGES_DIR="${TMPDIR:-/tmp}/tokenbar-source-packages-$SDK_VERSION"
DEFAULT_DEVELOPMENT_TEAM="${TOKENBAR_DEVELOPMENT_TEAM:-MNTV7AH6PF}"
SIGNING_IDENTITY="${TOKENBAR_CODE_SIGN_IDENTITY:-Apple Development}"

cd "$ROOT_DIR"
xcodegen generate --spec project.yml --project "$ROOT_DIR" >/dev/null
rm -rf "$XCODE_DERIVED_DATA_DIR"
xcodebuild \
  -project "$ROOT_DIR/TokenBar.xcodeproj" \
  -scheme TokenBar \
  -configuration Debug \
  -derivedDataPath "$XCODE_DERIVED_DATA_DIR" \
  -clonedSourcePackagesDirPath "$XCODE_SOURCE_PACKAGES_DIR" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEFAULT_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  build
