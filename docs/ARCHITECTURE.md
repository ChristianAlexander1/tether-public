# Architecture

## Runtime shape

```text
SwiftUI + SwiftTerm
        ▲ forward bytes                    ▲ restore sequence on abnormal exit
        │                                  │
   TetherVTEngine ── replies (DA/DECRQM/XTGETTCAP) ──► PTY
        ▲ PTY bytes
        │                    TetherSessionCore ── ordered lifecycle + teardown
        │                    TetherStorageCore ── managed areas, delete leases
        │
LinuxShellEngine ── workspace confinement ── iOS Documents/security scope
        │
        ▼
Blink x86-64 Linux machine + writable Alpine rootfs
        │ execve
        ├── default ───────────────► guest ELF
        ├── desktop opener ────────► SystemOpen ─► in-app Safari/document UI
        └── manifest host runtime ─► Python / Node / Claude / wasm3 service
                                              │
                                              └── TJIP/2 for Node/Claude
                                                  (TetherJobIPC <-> tether-shim-v2)
                                                  framed JSON: handshake, tty,
                                                  spawn, flow control
```

The primary terminal is an Alpine login shell. Blink interprets guest machine
code; downloaded ELF files are never loaded as native iOS code. The selected
workspace is mounted at `/work`, and host-path mapping rejects prefix confusion,
`..` traversal, and symlink escape.

## Session ownership and startup

`WorkspaceView` creates exactly one `SessionCommandRunner` for an open
workspace. The runner is the only owner of the startup and teardown sequence:

```text
workspaceOpened
  -> acquire rootfs lease + bootstrap Linux once
  -> create and start TerminalSession once
  -> attach the renderer and replay validated saved scrollback
  -> active
```

The view must never start `TerminalSession` directly or manufacture
`bootstrapSucceeded` / `shellStarted` events. Completion events come only from
the operation that actually completed. This prevents concurrent rootfs mounts
and duplicate Blink initialization, which are unsafe because the embedded
runtime is process-global.

The lifecycle services retain the live terminal session until ordered teardown
finishes. A rootfs lease is acquired before bootstrap begins and released only
after the output reader has stopped and the PTY has closed. Bootstrap and shell
failures release the same lease and workspace scope, so retry loops do not leak
resources.

## Execution policy

`Packages/TermXLinux/.../tether_dispatch_manifest.json` is the single dispatch
policy. `default` is `guest_elf`. Browser opener basenames and packaged host
runtimes are the only exceptions. Python and pip are explicit packaged-runtime
entries; Git, GCC, ripgrep, Alpine package managers, and future `apk` packages
remain ordinary guest ELF programs and are not named in host source code.

BusyBox-style symlinks under guest `/usr/local/bin` make packaged host runtimes
discoverable to normal Linux PATH resolution. The manifest exec hook resolves
those names before loading BusyBox; unrelated Linux utilities remain untouched.

## Runtime lanes

| Lane | Implementation | Why it exists |
|---|---|---|
| Linux | Blink + writable Alpine minirootfs | normal shell, packages, processes, sockets |
| Python | embedded CPython framework | fast iOS-safe Python without guest startup |
| Node | nodejs-mobile, one serialized engine | libuv runs directly on native Darwin facilities for full speed |
| Claude | real Claude package adapted to embedded Node | product CLI with persistent install and auth state |
| WASI | wasm3 + explicit WASI context | arbitrary workspace modules without module allow-lists |

Node’s `os` module forwards the real embedded runtime. Only `HOME`, `TMPDIR`,
TTY state, standard opener commands, and process creation are adapted because
those are properties of the Tether session and its process model.

Claude's official standalone executable is extracted into a split ESM graph.
`TermXClaude` owns the compatibility boundary between Bun's embedded-file
loaders and Node: Markdown and text imports return UTF-8 strings, opaque
`.asset` imports return their extracted paths, and unsupported native add-ons
use the documented embedded-runtime fallback. The Node engine persists across
shell commands, while its job shim restores `Module._load` after each command;
the Claude launcher therefore records the actual wrapper function and
reinstalls it whenever that function is no longer active. A two-invocation JS
regression exercises both the asset semantics and this teardown/relaunch path.
Because Node built-in ESM imports bypass `Module._load`, the TJIP/2 loader also
publishes its native-loader link. The launcher uses that link with
`syncBuiltinESMExports()` so Claude's ESM command runner receives the same
`child_process`, `tty`, and `os` implementations as CommonJS. TJIP children
implement chainable `ref()`/`unref()` no-ops: their shared session transport is
already unreferenced, while standard opener/execution libraries still require
the Node `ChildProcess` method contract.

Every persistent Node job starts with fresh-process exit semantics:
`process.exitCode` is `undefined`, even when the prior job set or returned an
exit code. `process.exit()`, `process.abort()`, and a signal sent by
`process.kill()` to the embedded process itself unwind only the current job.
This boundary is essential because Node and Tether share one native process;
a CLI fallback such as `process.kill(process.pid, "SIGKILL")` must never kill
the iOS app. Signals to non-self processes still use the native implementation.

Python and pip run through one serialized embedded CPython service. `python`
normalizes to `python3`, and both `pip` spellings normalize to
`python3 -m pip`. The first pip invocation extracts the bundled wheel directly
into the environment-selected `PYTHONUSERBASE` without `fork()` and without
leaking its expected import probe to the user's PTY.

## The terminal contract with host-run jobs

A job run on the host lane does not sit under the guest's controlling terminal,
so nothing in the kernel tells it about the session. Three facts are therefore
delivered explicitly, over TJIP/2:

- **Which fds are terminals.** The handshake reports the fds actually bound to
  the PTY, tested with `isatty(2)` on the real descriptors. It is per-fd, so
  `claude | tee log` sees an interactive stdin and a piped stdout.
- **Geometry, pushed not polled.** A resize travels
  `TerminalSession.resize` -> integration -> the live IPC server -> `tty.resize`,
  which updates every stream and raises `SIGWINCH` inside Node.
- **Signals.** Ctrl-C on the PTY reaches the foreground job through
  `TetherJobControl`'s job table, which also owns the TERM->KILL->orphan
  escalation.

Terminal Return is byte `CR` (`0x0d`). This matters for full-screen selection
prompts such as Claude's workspace-trust dialog: sending line-feed (`0x0a`)
looks like Enter in shell-oriented tests but does not confirm an Ink menu. The
UI and the simulator acceptance harness therefore send the same terminal key
byte.

## The controlling terminal and guest process groups

An iOS app cannot make the PTY it owns its Darwin controlling terminal: there
is no `setsid()` + `TIOCSCTTY` path available to it, and the app's own session
must not be rearranged anyway. Upstream Blink correctly forwards `/dev/tty`,
`tcgetsid`, `tcgetpgrp` and `tcsetpgrp` straight to the host, which is right
for its CLI and wrong here — every one of those failed with `ENOTTY`, so
BusyBox `ash` printed `can't access tty; job control turned off` and ran with
no job control at all.

`Frameworks/patches/blink-ios-embedded-tty.patch` moves that boundary into the
emulator for embedded iOS builds only (`TERMX_EMBEDDED_IOS`), and
`Frameworks/build-blink.sh` re-derives it from the pinned upstream commit on
every build:

- Guest `/dev/tty` resolves to the already-open PTY slave on fd 0. For the one
  embedded session, that file description *is* what a controlling terminal
  open should return.
- `tcgetsid` / `tcgetpgrp` / `tcsetpgrp` fall back to the bridge only when the
  host call fails with `ENOTTY` on a real tty, so nothing changes for the host
  CLI lane.

The bridge keeps that state in a `MAP_SHARED | MAP_ANON` page. Sharing is not
an optimization: `ash` sets the foreground process group from inside a forked
child, and the app parent — which is where terminal keystrokes arrive — has to
see that write. Private memory is why `jobs`, `bg` and `fg` could not work.

### Delivering a terminal signal

A guest job is a real Darwin process, so `termx_blink_terminal_signal` does
what a line discipline does: signal the recorded foreground process group.
Blink mirrors each guest signal disposition onto its host process in
`SysSigaction`, so the real host signal is the faithful equivalent — a guest
handler runs through Blink's `OnSignal`, and a guest default action becomes
the host default action on that child. Two details are not obvious:

- **A forked guest process must be given an empty signal mask.** The emulator
  runs on a libdispatch worker thread, and libdispatch blocks every
  asynchronous signal on its workers so signals reach the main thread instead.
  A fork child inherits that mask and silently defers `SIGINT`, `SIGTERM` and
  `SIGTSTP` forever; only `SIGKILL` and `SIGSTOP`, which cannot be blocked,
  had any effect. This is why Ctrl-C did nothing while Ctrl-Z worked. The
  patched `fork()` calls `termx_blink_guest_child_started` in the child before
  any guest code runs, and the bridge clears the mask there.
- **Ctrl-Z sends `SIGSTOP`, not `SIGTSTP`.** A job-control shell ignores
  `SIGTSTP`; its child inherits that host `SIG_IGN` before resetting its own
  dispositions, and a real `SIGTSTP` is measurably swallowed. Nothing is lost:
  a program that wants to handle Ctrl-Z itself clears `ISIG`, and the UI layer
  then passes the keystroke through as a byte rather than asking for a
  terminal signal.

When the foreground group is the app's own group the login shell itself is in
the foreground, and the signal is queued straight into the active machine
instead — the app must never signal its own process group.

`TerminalSession.terminalSignalsEnabled` reads the PTY's real `ISIG` bit, so
the decision between "this keystroke is a terminal signal" and "this keystroke
is a byte for a full-screen program" comes from the line discipline rather
than from a guess about what is running.

### Reaping guest processes

Background and stopped guest jobs outlive their shell, and iOS reparents them
rather than ending them with the app; a sandboxed app also cannot enumerate
its own descendants to find them. Because the shared page is inherited by the
whole fork tree, each guest process records its own pid there as it starts, so
even a grandchild is visible to the app. `termx_blink_reap_guest_children`
walks that set on `SIGCONT`+`SIGTERM`, then `SIGKILL`, and reaps by pid —
never `waitpid(-1)`, which would consume exit statuses belonging to Node and
Foundation child processes in the same app. It runs when the login shell run
returns, on workspace teardown, and on `UIApplication.willTerminate`. An
outright kill of the app (force quit, `simctl terminate`, memory pressure)
runs no cleanup code at all and still orphans guest jobs; that is a property
of `SIGKILL`, not something the app can intercept.

`TETHER_TTY_TRACE=1` prints the foreground-group and signal decisions to
stderr. It is a diagnostic for this boundary and emits nothing unless set.

`TetherVTEngine` watches the returning byte stream for the modes a full-screen
program turns on (alternate screen, hidden cursor, mouse reporting, bracketed
paste). When a job exits without clearing them, the engine synthesizes the exact
reset sequence the program owed and feeds it back through the session's output
path, so the repair is both rendered and recorded in the scrollback snapshot.
Saved scrollback replay is a separate startup operation: it is buffered until a
renderer attaches and is deliberately not recorded again, avoiding duplicated
snapshots on every reopen.

## Component placement

- `Packages/` contains app runtime packages.
- `External/` contains independently buildable components and protocol suites,
  including the rework-plan components: `TetherVTEngine`, `TetherJobIPC`,
  `TetherJobControl`, `TetherSessionCore`, `TetherStorageCore`,
  `tether-shim-v2` and `tether-bun-compat`. Each builds and tests standalone;
  anything Darwin-only lives behind a protocol the app implements.
- `Vendor/` contains clean-room C libraries, integration harnesses, reproducible
  build scripts and evaluated alternate runtimes.
- `Frameworks/` contains build recipes, notices, headers and ignored local binary
  artifacts.

## Runtime ownership map

| File or component | Responsibility | Calls into |
|---|---|---|
| `App/TetherApp.swift` | workspace/session UI, lifecycle wiring, DEBUG-only simulator input harness | `TermXUI.TerminalSession`, `SessionCommandRunner` |
| `Packages/TermXUI/Sources/TermXUI/TermXUI.swift` | `TerminalSession`: PTY lifetime, input bytes, resize and renderer feed | `TetherVTEngine`, selected `TerminalEngine` |
| `App/IntegrationSource/TermXIntegration.swift` | composition root and host-runtime dispatch | Python, Node, Claude, WASI services |
| `Packages/TermXLinux/.../LinuxShellEngine.swift` | Alpine login shell, `/work` mount, manifest launcher bridge | Blink and app host dispatch closure |
| `Packages/TermXLinux/.../tether_dispatch_manifest.json` | the only basename-to-host-handler policy | Node, Claude, Python/pip, WASI, openers |
| `Packages/TermXNode/.../bootstrap.js` | persistent Node job boundary and TJIP/2 shim install/restore | `TetherJobIPC`, `tether-shim-v2` |
| `Packages/TermXClaude/.../launcher.js` | Claude's Bun-asset compatibility and embedded loader repair | persistent Node service |
| `Packages/TermXPython/.../TermXPython.swift` | CPython argv/env normalization and pip bootstrap | `TermXPythonBridge` |
| `Packages/TermXLinux/Sources/TermXBlinkBridge/termx_blink_bridge.c` | embedded guest exit/signal boundary and guest-to-host exec IPC | Blink static runtime, Swift dispatch callback |

The per-package `HANDOFF.md` files document each package's internal files and
test commands; this table is the cross-package connection map.

P2 `TetherShellLang` deliberately evaluates against an in-memory filesystem, so
it is a parser conformance oracle rather than the product shell. The production
bridge uses real descriptors. P9 `TetherTerminal` is similarly a terminal
protocol oracle; SwiftTerm remains the renderer, and the UI gate feeds critical
streams to both implementations.

P4 fakefs is a real POSIX-metadata store. It becomes the active rootfs base
once its writable upper layer lands, giving `apk add` full Linux semantics on
top of it. P8 RISC-V remains an engine study because Blink is the selected
x86-64 platform.

## Persistence and migration

The Alpine rootfs and runtime installs live in the app container. Startup
migration removes only exact files generated by earlier Tether development
builds (fake uname/hostname wrappers, forced Git configuration and obsolete
browser modules). User-created or modified files are not broadly deleted.

## Licensing

Bundled code and dependencies must be App-Store-compatible. Clean-room Tether
implementations do not copy code from GPL emulators. Notices for native
frameworks live in `Frameworks/NOTICES` and the app licenses view.
