#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---quick}"
MODULE_CACHE="/tmp/tether-swift-module-cache"
BUILD_ROOT="/tmp/tether-validation-$$"

case "$MODE" in
  --quick|--network|--ios|--all) ;;
  *)
    echo "usage: $0 [--quick|--network|--ios|--all]" >&2
    exit 2
    ;;
esac

mkdir -p "$MODULE_CACHE" "$BUILD_ROOT"
trap 'rm -rf "$BUILD_ROOT"' EXIT

swift_test() {
  local path="$1"
  echo "== swift test: ${path#"$ROOT"/} =="
  (
    cd "$path"
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
      swift test --disable-sandbox --disable-automatic-resolution
  )
}

structure_check() {
  local packages=(TermXUI TermXCore TermXFiles TermXPython TermXNode TermXClaude TermXLinux)
  for package in "${packages[@]}"; do
    test -f "$ROOT/Packages/$package/Package.swift"
    test -d "$ROOT/Packages/$package/Sources/$package"
    test -f "$ROOT/Packages/$package/HANDOFF.md"
  done

  test -f "$ROOT/App/TetherApp.swift"
  test -f "$ROOT/App/Info.plist"
  test -f "$ROOT/App/IntegrationSource/TermXIntegration.swift"
  test -f "$ROOT/App/IntegrationSource/TetherWasmService.swift"
  test -f "$ROOT/External/TetherWasm/Package.swift"
  test -f "$ROOT/Packages/TermXLinux/Sources/TermXLinux/Resources/tether_dispatch_manifest.json"

  if rg -n 'fatalError\("unimplemented|TODO: implement|FIXME: implement' \
      "$ROOT/App" "$ROOT/Packages" --glob '*.swift'; then
    echo "unfinished source marker detected" >&2
    exit 1
  fi
}

quick_tests() {
  local packages=(
    TermXUI TermXCore TermXFiles TermXPython TermXNode TermXClaude TermXLinux
  )
  local external=(TermXCommands TermXShellLang TetherCommands)
  local standalone=(External/TetherShellLang External/TetherTerminal)

  for package in "${packages[@]}"; do
    swift_test "$ROOT/Packages/$package"
  done
  for package in "${external[@]}"; do
    swift_test "$ROOT/External/$package"
  done
  for package in "${standalone[@]}"; do
    swift_test "$ROOT/$package"
  done
  swift_test "$ROOT"

  echo "== npm test: External/tether-shim =="
  (cd "$ROOT/External/tether-shim" && npm test)
  echo "== npm test: External/tether-spawn-fixtures =="
  (cd "$ROOT/External/tether-spawn-fixtures" && npm test)

  echo "== CMake/CTest: TetherWasm =="
  cmake -S "$ROOT/External/TetherWasm" -B "$BUILD_ROOT/wasm" -DTETHER_WASM_BUILD_TESTS=ON
  cmake --build "$BUILD_ROOT/wasm" --parallel
  ctest --test-dir "$BUILD_ROOT/wasm" --output-on-failure
}

linux_network_tests() {
  echo "== real Blink/Alpine acceptance =="
  (
    cd "$ROOT/Packages/TermXLinux"
    TETHER_LINUX_NETWORK_TESTS=1 \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
      swift test --disable-sandbox --disable-automatic-resolution
  )
}

ios_build() {
  local simulator="${TETHER_SIMULATOR_NAME:-iPhone 17 Pro}"
  local derived="$BUILD_ROOT/DerivedData"
  echo "== iOS Simulator build: $simulator =="
  (cd "$ROOT" && xcodegen generate)
  xcodebuild \
    -project "$ROOT/Tether.xcodeproj" \
    -scheme Tether \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=$simulator" \
    -derivedDataPath "$derived" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    build
}

structure_check
case "$MODE" in
  --quick) quick_tests ;;
  --network) linux_network_tests ;;
  --ios) ios_build ;;
  --all)
    quick_tests
    linux_network_tests
    ios_build
    ;;
esac

echo "Tether validation passed ($MODE)."
