#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
packages=(TermXUI TermXCore TermXFiles TermXPython TermXNode TermXClaude TermXLinux)
for package in "${packages[@]}"; do
  test -f "$ROOT/Packages/$package/Package.swift"
  test -d "$ROOT/Packages/$package/Sources/$package"
  if [ "$package" = "TermXUI" ]; then
    test -d "$ROOT/Packages/$package/Tests/TermXUITests"
  else
    test -d "$ROOT/Packages/$package/Tests/$package"
  fi
  test -f "$ROOT/Packages/$package/HANDOFF.md"
done
test -f "$ROOT/App/TermXApp.swift"
test -f "$ROOT/App/Info.plist"
test -f "$ROOT/App/IntegrationSource/TermXIntegration.swift"
test -f "$ROOT/App/IntegrationTests/TermXIntegrationTests.swift"
if grep -RInE 'TODO|FIXME|fatalError\("unimplemented' "$ROOT/App" "$ROOT/Packages" --include='*.swift'; then
  echo "unfinished source marker detected" >&2
  exit 1
fi
echo "TermX repository structure and source-marker validation passed."
