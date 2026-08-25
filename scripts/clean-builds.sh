#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOVE_SIMULATOR=0

case "${1:-}" in
  "") ;;
  --simulator) REMOVE_SIMULATOR=1 ;;
  *)
    echo "usage: $0 [--simulator]" >&2
    exit 2
    ;;
esac

cache_roots=(
  "$ROOT/.build"
  "$ROOT/build"
  "$ROOT/Frameworks/.build"
  "$ROOT/Packages/TermXClaude/.build"
  "$ROOT/Packages/TermXClaude/.swiftpm"
  "$ROOT/Packages/TermXCore/.build"
  "$ROOT/Packages/TermXCore/.swiftpm"
  "$ROOT/Packages/TermXFiles/.build"
  "$ROOT/Packages/TermXFiles/.swiftpm"
  "$ROOT/Packages/TermXLinux/.build"
  "$ROOT/Packages/TermXLinux/.swiftpm"
  "$ROOT/Packages/TermXNode/.build"
  "$ROOT/Packages/TermXNode/.swiftpm"
  "$ROOT/Packages/TermXPython/.build"
  "$ROOT/Packages/TermXPython/.swiftpm"
  "$ROOT/Packages/TermXUI/.build"
  "$ROOT/Packages/TermXUI/.swiftpm"
  "$ROOT/External/TermXCommands/.build"
  "$ROOT/External/TermXCommands/.swiftpm"
  "$ROOT/External/TermXShellLang/.build"
  "$ROOT/External/TermXShellLang/.swiftpm"
  "$ROOT/External/TetherCommands/.build"
  "$ROOT/External/TetherCommands/.swiftpm"
  "$ROOT/External/TetherShellLang/.build"
  "$ROOT/External/TetherShellLang/.swiftpm"
  "$ROOT/External/TetherTerminal/.build"
  "$ROOT/External/TetherTerminal/.swiftpm"
  "$ROOT/External/TetherWasm/.build"
  "$ROOT/External/TetherWasm/.swiftpm"
)

for path in "${cache_roots[@]}"; do
  if test -e "$path"; then
    echo "remove ${path#"$ROOT"/}"
    rm -rf -- "$path"
  fi
done

if test "$(uname -s)" = "Darwin"; then
  user_name="$(id -un)"
  user_directory="$(id -P "$user_name" 2>/dev/null | awk -F: '{print $9}' || true)"
  derived_data="$user_directory/Library/Developer/Xcode/DerivedData"
  case "$derived_data" in
    /Users/*/Library/Developer/Xcode/DerivedData)
      if test -d "$derived_data"; then
        while IFS= read -r -d '' path; do
          case "$path" in
            "$derived_data"/Tether-*)
              echo "remove $path"
              rm -rf -- "$path"
              ;;
          esac
        done < <(find "$derived_data" -mindepth 1 -maxdepth 1 -type d -name 'Tether-*' -print0)
      fi
      ;;
    *)
      echo "warning: could not safely resolve Xcode DerivedData; skipped it" >&2
      ;;
  esac
fi

if test "$REMOVE_SIMULATOR" = "1"; then
  if xcrun simctl list devices booted 2>/dev/null | grep -q '(Booted)'; then
    echo "uninstall com.tether.app from booted simulator"
    xcrun simctl uninstall booted com.tether.app 2>/dev/null || true
  else
    echo "no booted simulator; nothing to uninstall"
  fi
fi

echo "Tether build caches removed."
