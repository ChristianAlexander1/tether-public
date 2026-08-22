# Changelog

All notable changes to TermX are recorded here.  
Format inspired by [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Planned
- Physical-device pass (bookmark persistence, iCloud eviction, scope leak) — see `TermX/docs/DEVICE-PASS.md`
- Interactive Claude Code login with a real Anthropic account
- Optional soak: `npm install express`, `pip install rich` on device
- Tabs / iPad multi-window / scrollback search polish

---

## [0.1.0] — 2026-08-22

First integrated local snapshot: shell + embedded runtimes on iPhone Simulator.

### Added
- **App shell** — SwiftUI workspace picker, pty terminal session, DEBUG `TERMX_AUTOCOMMANDS` harness
- **TermXUI** — SwiftTerm bridge, themes, keyboard accessory
- **TermXCore** — in-process shell (pipelines, redirects, jobs, command substitution)
- **TermXFiles** — security-scoped bookmarks and workspace access
- **TermXPython** — BeeWare CPython 3.14 bridge; BeeWare `install_python` app-bundle stdlib
- **TermXNode** — NodeMobile link + `@termx/shim` preload + job IPC bootstrap
- **TermXClaude** — install / login / run orchestration (blocked only on interactive login)
- **TermXLinux** — Blink iOS xcframework path + Alpine minirootfs auto-bootstrap
- **External packages** — `TermXCommands`, `TermXShellLang`, `termx-shim` (wired as T6–T8)
- **Licenses** screen (bundled NOTICE texts)
- Design docs under `docs/` and integration status in `STATUS-AND-REWORK.md`

### Integration milestones (same day)
| ID | Work |
|---|---|
| T6 | Wire `TermXCommands` into TermXCore registry |
| T7 | Wire `TermXShellLang` into `ShellSession` |
| T1 | Link `NodeMobile.xcframework` + `node_start` bridge |
| T8 | Swap delivered `termx-shim` into TermXNode |
| T2 | Bundle Python stdlib via BeeWare install phase |
| T3 | Build/link Blink for iOS + first-use Alpine bootstrap |
| T4 | Node Simulator e2e (`node -e` → `4`); Claude login still manual |
| T5 | Licenses UI + device-pass checklist |

### Fixed (notable)
- SIGWINCH / SIGPIPE shell survival; pty drain on shutdown
- Awk/sed argv re-lex and single-quoted `$` preservation
- Node bootstrap used `fs.open(fd)` incorrectly on job pipes
- Python init required app-bundle `PYTHONHOME` (not `.xcframework` layout)
- Blink iOS port: `clock_settime`, `fdatasync`, `sys/random.h` shims

### Verified on Simulator
- `python3` → `42`; `import ssl, sqlite3`
- `node -e` → `4`
- `linux /bin/busybox echo hi` → `hi`
- Host package tests: Node 9, Python 6, Linux 8 (2 skipped), External shim 48 JS

### Notes
- `*.xcframework` binaries are **not** versioned; rebuild with scripts under `TermX/Frameworks/` and `TermXPython/Scripts/`.
- This is a pre-release engineering snapshot, not an App Store build.

---

## Versioning

Until 1.0.0, versions are engineering tags (`0.x.y`). Bump:
- **patch** — fixes / docs
- **minor** — user-visible features or runtime lanes
- **major** — frozen API breaks or first public release
