#!/usr/bin/env bash
# Builds or fetches TermXPython.xcframework from BeeWare Python-Apple-support.
# Output: TermX/Frameworks/TermXPython.xcframework (not committed; ~240MB)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG_DIR="$ROOT/Packages/TermXPython"
BUILD_DIR="$PKG_DIR/.build"
FRAMEWORKS_DIR="$ROOT/Frameworks"
OUT_XCF="$FRAMEWORKS_DIR/TermXPython.xcframework"

PYTHON_SUPPORT_TAG="${TERMX_PYTHON_SUPPORT_TAG:-3.14-b10}"
IOS_TARBALL="Python-${PYTHON_SUPPORT_TAG%-b*}-iOS-support.${PYTHON_SUPPORT_TAG##*-}.tar.gz"
DOWNLOAD_URL="https://github.com/beeware/Python-Apple-support/releases/download/${PYTHON_SUPPORT_TAG}/${IOS_TARBALL}"

mkdir -p "$BUILD_DIR" "$FRAMEWORKS_DIR"

if [[ -d "$OUT_XCF/ios-arm64/Python.framework" ]]; then
  echo "TermXPython.xcframework already present at $OUT_XCF"
  exit 0
fi

echo "Downloading BeeWare ${PYTHON_SUPPORT_TAG} iOS support package..."
curl -L --fail --progress-bar -o "$BUILD_DIR/$IOS_TARBALL" "$DOWNLOAD_URL"

echo "Extracting to $FRAMEWORKS_DIR..."
rm -rf "$BUILD_DIR/extract" "$OUT_XCF"
mkdir -p "$BUILD_DIR/extract"
tar -xzf "$BUILD_DIR/$IOS_TARBALL" -C "$BUILD_DIR/extract"
mv "$BUILD_DIR/extract/Python.xcframework" "$OUT_XCF"

mkdir -p "$PKG_DIR/Vendor"
ln -sfn "../../../Frameworks/TermXPython.xcframework" "$PKG_DIR/Vendor/TermXPython.xcframework"

HEADER_SRC="$OUT_XCF/ios-arm64/include/python3.14"
HEADER_DST="$PKG_DIR/Sources/TermXPythonBridge/PythonHeaders"
rm -rf "$HEADER_DST"
mkdir -p "$HEADER_DST"
cp -R "$HEADER_SRC/"* "$HEADER_DST/"

if [[ -f "$BUILD_DIR/extract/VERSIONS" ]]; then
  cp "$BUILD_DIR/extract/VERSIONS" "$PKG_DIR/VERSIONS.upstream"
fi

echo "Installed TermXPython.xcframework"
du -sh "$OUT_XCF"
echo "Upstream: beeware/Python-Apple-support tag ${PYTHON_SUPPORT_TAG}"
