# TetherWasm — wasm32-wasi command runner

Track P6. Self-contained C component: runs `wasm32-wasi` command-line programs
from a host application. No UI, no app-repo dependencies.

The point is that users can drop a `.wasm` CLI into `~/wasm/bin` and run it
without an app update. This component is the part that executes them.

---

## 1. Build and test

```sh
cmake -B build
cmake --build build -j
ctest --test-dir build --output-on-failure
```

Requires CMake ≥ 3.16 and a C11 compiler. No network access, no package
manager, nothing to vendor at build time — wasm3 is already in the tree.

Expected result:

```
55 checks, 0 failures
PASS
```

The prebuilt sample modules are committed, so the tests run without a WASI
toolchain. Rebuild them only if you change `sample/*.c`:

```sh
WASI_SDK_PATH=/path/to/wasi-sdk sample/build.sh
```

There is also a CLI driver for manual work:

```sh
./build/tether-wasm sample/hello.wasm
./build/tether-wasm --timeout 5000 --dir /tmp --env KEY=VAL module.wasm arg1
echo hi | ./build/tether-wasm sample/echo.wasm
```

---

## 2. The API

```c
#include "tether_wasm.h"

int tether_wasm_run(const char *wasm_path, char *const argv[], int argc,
                    const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd);
```

Runs the module to completion on the calling thread and returns its exit
status. This is the signature the track specified; everything below is
additive.

- `argv[0]` is the program name the guest sees. `argc == 0` is allowed — the
  guest then gets the module's filename as its only argument.
- `cwd` is preopened for the guest as both `.` and `/`. It cannot reach
  outside that directory. `NULL` means the host's current directory.
- The three fds are **borrowed** and never closed. Pass `-1` for any of them to
  give the guest an empty stdin or discard its output.
- Return value: the guest's exit status `0..255`, or a `TETHER_WASM_ERR_*`
  code ≥ 256 if the command could not be run. Never negative, so
  `rc != 0` is a reliable failure test.

### Extended entry point

```c
int tether_wasm_run_opts(..., const tether_wasm_options *options, char **error_out);
```

`options` may be `NULL`. `error_out` may be `NULL`; when it isn't, a failure
gives you a malloc'd message to release with `tether_wasm_free`.

| Option | Meaning |
|---|---|
| `envp` | `NULL`-terminated `KEY=VALUE` list. Default: the guest sees an **empty** environment; the host's is never leaked implicitly. |
| `timeout_ms` | Wall-clock limit. `0` = none. See §5. |
| `cancel_flag` | `const volatile int *`; set it non-zero from another thread to stop the guest. |
| `guest_dirs` / `host_dirs` | Extra preopened directories, beyond `cwd`. |
| `max_memory_bytes` | Linear-memory ceiling. Default 256 MiB. |
| `stack_bytes` | Interpreter stack. Default 256 KiB. |

### Error codes

| Code | Value | Meaning |
|---|---|---|
| `TETHER_WASM_ERR_ARGS` | 256 | Bad arguments from the caller |
| `TETHER_WASM_ERR_LOAD` | 257 | Module file missing or unreadable |
| `TETHER_WASM_ERR_COMPILE` | 258 | Not valid wasm, or uses unsupported features |
| `TETHER_WASM_ERR_LINK` | 259 | Needs an import the runner lacks |
| `TETHER_WASM_ERR_NO_ENTRY` | 260 | No `_start`: not a wasi *command* |
| `TETHER_WASM_ERR_TRAP` | 261 | Guest trapped |
| `TETHER_WASM_ERR_OOM` | 262 | Allocation failure |
| `TETHER_WASM_ERR_TIMEOUT` | 263 | Exceeded `timeout_ms` |
| `TETHER_WASM_ERR_CANCELLED` | 264 | `cancel_flag` was set |

### Integrating

Link `libtetherwasm.a` + `libtether_wasm3.a` and add
`Sources/TetherWasm/include` to your header path. Pure C11 + POSIX; no
Foundation, no Swift, no Objective-C. From Swift, import it through a bridging
header or a small SwiftPM system-library target — `tether_wasm.h` is plain C
and imports cleanly.

**Threading:** `tether_wasm_run` is fully reentrant. Concurrent calls on
different threads share no mutable state. Verified under ThreadSanitizer with
8 threads × 15 runs.

---

## 3. WASI coverage

`wasi_snapshot_preview1` (and `wasi_unstable`, which older toolchains emit).

Required by the track, all implemented and tested:
`args_get`, `args_sizes_get`, `environ_get`, `environ_sizes_get`, `fd_read`,
`fd_write`, `path_open`, `path_filestat_get`, `proc_exit`.

Also implemented, because real CLIs need them — wasi-libc calls `fd_seek` and
`fd_fdstat_get` during ordinary `printf`, and `fd_prestat_*` during startup, so
a runner without them cannot run a stock `hello.c`:

`fd_close`, `fd_seek`, `fd_tell`, `fd_fdstat_get`, `fd_fdstat_set_flags`,
`fd_filestat_get`, `fd_sync`, `fd_datasync`, `fd_readdir`, `fd_prestat_get`,
`fd_prestat_dir_name`, `path_create_directory`, `path_remove_directory`,
`path_unlink_file`, `path_rename`, `clock_time_get`, `clock_res_get`,
`random_get`, `sched_yield`, `poll_oneoff`, `proc_raise`.

**Not implemented:** sockets (`sock_*`), `path_symlink`, `path_readlink`,
`path_link`, `fd_pread`/`fd_pwrite`, `fd_advise`, `fd_allocate`,
`fd_filestat_set_*`, `path_filestat_set_times`, `fd_renumber`.

Unimplemented imports are deliberately left unlinked rather than stubbed. wasm3
only reports a missing import when the guest actually calls it, so a module
that merely *references* an unsupported function still runs — it fails only if
it truly needs it. `proc_raise` returns `ENOTSUP`; `poll_oneoff` honours clock
subscriptions (so `sleep()` works) and reports fd subscriptions as immediately
ready, which is right for blocking descriptors and avoids hanging a guest on a
wait we can't perform.

---

## 4. Design notes

### wasm3's own WASI layer is not used

wasm3 ships `m3_api_wasi.c`. It is excluded from the build and not vendored.
It keeps its state in a `static` global, hardcodes the host's real fds 0/1/2,
resolves paths against a fixed global preopen table, and leaves
`path_filestat_get` commented out. None of that can express this component's
contract: per-call `stdin_fd`/`stdout_fd`/`stderr_fd`, a per-call `cwd`, and
concurrent runs.

`Sources/TetherWasm/tether_wasi.c` replaces it. Every host function reaches its
state through the import context wasm3 passes in, so there are no globals and
guest fds are indices into a per-run table — a guest cannot name a host
descriptor the caller never handed it.

### Local changes to vendored wasm3

Only the interpreter core (11 `.c` files) is vendored, at the revision in
`Sources/CWasm3/WASM3_REVISION.txt`. There is exactly **one** local change,
marked `TETHER LOCAL CHANGE` in `Sources/CWasm3/include/m3_exec.h`:

> Upstream calls `m3_Yield()` only from the `Call` opcodes. A guest spinning in
> a loop that makes no calls therefore can never be interrupted. The `Loop`
> opcode now yields on each back-edge so the timeout can actually stop a
> runaway command.

Without it, `timeout_ms` does not fire on the most likely kind of hang. Re-apply
this when upgrading wasm3.

### Alignment and endianness

WASI guests may pass **unaligned** pointers into linear memory. wasm3's
`m3ApiWriteMem*` macros dereference them directly, which is undefined behaviour
and faults on strict-alignment ARM targets. All guest-memory access in
`tether_wasi.c` goes through byte-wise `tw_load_*`/`tw_store_*` helpers that are
alignment-safe and force little-endian, per the wasm spec. This was found by
fuzzing (UBSan flagged a misaligned store) rather than by inspection.

---

## 5. Operational guidance

**Set `timeout_ms` for anything you did not build yourself.** Nothing prevents a
wasm module from looping forever; with no limit `tether_wasm_run` never
returns. This is the single most likely way to hang the app.

**Sandboxing is directory-scoped, not a full jail.** A guest is confined to the
preopened directories: absolute paths and `..` escapes are rejected. However,
symlinks *inside* a preopened directory are followed by the host and could
point outside it. Preopen a directory you control. Concretely, preopen
`~/wasm/bin`'s data directory rather than the user's whole home.

**Blocking I/O is synchronous.** `tether_wasm_run` blocks its thread for the
lifetime of the command — call it off the main thread. If the guest reads a
stdin pipe nobody writes to, it blocks there; `cancel_flag` is how you get out.

**Guest exit codes and runner errors share one return value.** They are
disjoint by range (`≤ 255` vs `≥ 256`), so check the range before treating a
value as the program's own status.

---

## 6. Test coverage

`Tests/test_tether_wasm.c` — 55 checks. Output is captured through real pipes,
so the runner sees the kind of descriptors an embedder actually supplies.

The three required cases:

| Test | Result |
|---|---|
| `hello.wasm` | prints `hello`, exit 0 ✓ |
| bad path | non-zero (`ERR_LOAD`), plus directory / non-wasm / empty-path variants ✓ |
| read stdin | `echo.wasm` round-trips stdin, including the empty case ✓ |

Also covered: argv passing, environment (and that the host's env does **not**
leak), exit codes 0/7/255, stdout/stderr isolation, file reads inside `cwd`,
`..` and absolute-path escape attempts, `-1` descriptors, five repeated runs in
one process, default argv, timeout, cancellation, and a generous timeout not
misfiring.

### Verification performed

| Check | Result |
|---|---|
| Test suite | 55/55 pass |
| ASan + UBSan + LeakSanitizer | Clean |
| ThreadSanitizer, 8×15 concurrent runs | 0 races, 0 failures |
| Fuzzing: 2220 malformed/truncated/mutated modules | 0 crashes, hangs, leaks, or UB |
| Realistic CLI (file I/O, malloc, qsort, strtok, float math) | Output byte-identical to native build |
| Compiler warnings (`-Wall -Wextra`) | None in Tether code |

Two real bugs were found and fixed this way: the unaligned-store UB (§4) and
the uninterruptible-loop gap (§4).

---

## 7. Layout

```
TetherWasm/
├── CMakeLists.txt
├── LICENSE                       MIT + third-party notices
├── HANDOFF.md
├── Sources/
│   ├── CWasm3/                   vendored wasm3 interpreter (MIT)
│   │   ├── m3_*.c                11 core files; its WASI layer excluded
│   │   ├── include/
│   │   ├── LICENSE-wasm3.txt
│   │   └── WASM3_REVISION.txt
│   └── TetherWasm/
│       ├── include/tether_wasm.h public API — the only header to include
│       ├── tether_wasm.c         runner: load, link, _start, exit status
│       ├── tether_wasi.c         reentrant WASI implementation
│       ├── tether_wasi.h
│       └── tether_wasi_abi.h     preview1 constants and struct layouts
├── Tests/
│   ├── test_tether_wasm.c        55 checks
│   └── tether_wasm_cli.c         `tether-wasm` driver
└── sample/
    ├── hello.c/.wasm             prints hello (+ echoes argv)
    ├── echo.c/.wasm              stdin → stdout
    ├── exitcode.c/.wasm          exits with a chosen status
    ├── envcat.c/.wasm            dumps environ, or prints a file
    ├── spin.c/.wasm              infinite loop, for timeout tests
    └── build.sh                  rebuild the samples (needs wasi-sdk)
```

Naming: product **Tether** throughout, public API prefix `tether_wasm_*`,
internal WASI prefix `tw_*`. No legacy product name appears anywhere in the
tree.

---

## 8. Known limitations

- **Interpreter, not JIT.** wasm3 is roughly 4–15× slower than native. Fine for
  ordinary CLI work; not for heavy compute. This is the standard trade-off on
  iOS, where JIT is unavailable anyway.
- **No threads.** wasi-threads and shared memory are unsupported; build guests
  single-threaded.
- **No sockets.** Networking is out of scope for preview1 here.
- **wasm features:** MVP plus a few post-MVP proposals. No SIMD, bulk memory,
  reference types, or multi-value. `sample/build.sh` disables these explicitly;
  third-party modules built with a recent default-on toolchain may need the
  same flags. A module using them fails cleanly with `ERR_COMPILE`.
- **`fd_readdir` cookies** use `telldir` values, valid only within one open
  directory handle — standard for this approach, and fine for `readdir` loops.
- **Symlink caveat** in §5.
