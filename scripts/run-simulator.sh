#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIMULATOR_NAME="${TETHER_SIMULATOR_NAME:-iPhone 17 Pro}"
DERIVED_DATA="$ROOT/build/ios-simulator/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Tether.app"
RESET_DATA=0
DATA_BACKUP=""
OLD_DATA_CONTAINER=""

usage() {
  cat <<'USAGE'
usage: ./scripts/run-simulator.sh [--reset-data]

Build, install, and launch Tether in the selected Simulator. Existing app data
is preserved by default. --reset-data uninstalls the app first and permanently
deletes that Simulator installation's Linux rootfs, packages, and CLI state.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset-data) RESET_DATA=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for tool in xcodegen xcodebuild xcrun ditto mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required command not found: $tool" >&2
    exit 127
  fi
done

cleanup_backup() {
  if [[ -n "$DATA_BACKUP" && "$DATA_BACKUP" == "${TMPDIR:-/tmp}/tether-simulator-data."* ]]; then
    rm -rf "$DATA_BACKUP"
  fi
}
trap cleanup_backup EXIT

echo "== Generate Tether.xcodeproj =="
(cd "$ROOT" && xcodegen generate)

echo "== Boot simulator: $SIMULATOR_NAME =="
xcrun simctl boot "$SIMULATOR_NAME" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_NAME" -b

echo "== Build Tether =="
xcodebuild \
  -project "$ROOT/Tether.xcodeproj" \
  -scheme Tether \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build

if ! test -d "$APP_PATH"; then
  echo "error: build succeeded but app was not found at $APP_PATH" >&2
  exit 1
fi

echo "== Install and launch Tether =="
if [[ "$RESET_DATA" == "1" ]]; then
  echo "== Reset Simulator app data =="
  xcrun simctl uninstall "$SIMULATOR_NAME" com.tether.app 2>/dev/null || true
else
  # Terminating is enough for an in-place install and preserves the app's data
  # when CoreSimulator keeps the same container. Back up first because some
  # Simulator/Xcode combinations allocate a replacement data-container UUID.
  xcrun simctl terminate "$SIMULATOR_NAME" com.tether.app 2>/dev/null || true
  OLD_DATA_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_NAME" com.tether.app data 2>/dev/null || true)"
  if [[ -n "$OLD_DATA_CONTAINER" && -d "$OLD_DATA_CONTAINER" ]]; then
    DATA_BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/tether-simulator-data.XXXXXX")"
    echo "== Preserve existing Simulator app data =="
    ditto "$OLD_DATA_CONTAINER" "$DATA_BACKUP"
  fi
fi
xcrun simctl install "$SIMULATOR_NAME" "$APP_PATH"

if [[ "$RESET_DATA" != "1" && -n "$DATA_BACKUP" ]]; then
  NEW_DATA_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_NAME" com.tether.app data)"
  if [[ "$NEW_DATA_CONTAINER" != "$OLD_DATA_CONTAINER" ]]; then
    echo "== Restore Simulator app data into replacement container =="
    ditto "$DATA_BACKUP" "$NEW_DATA_CONTAINER"
  fi
fi
xcrun simctl launch "$SIMULATOR_NAME" com.tether.app

if test "${TETHER_SKIP_OPEN_SIMULATOR:-0}" != "1"; then
  open -a Simulator 2>/dev/null || true
fi

echo "Tether is running on $SIMULATOR_NAME."
