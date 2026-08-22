# TermX

Native iOS / iPadOS terminal with an in-process shell, security-scoped workspaces, and
embedded runtimes for **Python**, **Node.js**, **Claude Code**, and a **Linux (Blink)** guest.

This repo is set up for local git history now; when you create a remote later, push `main`
and the full history comes along.

## Status (2026-08-22)

The Simulator build runs a real pty shell plus embedded runtimes. See
[`STATUS-AND-REWORK.md`](STATUS-AND-REWORK.md) and [`CHANGELOG.md`](CHANGELOG.md).

| Lane | Simulator |
|---|---|
| Shell (pipes, redirects, jobs, `if`/`while`/`case`) | Working |
| Python 3.14 (`python3`, stdlib, `ssl`/`sqlite3`) | Working |
| Node (`node -e`, shim) | Working |
| Linux guest (`linux busybox …`, Alpine bootstrap) | Working |
| Claude Code | Needs real account login |

## Layout

```
terminal/
├── README.md                 ← you are here
├── CHANGELOG.md
├── STATUS-AND-REWORK.md
├── docs/                     ← design + remaining-work briefs
├── TermX/                    ← Xcode app + Swift packages
│   ├── App/
│   ├── Packages/             ← TermXUI, Core, Files, Python, Node, Claude, Linux
│   ├── External/             ← TermXCommands, TermXShellLang, termx-shim
│   ├── Frameworks/           ← build scripts + (gitignored) xcframeworks
│   └── project.yml           ← XcodeGen
└── _archive/                 ← earlier experiments
```

## Prerequisites

- macOS with **Xcode 16+** (tested on Xcode 26 / iPhone 17 Pro Simulator)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- GNU Make 4+ for Blink (`brew install make`)
- Network once to fetch Python / Node / Alpine artifacts

## First-time setup

Large native frameworks are **not** in git (too big). Build them once:

```bash
# Python (BeeWare CPython 3.14)
./TermX/Packages/TermXPython/Scripts/build-termx-python-xcframework.sh

# Node (nodejs-mobile)
./TermX/Frameworks/build-nodejs-mobile.sh

# Blink Linux emulator (host + iOS xcframework)
./TermX/Frameworks/build-blink.sh
```

Symlinks under `Packages/*/Vendor/` already point at `Frameworks/*.xcframework`.

## Build & run

```bash
cd TermX
xcodegen generate
xcodebuild -project TermX.xcodeproj -scheme TermX \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation build

xcrun simctl install "iPhone 17 Pro" \
  ~/Library/Developer/Xcode/DerivedData/TermX-*/Build/Products/Debug-iphonesimulator/TermX.app
xcrun simctl launch "iPhone 17 Pro" com.termx.app
```

DEBUG harness (skips folder picker, types commands):

```bash
SIMCTL_CHILD_TERMX_AUTOWORKSPACE=1 \
SIMCTL_CHILD_TERMX_AUTOCOMMANDS=$'echo hi > a.txt\nls | wc -l > count.txt' \
xcrun simctl launch "iPhone 17 Pro" com.termx.app
```

## Package tests (host)

```bash
for p in TermXCore TermXFiles TermXNode TermXClaude TermXPython TermXLinux; do
  (cd TermX/Packages/$p && swift test)
done
(cd TermX/External/termx-shim && npm test)
```

## Docs

| Doc | Purpose |
|---|---|
| [`docs/00-MASTER-PLAN.md`](docs/00-MASTER-PLAN.md) | Product plan |
| [`docs/09-integration-contracts.md`](docs/09-integration-contracts.md) | Frozen APIs |
| [`docs/10-remaining-work.md`](docs/10-remaining-work.md) | Agent handoff tasks |
| [`TermX/docs/DEVICE-PASS.md`](TermX/docs/DEVICE-PASS.md) | Physical-device checklist |
| [`TermX/External/INTEGRATION-NOTES.md`](TermX/External/INTEGRATION-NOTES.md) | External package wiring |

## Licensing

Third-party notices live under `TermX/NOTICES/`, `TermX/Frameworks/NOTICES/`, and
`TermX/Packages/TermXUI/NOTICES/`. In the app: home screen → **Licenses**.

No GPL/LGPL in the product target. Guest Alpine packages are downloaded by the user at runtime.

## Creating a remote later

```bash
# after you create an empty GitHub/GitLab repo:
git remote add origin git@github.com:YOU/termx.git
git push -u origin main
```

Local history (this `main` branch) is what gets pushed — no rebase required if you start here.
