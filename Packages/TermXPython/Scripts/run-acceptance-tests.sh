#!/usr/bin/env bash
# Runs the Python acceptance tests on iOS Simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG="$ROOT/Packages/TermXPython"
export TETHER_PYTHON_ROOT="$ROOT/Frameworks/TermXPython.xcframework"

"$PKG/Scripts/build-termx-python-xcframework.sh"

DEST="${TERMX_IOS_SIM_DEST:-platform=iOS Simulator,name=iPhone 17,OS=26.3.1}"
cd "$PKG"
xcodebuild test \
  -scheme TermXPython \
  -destination "$DEST" \
  -skipPackagePluginValidation \
  "$@"
