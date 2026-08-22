# HANDOFF — WP-A `termx-shim`

A self-contained Node.js shim for TermX that replaces `child_process` (plus `os` and
`tty`) with a JSON IPC channel to the app's in-process command engine, so `npm install`
and Claude Code can run inside an iOS app where OS child processes are forbidden.

**Built & verified against Node v20.20.2. No third-party dependencies. `npm test` passes.**

---

## 1. What was implemented

### Folder layout
```
termx-shim/
├── package.json          # name "@termx/shim", type "commonjs", scripts.test
├── index.js              # installs Module._load overrides (entry point)
├── lib/
│   ├── child_process.js  # full replacement module
│   ├── os.js             # platform overrides
│   ├── tty.js            # isatty overrides
│   └── ipc.js            # transport: request → reply (roundTrip)
└── test/
    ├── mock-backend.js   # fake engine implementing the protocol
    ├── child_process.test.js
    ├── index.test.js
    ├── ipc.test.js       # real wire protocol over a Unix socket (subprocess)
    ├── os.test.js
    └── tty.test.js
```

### `child_process` — complete, Node-accurate
- **`spawn`** returns a `ChildProcess` (`EventEmitter`) with `stdout`/`stderr` as
  readable streams (fed once then ended) and `stdin` as a writable; properties `pid`,
  `exitCode`, `signalCode`, `killed`; methods `kill(signal)`, `ref()`, `unref()`,
  `hasRef()`. Emits `'spawn'` → `'exit'` → `'close'` in that order, asynchronously on a
  later tick (so callers can attach listeners first). Failed starts emit `'error'` (and
  `'close'`), **not** `'exit'`.
- **`spawnSync`** returns `{ pid, output: [null, stdout, stderr], stdout, stderr,
  status, signal, error }` with Buffers unless an `encoding` says otherwise.
- **`exec` / `execFile`** callbacks receive `(error, stdout, stderr)`; non-zero exit sets
  `error.code` (exit status) and `error.killed`; stdout/stderr always populated.
- **`execSync` / `execFileSync`** throw on non-zero exit with `status`, `signal`,
  `stdout`, `stderr` and a `message` ending with the command; return stdout on success.
- **`fork`** returns a `ChildProcess` with the IPC surface (`send`, `disconnect`,
  `'message'`). See the documented limitation below.
- Argument normalisation for every documented call form: `(file)`, `(file, args)`,
  `(file, options)`, `(file, args, options)`, callback variants for `exec`/`execFile`,
  object-as-options for the `*Sync` file variants.
- Options honoured: `cwd`, `env`, `shell` (`true` → `sh -c`, or an explicit path),
  `stdio` (`'pipe'`, `'inherit'`, `'ignore'`, and array forms), `encoding`
  (incl. `'buffer'`), `input` (sync variants), `maxBuffer` (exceeding it → error code
  `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`), `timeout` + `killSignal`, `argv0` (sent),
  `windowsHide` (accepted, ignored — irrelevant on iOS).
- A missing command produces an `Error` with `code: 'ENOENT'`, `errno: -2`,
  `syscall: 'spawn <file>'`, `path: <file>`.
- Shell command reconstruction and quoting for `shell: true` matches Node's behaviour
  (tokens are shell-quoted; the whole `file + args` becomes the `sh -c` body).

### `os` overrides
`platform()` → `'darwin'`, `type()` → `'Darwin'`, `arch()` → `'arm64'`, `homedir()` from
`HOME`, `tmpdir()` from `TMPDIR`, plus `release()`, `cpus()`, `totalmem()`, `freemem()`,
`endianness()` → `'LE'`, `EOL` → `'\n'`. Everything else passes through to real `os`
(e.g. `networkInterfaces`, `constants`, `hostname`, `loadavg`).

### `tty` overrides
`isatty(fd)` → `true` only for fds 0/1/2 **and** `TERMX_INTERACTIVE === '1'`, else
`false`. `isTTY` mirrors that; `ReadStream`/`WriteStream` are real-tty passthrough.

### `ipc` transport (lib/ipc.js)
One synchronous function, `roundTrip(requestObject) -> replyObject`, so the transport is
swappable in tests via `setTransport(fn)` / `clearTransport()`. Request = one
`JSON + '\n'` line; reply = one `JSON + '\n'` line. Transport selected in this order:
1. Injected transport (tests only).
2. `TERMX_IPC_SOCKET` (Unix socket).
3. `TERMX_IPC_FD` / `TERMX_IPC_REPLY_FD` (fallback fd transport).

---

## 2. Deliberately left out / known limitations (documented, not stubbed)

These are real protocol limitations, listed honestly rather than silently faked:

- **Incremental stdout/stderr streaming.** The app returns `stdout`/`stderr` as complete
  strings once the command finishes. `spawn`'s streams are therefore fed once and ended.
  Live streaming is a future protocol addition; `ChildProcess` still exposes the correct
  stream API. `^C`-style interactive control (writing repeatedly to a live child's
  stdin) is not possible until the protocol supports it.
- **`fork()` IPC messaging.** There is no message stream in the wire protocol, so
  `child.send(msg)` returns `false` and `'message'` events never fire. The object shape
  (send/disconnect/connected) is faithful. `fork` spawns the configured node executable
  (see `TERMX_NODE_EXEC`, below) to run the module; it only works if the host's command
  engine can actually run that executable.
- **`timeout` / `killSignal`.** Because the bus is a synchronous request/reply that
  blocks until the engine replies, the shim **cannot** enforce a timeout locally. It
  sends `timeout` and `killSignal` as extra request fields and the **engine is expected to
  honour them** (kill the in-flight command and reply with
  `{ signal: <killSignal>, exitCode: null }`). The mock backend implements exactly this.
  If the app does not yet honour these fields, a long command will block and `timeout`
  will not interrupt — see the "must wire up" section.
- **`kill(signal)` on a still-running process.** Given synchronous semantics, by the time
  `spawn` returns a handle the command has already run to completion, so `kill()` returns
  `false` (matching Node's behaviour of not killing a finished child). The `signal` op is
  still sent (and tested) over the wire for the case where the engine supports it.
- **Platform constants.** `os` returns a handful of plausible virtual values; it does not
  model a full macOS `uname`/sysctl.

---

## 3. The exact test command and its real output

Command:
```bash
cd termx-shim && npm test
```
(i.e. `node --test test/*.test.js` using the built-in `node:test` runner.)

Real output (Node v20.20.2):
```text
# tests 48
# suites 0
# pass 48
# fail 0
# cancelled 0
# skipped 0
# todo 0
# duration_ms 473.765487
```

All 48 tests pass, including: the 10 items required by the spec (`spawn` stdout + ordering,
missing-command `ENOENT` shape, `spawnSync` with `input` + Buffer/string encoding, `exec`
success + non-zero exit, `execSync` throwing with `status`/`stdout`/`stderr`, `maxBuffer`
→ `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`, `timeout` reporting the signal, `shell: true`
routing through `sh -c`, `stdio: 'inherit'`/`'ignore'`, and `os`/`tty` for both
`TERMX_INTERACTIVE` values), plus a real end-to-end over-the-wire Unix-socket test with the
mock engine running as a separate process.

### True-to-life bootstrap smoke (not part of `npm test`, run manually)
```bash
node test/mock-backend.js /tmp/smoke.sock &   # mock engine
TERMX_IPC_SOCKET=/tmp/smoke.sock node --require ./index.js -e '...'
```
Result of the simulation of the app boot (real Unix socket, bare `require('child_process')`):
```text
same impl: true
spawnSync: {"status":0,"stdout":"hello from TermX\n"}
os: darwin arm64 Darwin
tty.isatty(1): false -> 0
```
This is the closest replication of the real app usage: `--require index.js` patches
`Module._load`, both `child_process` spellings resolve to the shim, and synchronous
request/reply works over the socket.

---

## 4. Assumptions made about the protocol / interfaces

1. **`op: 'spawn'` vs `'spawnSync'`.** The spec lists `spawn`, `spawnSync`, `signal`. I
   use `'spawnSync'` for the sync functions and `'spawn'` for the async ones; both use the
   same reply shape (`pid`, `exitCode`, `stdout`, `stderr`, `signal`, `error`, `code`,
   `encoding`). If the app only accepts one op name, both should be mapped to the same
   handler — note this and keep them equivalent.
2. **Extra request fields the app may not know about:**
   - `input` — required so `spawnSync`/`spawn` can deliver stdin, since replies return full
     strings. If the app already pipes stdin some other way, ignore this field.
   - `timeout` and `killSignal` — REQUIRED for `timeout` to function (see limitations).
   - `encoding` — echoes the requested output encoding back so the engine can return the
     right representation.
   Extra JSON fields are additive; an engine that ignores them still works for the
   non-timeout paths.
3. **The reply's `error` field** carries a message string when the command could not start,
   with `code` set to e.g. `'ENOENT'`. The shim maps that to Node's ENOENT Error shape.
4. **`TERMX_INTERACTIVE`** drives both `tty.isatty` and the `interactive` request field.
5. **Socket transport needs `await ipc.connect()` once at startup.** Establishing a Unix
   socket connection is the only asynchronous part; after that, every `roundTrip` is purely
   synchronous over the connected fd. `connect()` is exported and called by the app during
   boot; it is a no-op for the fd transport and for in-process test fakes.

---

## 5. What the maintainer must wire up on their side

1. **Preload the shim** with `node --require <abs path to termx-shim/index.js>`; `index.js`
   already patches `Module._load` for `child_process`, `node:child_process`, `os`,
   `node:os`, `tty`, `node:tty`. No source change needed in the app's JS.
2. **Set the IPC env vars the app already sets** — `TERMX_IPC_SOCKET` (today) or
   `TERMX_IPC_FD` + `TERMX_IPC_REPLY_FD`. Set `TERMX_INTERACTIVE` to `"1"`/`"0"`.
3. When a socket is used, call `await ipc.connect()` once during startup (or rely on the
   app handing over fds and using the fd transport, which needs no bootstrap).
4. **Honour `timeout` / `killSignal`** in the command engine if you want `timeout` to
   interrupt. Otherwise implement a timeout on the JS side by other means and note that the
   current shim cannot interrupt a synchronous in-flight request.
5. `fork()` uses `process.env.TERMX_NODE_EXEC || process.execPath` as the node executable
   to run the module. Set `TERMX_NODE_EXEC` if that path isn't runnable in your engine.
6. The `index.test.js` and `ipc.test.js` files are the seam to verify the patch and the wire
   protocol after merging.

All interfaces were implemented exactly as written in WP-A. No third-party dependencies;
the only modules imported are Node built-ins (`events`, `stream`, `fs`, `net`, `os`,
`tty`, `module`). No `fork`/`exec`/`Process`/`posix_spawn`/`system` is used in **delivered
code** — the only process creation anywhere is in the *test* harness (`ipc.test.js`
launches the mock engine, and `spawnProc` in `test/child_process.test.js` runs the mock
backend as a child), never in `lib/` or `index.js`.
