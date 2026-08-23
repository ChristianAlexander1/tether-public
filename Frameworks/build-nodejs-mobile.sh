#!/usr/bin/env bash
# Fetches a signed NodeMobile.xcframework for TermX from the maintained digidem
# nodejs-mobile fork (Node current + mobile patches). Official nodejs-mobile
# stopped at 18.20.4 / V8 10.2, which faults on npm's module graph under iOS
# jitless; digidem's lite iOS build ships interpreter-only V8.
#
# License: MIT (Node.js / nodejs-mobile). See NOTICES/nodejs-mobile-MIT.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build"
# Tag format: v<node-version>-<mobile-rev> (process.versions.mobile / process.version).
VERSION="${NODEJS_MOBILE_VERSION:-24.19.0-1}"
TAG="v${VERSION#v}"
FILE_VERSION="${TAG#v}"
# lite: no ICU/inspector/sqlite/TS strip; iOS also omits V8 compiled tiers.
FLAVOR="${NODEJS_MOBILE_FLAVOR:-full}"
case "$FLAVOR" in
  lite) ASSET_FLAVOR="-lite" ;;
  full) ASSET_FLAVOR="" ;;
  *) echo "NODEJS_MOBILE_FLAVOR must be lite or full, got: $FLAVOR" >&2; exit 1 ;;
esac

REPO="${NODEJS_MOBILE_REPO:-digidem/nodejs-mobile}"
ZIP="$BUILD_DIR/nodejs-mobile-ios${ASSET_FLAVOR}-${FILE_VERSION}.zip"
URL="https://github.com/${REPO}/releases/download/${TAG}/nodejs-mobile-ios${ASSET_FLAVOR}-${FILE_VERSION}.zip"
OUT="$ROOT/NodeMobile.xcframework"
HEADERS_OUT="$ROOT/include/node"
VERSIONS_OUT="$ROOT/VERSIONS.node"
SHA_OUT="$ROOT/NodeMobile.xcframework.sha256"

# Expected digest for the default pin (digidem v24.19.0-1 full iOS — includes ICU
# so packages using Unicode property escapes, e.g. Claude Code, can load).
# Override with NODEJS_MOBILE_SHA256=skip when intentionally changing pins.
EXPECTED_SHA256="${NODEJS_MOBILE_SHA256:-e7633a60e55443ca11ee4c28ff7a43294a6ace9aa3362a6c0213a843b4c4f840}"

echo "==> nodejs-mobile ${TAG} (${FLAVOR}) from ${REPO}"
mkdir -p "$BUILD_DIR"

if [[ ! -f "$ZIP" ]]; then
  echo "==> Downloading ${URL}"
  curl -fSL --retry 3 --retry-delay 2 -o "$ZIP" "$URL"
fi

if [[ "$EXPECTED_SHA256" != "skip" ]]; then
  ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  if [[ "$ACTUAL" != "$EXPECTED_SHA256" ]]; then
    echo "SHA-256 mismatch for $ZIP" >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  actual:   $ACTUAL" >&2
    exit 1
  fi
  echo "==> SHA-256 OK ($ACTUAL)"
fi

echo "==> Extracting xcframework"
rm -rf "$OUT" "$BUILD_DIR/extract-ios"
mkdir -p "$BUILD_DIR/extract-ios"
# Zip top-level is NodeMobile.xcframework/ plus optional include/; keep headers.
unzip -qo "$ZIP" -d "$BUILD_DIR/extract-ios"
if [[ ! -d "$BUILD_DIR/extract-ios/NodeMobile.xcframework" ]]; then
  echo "error: zip did not contain NodeMobile.xcframework" >&2
  exit 1
fi
mv "$BUILD_DIR/extract-ios/NodeMobile.xcframework" "$OUT"

if [[ -d "$BUILD_DIR/extract-ios/include/node" ]]; then
  rm -rf "$HEADERS_OUT"
  mkdir -p "$(dirname "$HEADERS_OUT")"
  cp -R "$BUILD_DIR/extract-ios/include/node" "$HEADERS_OUT"
elif [[ -d "$OUT/ios-arm64/NodeMobile.framework/Headers" ]]; then
  # Framework module headers are enough for the C bridge (node_start).
  echo "==> Using framework Headers (no top-level include/ in zip)"
fi

{
  echo "repo=${REPO}"
  echo "tag=${TAG}"
  echo "flavor=${FLAVOR}"
  echo "asset=nodejs-mobile-ios${ASSET_FLAVOR}-${FILE_VERSION}.zip"
  echo "sha256=${EXPECTED_SHA256}"
  echo "node=$(echo "$FILE_VERSION" | cut -d- -f1)"
  echo "fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$VERSIONS_OUT"

shasum -a 256 "$ZIP" | awk '{print $1"  nodejs-mobile-ios'"${ASSET_FLAVOR}"'-'"${FILE_VERSION}"'.zip"}' > "$SHA_OUT"

echo "==> Installed:"
echo "    $OUT"
echo "    $VERSIONS_OUT"
echo "    $SHA_OUT"
echo "==> Slices:"
/usr/libexec/PlistBuddy -c 'Print AvailableLibraries' "$OUT/Info.plist" 2>/dev/null || ls "$OUT"
