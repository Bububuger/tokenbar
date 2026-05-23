#!/usr/bin/env bash
set -euo pipefail

# Usage: script/release.sh <VERSION>
# Example: script/release.sh 1.0.0
#
# Builds a Release DMG for Homebrew Cask distribution (ad-hoc signed).
# Also embeds the `tbar` CLI binary inside TokenBar.app/Contents/MacOS/tbar
# so that the Cask formula can symlink it onto $PATH automatically (a single
# `brew install --cask tokenbar` then makes both the app and the CLI usable).
# No Apple Developer ID required.
#
# Output: dist/TokenBar-VERSION.dmg
# Prints sha256 at the end for updating the Cask formula.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/xcode_env.sh"

# ── Args ─────────────────────────────────────────────────────────────────────

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: script/release.sh <VERSION>"
  echo "  e.g. script/release.sh 1.0.0"
  exit 1
fi

# Basic semver sanity check
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be x.y.z (got: $VERSION)"
  exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────

APP_NAME="TokenBar"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version | tr -cd '[:alnum:]._-')"
DERIVED_DATA="${TMPDIR:-/tmp}/tokenbar-release"
SOURCE_PACKAGES="${TMPDIR:-/tmp}/tokenbar-source-packages-$SDK_VERSION"
DIST_DIR="$ROOT_DIR/dist"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
BUILD_LOG="${TMPDIR:-/tmp}/tokenbar-release-build.log"

echo "TokenBar release builder"
echo "  Version : $VERSION"
echo "  Output  : dist/$DMG_NAME"
echo ""

# ── 1. Bump version in Info.plist ─────────────────────────────────────────────

echo "→ [1/6] Updating Info.plist version to $VERSION"
PLIST="$ROOT_DIR/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
BUILD_NUMBER=$(date +%s)
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD_NUMBER" "$PLIST"

# ── 2. Regenerate Xcode project ───────────────────────────────────────────────

echo "→ [2/6] Generating Xcode project"
if ! command -v xcodegen &>/dev/null; then
  echo "  Error: xcodegen not found. Install with: brew install xcodegen"
  exit 1
fi
xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR" >/dev/null

# ── 3. Build Release ─────────────────────────────────────────────────────────

echo "→ [3/6] Building Release (log: $BUILD_LOG)"
rm -rf "$DERIVED_DATA"

xcodebuild \
  -project "$ROOT_DIR/TokenBar.xcodeproj" \
  -scheme TokenBar \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  build >"$BUILD_LOG" 2>&1 || {
    echo "  Build FAILED. Last 30 lines:"
    tail -30 "$BUILD_LOG"
    exit 1
  }

APP_PATH="$(find "$DERIVED_DATA/Build/Products/Release" -name "$APP_NAME.app" -maxdepth 1 2>/dev/null | head -1)"
if [[ -z "$APP_PATH" ]]; then
  echo "  Error: $APP_NAME.app not found after build"
  exit 1
fi
echo "  Built: $APP_PATH"

# ── 4. Build + embed `tbar` CLI inside the .app ───────────────────────────────
#
# Build the TokenBarCLI scheme into the same DerivedData, then copy the
# resulting `tbar` binary into TokenBar.app/Contents/MacOS/tbar. A Homebrew
# Cask `binary` directive can then symlink this into /opt/homebrew/bin/tbar.
#
# The CLI is signed with the same ad-hoc identity as the app.

echo "→ [4/6] Building tbar CLI and embedding into bundle"
TBAR_BUILD_LOG="${TMPDIR:-/tmp}/tokenbar-release-tbar.log"

xcodebuild \
  -project "$ROOT_DIR/TokenBar.xcodeproj" \
  -scheme tbar \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  build >"$TBAR_BUILD_LOG" 2>&1 || {
    echo "  tbar build FAILED. Last 30 lines:"
    tail -30 "$TBAR_BUILD_LOG"
    exit 1
  }

TBAR_BIN="$DERIVED_DATA/Build/Products/Release/tbar"
if [[ ! -x "$TBAR_BIN" ]]; then
  echo "  Error: tbar binary not found or not executable at $TBAR_BIN"
  ls -la "$(dirname "$TBAR_BIN")" 2>/dev/null || true
  exit 1
fi
echo "  Built: $TBAR_BIN ($(du -h "$TBAR_BIN" | cut -f1))"

cp "$TBAR_BIN" "$APP_PATH/Contents/MacOS/tbar"
chmod +x "$APP_PATH/Contents/MacOS/tbar"
echo "  Embedded: $APP_PATH/Contents/MacOS/tbar"

# ── 5. Ad-hoc sign (app + embedded CLI) ───────────────────────────────────────

echo "→ [5/6] Ad-hoc signing (codesign -s -)"
# Sign the embedded CLI first, then re-sign the app bundle to refresh its
# CodeResources hash. --deep then walks any other inner code.
codesign --force --sign - "$APP_PATH/Contents/MacOS/tbar"
codesign --force --deep --sign - "$APP_PATH"
echo "  Signed: $(codesign -dv "$APP_PATH" 2>&1 | grep 'Identifier' || echo 'ok')"

# ── 6. Create DMG ────────────────────────────────────────────────────────────

echo "→ [6/6] Creating DMG"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -quiet \
  "$DMG_PATH"

# ── Summary ──────────────────────────────────────────────────────────────────

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
SIZE="$(du -sh "$DMG_PATH" | cut -f1)"

echo ""
echo "✓ Done"
echo ""
echo "  File          : dist/$DMG_NAME  ($SIZE)"
echo "  sha256        : $SHA256"
echo "  Embedded CLI  : TokenBar.app/Contents/MacOS/tbar"
echo ""
echo "Next steps:"
echo "  1. git tag v$VERSION && git push origin v$VERSION"
echo "  2. Upload dist/$DMG_NAME to GitHub Releases (tag v$VERSION)"
echo "  3. Update Cask formula in script/release/Casks/tokenbar.rb:"
echo "       version \"$VERSION\""
echo "       sha256 \"$SHA256\""
echo "  4. Publish via the homebrew tap (e.g. Bububuger/homebrew-tap)."
echo ""
echo "Users will then get both the app and the CLI from one command:"
echo "  brew install --cask <tap>/tokenbar  ⇒  /Applications/TokenBar.app"
echo "                                          /opt/homebrew/bin/tbar"
