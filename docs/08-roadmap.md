# C8 — Roadmap & Agent Work Split

**Goal:** Ship in clean milestones, with components parallelized across agents. Every
milestone ends in something that runs on a device.

## Milestones

### M1 — Walking skeleton  *(the "it's real" moment)*
- Xcode project + SwiftUI shell app, TestFlight-able
- C1: SwiftTerm view + pty + resize + basic key toolbar
- C3: folder picker + bookmark persistence + workspace launcher screen
- C2: forked ios_system building as xcframework; dispatcher runs `ls/cat/echo/cd` with
  pipes & redirects via interim mini-parser
- ✔ Demo: open a folder, `ls | grep foo > out.txt`, relaunch app, access persists

### M2 — Real shell
- mksh port on the VirtualProcess model; history, completion, .profile
- Job control, Ctrl-C, `&`, `jobs`
- ripgrep/fd/jq native ports; command registry v1 (~200 commands)
- Tabs, themes, fonts, hardware keyboard polish
- ✔ Demo: write & run a shell script with loops and functions; vim a file

### M3 — Runtimes
- CPython xcframework + pip (+ wheel index for binary wheels)
- nodejs-mobile engine + Node service + stdio/tty bridge
- `@termx/shim` child_process layer; **e2e: `npm install` a real package tree**
- ✔ Demo: `pip install rich` + run script; `npm init -y && npm i chalk` + run script

### M4 — Claude Code  *(the headline)*
- `claude` launcher: first-run npm install flow, login flow (browser session / token)
- Shim hardening against Claude Code's spawn/os/tty usage; Esc/interrupt; git via lg2
- ✔ Demo: open project folder → `claude` → agent edits files, runs tests, commits

### M5 — Linux lane
- Blink port (interpreter mode) + syscall/path patches
- Alpine minirootfs bootstrapper + `linux` command + PATH fallthrough
- ✔ Demo: `linux apk add cowsay figlet gcc` … and `linux` running the official Linux
  build of claude as Route-2 fallback

### M6 — Ship
- Licenses screen (generated), privacy label, review notes + demo video (C7 playbook)
- Onboarding (60-second tour), app icon/brand, App Store page
- Beta hardening: crash reporting (local, privacy-clean), perf passes
- Submit → respond → launch 🚀

### Post-1.0 seeds
- TermX Agent native UI (C5 Route 3) as premium feature
- Files.app provider for $HOME; iPad side-by-side agent+terminal
- RISC-V engine bake-off; SSH client command polish (`ssh`, `mosh`-alt)
- Mac Catalyst build (nearly free) → same app on Mac

## Suggested agent assignments (parallel tracks)

| Agent | Owns | First task | Depends on |
|---|---|---|---|
| **A1 UI** | C1 | SwiftTerm+pty demo package with echo engine | nothing |
| **A2 Core** | C2 | ios_system fork building in workspace + dispatcher API (`termx_run`) | nothing |
| **A3 Files** | C3 | WorkspaceManager + picker + bookmark tests | nothing |
| **A4 Runtimes** | C4 | CPython xcframework via BeeWare scripts | A2's API stub |
| **A5 Node/Claude** | C4-node + C5 | nodejs-mobile build + shim spec | A2's VirtualProcess API |
| **A6 Linux** | C6 | Blink compiling for iOS, run BusyBox `echo` in simulator | nothing |
| **A7 Release** | C7 + M6 | NOTICES tooling + review-notes draft | ongoing |

Integration owner (you + main agent): owns the Xcode workspace, the `termx_run` /
VirtualProcess API contract between A1/A2/A5 (freeze it early — it's the only hot
interface), and weekly on-device integration builds.

## Interface contracts to freeze in week 1

1. `termx_run(cmdline, stdin_fd, stdout_fd, stderr_fd, cwd, env[]) -> exit_code` + async
   variant with cancellation token (A1↔A2, A5↔A2).
2. `WorkspaceManager.resolve(path)` + mount-table semantics (A2↔A3).
3. Command registry JSON schema (A2↔A4↔A6).
4. Node service job API: `runNode(argv, cwd, env, fds, requireShim) -> exitCode` (A5).

## Definition of done (per component)

- Builds as its own Swift package / xcframework with tests green in CI (GitHub Actions,
  macOS runner, simulator tests).
- On-device smoke test checklist in the component doc updated.
- No red-list licenses (check against 07 doc) — CI script greps SPDX headers of new deps.
