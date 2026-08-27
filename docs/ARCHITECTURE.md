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
