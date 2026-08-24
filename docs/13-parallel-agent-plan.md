# C10 — Parallel Agent Plan (self-contained briefs)

**Purpose:** Work packages you can hand to **online agents with no Mac, no Xcode, no repo
access**. Each brief is independent: deliver a folder + tests + `HANDOFF.md`. An integrator
on Mac merges into `~/Projects/tether`.

**Reference architecture:** [ios-linuxkit](https://github.com/rcarmo/ios-linuxkit) — study
folder layout and test discipline; **never copy GPL code**. Prefer the open-source projects
listed in each track.

**Platform contract (integrator):** [`GUEST-PLATFORM.md`](GUEST-PLATFORM.md) — default
guest ELF, manifest dispatch, generic URL openers — **not** per-tool hardcoding.

**Integrator (Mac + Xcode):** links xcframeworks, runs Simulator, wires packages into
`Tether.xcodeproj`. See `HOW-TO-RUN.md`.

**Agent paste-ready briefs:** [`agent-briefs/README.md`](agent-briefs/README.md) — one file per track.

---

## Track index

| ID | Name | Needs Mac? | Open-source anchors |
|---|---|---|---|
| **P1** | Command suite expansion | No | ios_system, GNU coreutils (study behavior), TermXCommands |
| **P2** | Shell language completeness | No | mksh, dash, POSIX spec |
| **P3** | Node `child_process` shim | No | nodejs `child_process` API, termx-shim |
| **P4** | Fakefs + rootfs tooling | No (Linux host) | ios-linuxkit fakefs *behavior*, libarchive |
| **P5** | Guest native-offload spec | No | ios-linuxkit native_offload *pattern* |
| **P6** | WASM command runner | No | [wasm3](https://github.com/wasm3/wasm3) MIT, [WasmKit](https://github.com/swiftwasm/WasmKit) Apache-2 |
| **P7** | Linux harness + syscall tests | No (Linux/macOS host) | Blink ISC, Alpine minirootfs |
| **P8** | libriscv guest engine spike | No (Linux host) | [libriscv](https://github.com/libriscv/libriscv) BSD-3 |
| **P9** | Terminal protocol + TUI fixes | Partial | SwiftTerm MIT, [Ghostty](https://github.com/ghostty-org/ghostty) MIT, xterm docs |
| **P10** | Generic spawn protocol fixtures | No | Node `child_process` API, xdg-utils opener semantics |
| **P11** | Architecture + validation docs | No | ios-linuxkit docs structure |
| **P12** | Native tier: rg/fd/jq iOS build scripts | Mac for final link | ripgrep MIT, fd MIT, jq MIT |
| **I1** | ios_system xcframework integration | **Mac** | [ios_system](https://github.com/holzschu/ios_system) BSD-3 |
| **I2** | Blink/iOS + mount table | **Mac** | Blink ISC, TermXLinux |
| **I3** | App integration + device pass | **Mac** | Tether repo |

---

## P1 — Command suite expansion

**Goal:** 200+ commands as pure Swift `CommandIO → CommandResult` (same pattern as
`External/TermXCommands`).

**Start from:** copy `External/TermXCommands/` structure.

**Add (priority order):** `curl` subset, `wget` subset, `tar` (in-process, no fork),
`zip`/`unzip` (via libarchive — **Apache-2**), `ssh` client subset (libssh2 **BSD** —
interface spec only if no native link yet), `scp` subset, `xargs`, `tee`, `cut`, `tr`,
`uniq`, `sort` enhancements, `env`/`printenv`, `which`, `type`, `test`/`[` parity,
`install`, `install`/`cp`/`mv` edge cases, `find` (minimal), `locate` stub, `watch`,
`time`, `nohup` (in-process), `flock` stub.

**Open source to read (behavior, not copy-paste):**
- [holzschu/ios_system](https://github.com/holzschu/ios_system) BSD-3
- [uutils/coreutils](https://github.com/uutils/coreutils) MIT (behavior reference)

**Deliverable:** `TermXCommands/` folder, 80+ new tests, `HANDOFF.md` with command list.

**Acceptance:** `npm test` equivalent = `swift test` on macOS; every command has ≥2 tests.

---

## P2 — Shell language completeness

**Goal:** Full POSIX-ish shell via `TermXShellLang` — match mksh/dash behavior for scripts
Claude Code and npm lifecycle scripts use.

**Start from:** `External/TermXShellLang/`.

**Implement / harden:**
- `case`/`esac`, `select`, `until`, functions with `local`, `return`, `$@`/`$*`, arrays (if
  needed for compatibility)
- `${var/pattern/repl}`, `${var#prefix}`, `${var%suffix}`, `${var:-default}`
- Arithmetic `$(( ))` full ops
- Here-docs with quoted delimiters, `<<-` tab strip
- `.` / `source`, `exec` builtin (replace shell with command — spec for integrator)
- `trap` (minimal — at least `trap '' INT` for subshells)
- Redirects on all compound commands (already started — extend)

**Open source:**
- [MirBSD/mksh](https://github.com/MirBSD/mksh) MirOS
- [emilycheng/toy-sh](https://github.com/emilycheng/toy-sh) (small reference)

**Deliverable:** `TermXShellLang/` + 60+ new tests.

**Acceptance:** run a `fixtures/` dir of 50 POSIX script snippets; all match expected stdout.

---

## P3 — Node `child_process` shim (complete surface)

**Goal:** `@termx/shim` covers **all** APIs npm and Claude Code use — not just spawn.

**Start from:** `External/termx-shim/`.

**Implement:**
- `spawn`, `exec`, `execFile`, `fork` (virtual — new V8 context, not OS fork)
- `spawnSync`, `execSync`, `execFileSync`
- `kill`, `abort`, signal forwarding spec
- `stdio: 'pipe'|'inherit'|'ignore'`, maxBuffer, encoding
- `shell: true` → `/bin/sh -c` mapping
- `detached`, `unref` (no-op with correct return semantics)
- IPC channel spec (`send`/`channel`) — document unsupported vs stub
- Windows-isms guarded (`shell: true` only)

**Open source:**
- Node.js `lib/child_process.js` (MIT)
- [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) MIT

**Deliverable:** `termx-shim/` + Jest tests (≥80), recorded fixture JSON for Claude Code
spawn sequences.

**Acceptance:** `npm test` green; fixture replay passes without network.

---

## P4 — Fakefs + rootfs tooling

**Goal:** Pack Alpine rootfs efficiently — ios-linuxkit-style fakefs without GPL code.

**Deliver:**
1. **`TermXFakefs/`** C library (MIT):
   - On-disk format spec (metadata index + content-addressed blobs + directory tree)
   - `fakefs_create(rootfs_tar.gz, output_dir)`
   - `fakefs_mount(output_dir, mount_point)` API (integrator calls from Blink VFS hook)
2. **`fakefsify` CLI** — works on Linux/macOS host
3. Tests: round-trip `alpine-minirootfs-3.20.x-x86_64.tar.gz`, verify 1000 random paths

**Open source:**
- [libarchive](https://github.com/libarchive/libarchive) BSD-2 (extract tar.gz)
- Study ios-linuxkit `tools/fakefsify.c` **behavior only** — reimplement clean room

**Deliverable:** standalone repo folder `TermXFakefs/` + Meson or CMake build.

**Acceptance:** `fakefsify alpine.tar.gz out/ && fakefs_verify out/` exits 0.

---

## P5 — Guest exec dispatch (manifest + C registry)

**Goal:** Replace hardcoded `path_is_host_backed()` strcmp lists with a **manifest-driven**
dispatch layer (ios-linuxkit `native_offload.c` **pattern only** — read for API design,
do not copy GPL code).

**Default:** every `execve` → **guest ELF**. Only manifest rows override.

**Deliver:**
1. **`TetherDispatch/`** header + C implementation:
   - Load `tether_dispatch_manifest.json` at init
   - `browser_openers[]` → host URL opener (any https/file URL)
   - `host_runtimes[]` → host handler (node-mobile, etc.) — **never** git/python/gcc
   - `tether_dispatch_resolve(argv[0]) → guest | url_opener | host_runtime`
   - Socket protocol compatible with existing `termx_blink_bridge.c` host exec channel
2. Manifest schema documented in `SPEC.md` (see `GUEST-PLATFORM.md` §3)
3. Swift wrapper to register host handlers from TermXNode / TermXFiles
4. Tests on Linux host with mock guest exec

**Deliverable:** `TetherDispatch/` + `SPEC.md` + unit tests.

**Acceptance:** manifest with only `node`/`npm`/`claude`/`open`/`xdg-open` entries;
`git`, `python3`, `gcc` resolve to **guest** even if present in guest PATH.

---

## P6 — WASM command runner

**Goal:** wasm32-wasi commands in `~/wasm/bin` — a-Shell's extensibility model.

**Deliver:**
1. **`TermXWasm/`** Swift package **or** C core + Swift bindings:
   - Embed [wasm3](https://github.com/wasm3/wasm3) (MIT) or document WasmKit integration
   - WASI snapshot preview1: `args`, `environ`, `fd_read`, `fd_write`, `path_open`,
     `path_filestat_get`, `proc_exit`
   - Map WASI fds to host sandbox paths (workspace-scoped)
2. `termx_run_wasm(path, argv, env, fds) -> exit_code` C API
3. Sample wasm module: `hello.wasm` compiled from Rust or C

**Open source:**
- [wasm3](https://github.com/wasm3/wasm3) MIT
- [bytecodealliance/wasi-sdk](https://github.com/WebAssembly/wasi-sdk) Apache-2

**Deliverable:** `TermXWasm/` + build script for sample `.wasm` + 20 tests.

**Acceptance:** `./termx_wasm_test hello.wasm` prints `hello` on macOS/Linux.

---

## P7 — Linux harness + syscall acceptance tests

**Goal:** Host-side test runner (like ios-linuxkit's `ish` binary) — no iOS required.

**Deliver:**
1. **`termx-linux-harness/`** — links Blink (build on Linux x86_64 or macOS):
   - `termx-harness -r ROOTFS /bin/sh -c 'uname -a'`
   - Mount test dir at `/work`
   - Exit code + stdout capture
2. **`tests/fixtures/`** — shell scripts:
   - `apk add git` (needs network — mark optional)
   - pipelines, fork bomb (bounded), socket connect curl example.com
   - BusyBox `--install -s` self-test
3. **`SYSCALL-GAP-LOG.md`** — failing tests → syscall needed

**Open source:**
- [jart/blink](https://github.com/jart/blink) ISC
- Alpine minirootfs (user download)

**Deliverable:** harness + 30 fixture scripts + gap log.

**Acceptance:** `make test` runs ≥20 fixtures offline against bundled minirootfs.

---

## P8 — libriscv guest engine spike

**Goal:** Prove riscv64 Alpine runs faster/simpler than x86 Blink — data for engine choice.

**Deliver:**
1. **`TermXRiscv/`** — libriscv embedded, load riscv64 static binary
2. Run `/bin/uname` from `alpine-minirootfs-*-riscv64.tar.gz`
3. Benchmark vs Blink x86 on same host (simple timer)
4. **`REPORT.md`**: speed, package availability, integration effort estimate

**Open source:**
- [libriscv](https://github.com/libriscv/libriscv) BSD-3

**Deliverable:** spike repo + report. No iOS required for spike.

---

## P9 — Terminal protocol + TUI fixes

**Goal:** Claude Code and vim render correctly — fix DECSET 2031, width, smashed text.

**Deliver:**
1. **`TERMINAL-PROTOCOL.md`** — document every escape Claude Code / Ink sends; map to
   SwiftTerm support matrix
2. **Patch set** for SwiftTerm fork OR wrapper in `TermXUI`:
   - DEC private mode 2031 (ignore or implement)
   - Minimum 80 cols default; SIGWINCH on layout
   - Bracketed paste, focus events
3. Evaluate **Ghostty Web** (MIT) in WKWebView vs SwiftTerm — pros/cons doc
4. Tests: VT100 state machine unit tests (pure Swift, no UI)

**Open source:**
- [swiftterm/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) MIT
- [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) MIT
- [hediet/vscode-debug-visualizer](https://vt100.net/neo/) — xterm spec

**Deliverable:** `TermXTerminal/` docs + Swift patches + 25 parser tests.

---

## P10 — Generic spawn protocol fixtures (JavaScript)

**Goal:** Replay **any** Node CLI spawn pattern against `@tether/shim` — URL openers,
`child_process.spawn`, PATH resolution — without baking in vendor-specific logic.

**Deliver:**
1. **`tether-spawn-fixtures/`** — JSON recordings:
   - URL opener: `open` / `xdg-open` + `https://…` (OAuth URL is one example only)
   - Generic spawn: `git status`, `rg`, `bash -c` pipelines (assert IPC shape, not tool names)
   - MCP stdio spawn pattern
2. Mock host backend understands **opener basenames** + **spawn argv** — not “if claude”
3. **`SPAWN-PROTOCOL.md`** — what the shim must send to host for each pattern
4. Jest tests replay all fixtures against mock backend

**Open source:** Node.js MIT; [Freedesktop xdg-utils](https://www.freedesktop.org/wiki/Software/xdg-utils/) opener semantics.

**Deliverable:** `tether-spawn-fixtures/` + tests + docs.

**Acceptance:** `npm test` green offline; no fixture runner branches on `claude`/`git` by name.

---

## P11 — Architecture + validation docs

**Goal:** ios-linuxkit-quality documentation for Tether.

**Write (markdown only):**
1. **`docs/ARCHITECTURE.md`** — data flow diagram: pty → shell → registry → lanes
2. **`docs/LIMITATIONS.md`** — current gaps with owner track ID; update as tracks close
3. **`docs/VALIDATION.md`** — how to run all test suites; release checklist
4. **`docs/RELEASES.md`** — versioning, TestFlight, App Store notes template

**Reference structure:** ios-linuxkit `docs/` folder (GPL repo — structure only).

**Deliverable:** four markdown files, no code.

---

## P12 — Native tier: rg/fd/jq for iOS (build scripts)

**Goal:** Static libraries + C bridge for in-process `rg`, `fd`, `jq`.

**Deliver:**
1. **`TermXNativeTools/`** — Rust/C cross-compile scripts:
   - `ripgrep` → static lib, expose `rg_main(argc, argv)` (MIT)
   - `fd` → same (MIT)
   - `jq` → same (MIT)
2. `build-ios.sh` (needs Xcode SDK on Mac for final step — script runs on Mac)
3. Linux host can build and run host tests without iOS SDK

**Open source:**
- [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) MIT
- [sharkdp/fd](https://github.com/sharkdp/fd) MIT
- [jqlang/jq](https://github.com/jqlang/jq) MIT

**Deliverable:** scripts + host smoke tests; iOS slice when Mac available.

---

## I1–I3 — Mac integrator tracks (repo required)

### I1 — ios_system xcframework
- Fork [ios_system](https://github.com/holzschu/ios_system) BSD-3 into `Vendor/ios_system`
- Build xcframework; register top 50 commands in `TermXCore`
- Wire lg2 for `git`

### I2 — Blink/iOS + full mount table
- `termx_blink_mount` for every workspace bookmark
- Fakefs VFS hook from P4
- Native offload from P5
- Multi-session queue (or document single-session until fixed)

### I3 — App integration + ship
- Merge P1–P12 deliverables
- Physical device checklist (`docs/DEVICE-PASS.md`)
- App Store submission with full Linux lane enabled

---

## Dependency graph (what can run in parallel)

```text
P11 (docs) ─────────────────────────────► anytime

P1 (commands) ────┐
P2 (shell)     ───┼──► I1 (ios_system merge)
P3 (shim)      ───┼──► I3 (Claude e2e)
P6 (wasm)      ───┘

P4 (fakefs) ──► I2 (Blink mounts)
P5 (offload) ──► I2
P7 (harness) ──► I2 (syscall gaps)
P8 (riscv)   ──► engine decision ──► I2

P9 (terminal) ──► I3 (TUI polish)
P10 (claude)  ──► I3 (login e2e)
P12 (rg/fd)   ──► I1
```

---

## How to hand off to an online agent

Copy **one track section** above plus this boilerplate:

```text
You are building track [PX] for Tether (iOS terminal app).
You do NOT have the repo or a Mac. Create a standalone folder with code, tests, and HANDOFF.md.
License: MIT for your new code. Do not copy GPL source.
When done, zip the folder for merge into ~/Projects/tether/External/ or Vendor/.
Acceptance criteria are in the track description — all must pass.
```

---

## Success definition (complete product — not a partial release)

- [ ] Alpine login shell; `apk add` top-200 packages pass harness
- [ ] Every bookmarked folder mounted at `/workspaces/<name>`
- [ ] `claude` login + edit + commit on device
- [ ] ios_system native tier OR 200+ Swift commands — user cannot tell the difference
- [ ] WASM `~/wasm/bin` works
- [ ] TUI: Claude Code + vim usable at 80+ cols
- [ ] Native offload registry documented and extensible
- [ ] fakefs rootfs option shipped
- [ ] ARCHITECTURE + LIMITATIONS + VALIDATION docs maintained
- [ ] Physical iPhone + iPad pass
- [ ] App Store submission with Linux lane enabled
