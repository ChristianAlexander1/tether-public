#!/usr/bin/env bash
# Builds (fetches) NodeMobile.xcframework for TermX from the official nodejs-mobile release.
# License: MIT (Node.js / nodejs-mobile). See NOTICES/nodejs-mobile-MIT.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build"
VERSION="${NODEJS_MOBILE_VERSION:-18.20.4}"
ZIP="$BUILD_DIR/nodejs-mobile-v${VERSION}-ios.zip"
URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v${VERSION}/nodejs-mobile-v${VERSION}-ios.zip"
OUT="$ROOT/NodeMobile.xcframework"
HEADERS_OUT="$ROOT/include/node"

echo "==> nodejs-mobile ${VERSION} (iOS)"
mkdir -p "$BUILD_DIR"

if [[ ! -f "$ZIP" ]]; then
  echo "==> Downloading ${URL}"
  curl -fsSL -o "$ZIP" "$URL"
fi

echo "==> Extracting xcframework"
rm -rf "$OUT"
unzip -qo "$ZIP" "NodeMobile.xcframework/*" -d "$ROOT"

if [[ -d "$BUILD_DIR/include/node" ]]; then
  rm -rf "$HEADERS_OUT"
  mkdir -p "$(dirname "$HEADERS_OUT")"
  cp -R "$BUILD_DIR/include/node" "$HEADERS_OUT"
else
  rm -rf "$BUILD_DIR/extract"
  unzip -qo "$ZIP" "include/*" -d "$BUILD_DIR/extract"
  rm -rf "$HEADERS_OUT"
  mkdir -p "$(dirname "$HEADERS_OUT")"
  cp -R "$BUILD_DIR/extract/include/node" "$HEADERS_OUT"
fi

echo "==> Installed:"
echo "    $OUT"
echo "    $HEADERS_OUT"
echo "==> Slices:"
/usr/libexec/PlistBuddy -c 'Print AvailableLibraries' "$OUT/Info.plist" 2>/dev/null || ls "$OUT"
