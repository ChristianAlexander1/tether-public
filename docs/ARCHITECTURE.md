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
        └── manifest host runtime ─► Node / Claude / wasm3 service
                                           │
                                           └── TJIP/2 (TetherJobIPC <-> tether-shim-v2)
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
runtimes are the only exceptions. Git, Python, GCC, ripgrep, package managers,
and future `apk` packages are not named in host source code.

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
