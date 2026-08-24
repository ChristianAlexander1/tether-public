# C8 — Roadmap & Agent Work Split

**Goal:** Ship the **complete** product — all lanes, all integrations, App Store ready.
Milestones run in parallel where possible; see `13-parallel-agent-plan.md` for offline tracks.

## Milestones (all required)

### M1 — Walking skeleton
- Xcode project + SwiftUI shell
- C1: SwiftTerm + pty + resize + key toolbar
- C3: folder picker + bookmark persistence
- C2: dispatcher runs core commands with pipes & redirects
- ✔ Demo: open folder, `ls | grep foo > out.txt`, relaunch, access persists

### M2 — Full shell + native command tier
- mksh-class shell: history, completion, `.profile`, job control, Ctrl-C/Z
- ios_system xcframework + lg2 `git` + native `rg`/`fd`/`jq`
- TermXCommands wired (200+ commands)
- Tabs, themes, fonts, hardware keyboard
- ✔ Demo: shell scripts with loops/functions; vim a file; `git commit`

### M3 — Runtimes
- CPython xcframework + pip + iOS wheel index
- nodejs-mobile + Node service + full `@tether/shim` (generic spawn + openers)
- ✔ Demo: `pip install rich`; `npm init -y && npm i chalk`; `node-gyp` documented path

### M4 — Claude Code (headline)
- `claude` launcher, npm install, OAuth login, TUI rendering
- Shim covers all spawn patterns; Esc/double-Ctrl-C interrupt
- Route 2: `linux claude` via Blink where useful
- Route 3: TermX Agent skeleton (API-key + OAuth)
- ✔ Demo: open project → `claude` → edits files, runs tests, commits

### M5 — Linux engine (ios-linuxkit parity)
- Blink iOS + optional libriscv bake-off
- fakefs rootfs packaging (P4)
- Bind mounts: `/work` + `/workspaces/<name>`
- **Manifest exec dispatch (P5)** — replace hardcoded host lists; see `GUEST-PLATFORM.md`
- Harness acceptance suite (P7): BusyBox, apk top-200, pipelines, fork stress
- ✔ Demo: `apk add gcc python3 openssh`; build and run guest program; workspace R/W

### M6 — WASM + terminal polish
- wasm3/WASI runner + `~/wasm/bin`
- Terminal: DEC 2031, 80-col default, bracketed paste (P9)
- Ghostty Web evaluation / integration if beats SwiftTerm for TUIs
- ✔ Demo: install wasm `rg`; Claude Code TUI clean at 120 cols

### M7 — Ship
- Licenses screen, privacy label, review notes + demo video
- Physical device pass (iPhone + iPad)
- App Store submission — **full feature set enabled**
- Crash reporting (local), perf passes

## Agent assignments

| Agent | Owns | Track | Depends on |
|---|---|---|---|
| **Online P1–P12** | Standalone packages | `13-parallel-agent-plan.md` | nothing (parallel) |
| **A1 UI** | C1 + P9 terminal | SwiftTerm / Ghostty | nothing |
| **A2 Core** | C2 + P1/P2 merge | ios_system + shell | P1, P2 deliverables |
| **A3 Files** | C3 | bookmarks, mounts | nothing |
| **A4 Python** | C4-python | CPython + pip | A2 API |
| **A5 Node/Claude** | C4-node + C5 + P3/P10 | nodejs-mobile, claude | A2 API, P3 |
| **A6 Linux** | C6 + P4/P5/P7/P8 | Blink, fakefs, harness | P4, P5, P7 |
| **A7 Release** | C7 + M7 + P11 docs | legal, submission | ongoing |
| **Integrator** | I1–I3 | Xcode, Simulator, device | all tracks |

## Interface contracts (frozen — see 09-integration-contracts.md)

1. `termx_run(cmdline, stdin_fd, stdout_fd, stderr_fd, cwd, env[]) -> exit_code` + cancel
2. `WorkspaceManager.resolve(path)` + mount-table semantics
3. Command registry JSON schema
4. Node service job API + `@tether/shim` IPC keys
5. `termx_blink_mount(host, guest)` + **`tether_dispatch_manifest.json`** (P5)

## Definition of done

- Builds green in CI (macOS runner + simulator tests)
- Track acceptance criteria in `13-parallel-agent-plan.md` met
- No red-list licenses (`07-appstore-licensing.md`)
- `docs/LIMITATIONS.md` updated — gap closed or explicitly owned
