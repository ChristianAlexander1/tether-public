# Agent brief C — `tether-shim-v2` (TJIP/2 client + honest Node TTY shim, JS)

> **How to use this file:** copy everything below the horizontal rule into a
> fresh agent session as its complete instructions. The agent needs no access
> to any repository, macOS machine, or other document — this brief is
> self-contained.

---

## Mission

Build **`tether-shim-v2`**, a zero-dependency Node.js (CommonJS) package that
runs inside an embedded Node.js on iOS and makes terminal programs — including
full-screen TUIs like Claude Code, Ink apps, and inquirer prompts — behave
exactly as they would on a real Linux terminal. It is the **client side** of
TJIP/2, a framed JSON protocol; the server side lives in the host app (built
separately in Swift from the same spec — you never see it; your tests use a
mock server you write from the spec).

The package replaces a legacy shim that had these defects, which you must NOT
reproduce:

- `isatty(fd)` returned `true` for **every** fd when an env flag was set.
- Color depth was hardcoded to 8.
- Window size was polled; no `SIGWINCH` or `'resize'` events ever fired.
- No stdout backpressure — fast producers ballooned memory.
- Child processes had fake PIDs with non-functional `kill()`.

Your version derives every answer from the protocol handshake and pushes —
**no environment-flag faking anywhere**.

## Ground rules

- Node 18+; pure CommonJS; **zero npm dependencies** (package.json has none).
- Tests use only the built-in `node:test` runner: `node --test test/`.
- Never talk to a real socket in tests — you build an in-process mock server
  harness implementing the wire spec below.
- The shim is loaded with `--require` before user code. It must patch
  `require('tty')`, `require('child_process')` (via `Module._load`
  interception or equivalent), and `process.stdout/stderr/stdin` TTY
  properties, without breaking non-TTY usage.
- Fail loud: if the IPC connection breaks mid-session, emit a single clear
  error on `process.stderr` and exit 1 — never hang, never silently degrade.
- No hardcoded program names, ever.

## The wire specification (FROZEN — implement exactly)

### Transport and framing

- Transport: any reliable ordered byte stream (production: a Unix socket
  whose path arrives in `process.env.TETHER_IPC_SOCK`; tests: your mock).
- Frame = 4-byte **big-endian unsigned length** `N`, then `N` bytes of UTF-8
  JSON. Length counts the JSON bytes only.
- Max frame: 1,048,576 bytes; a longer declared length → treat as fatal
  protocol error.
- Frames never interleave.

### Envelope

```json
{ "v": 2, "kind": "req" | "res" | "evt", "id": 7, "type": "domain.op", "body": { } }
```

- `v` always 2. `req` expects exactly one `res` with the same `id`. `res.body`
  always has `ok`; on `ok:false` also `code` (errno string) and `message`.
  `evt` has no `id`. Your request `id`s are strictly increasing from 1.
- Unknown req types you receive → respond `{ok:false, code:"ENOSYS"}`.
  Unknown evt types → ignore. Unknown body fields → ignore.
- Error codes: `ENOENT`, `EACCES`, `EPERM`, `EINVAL`, `ESRCH`, `EPIPE`,
  `ENOSYS`, `EPROTO`, `EMSGSIZE`, `EAGAIN`.

### Handshake (client sends first)

```json
req  "hello"  body: { "proto": 2, "role": "node-shim", "features": ["tty","spawn","flow"] }
res           body: { "ok": true, "proto": 2, "features": ["tty","spawn","flow"],
                      "ttyFds": [0,1,2], "cols": 80, "rows": 24,
                      "termName": "xterm-256color", "colorTerm": "truecolor" }
```

- `ttyFds`: which of fds 0–2 are genuinely PTY-bound. **The only source of
  isTTY truth.** `colorTerm` ∈ `"truecolor" | "256" | "16" | "none"`.

### `tty` domain

```json
req "tty.get"        body {"fd":0}                → {ok, "isTTY":bool, "isRaw":bool, "cols":int, "rows":int}
req "tty.setRawMode" body {"fd":0,"mode":true}    → {ok, "wasRaw":bool}      // EINVAL if fd not a TTY
req "tty.windowSize" body {"fd":1}                → {ok, "cols":int, "rows":int}
evt S→C "tty.resize" body {"cols":int,"rows":int}
evt S→C "tty.signal" body {"signal":"SIGINT"|"SIGTERM"|"SIGTSTP"|"SIGCONT"|"SIGHUP"}
```

### `spawn` domain

```json
req "spawn.start" body {"argv":["ls","-la"], "cwd":"/work", "env":{...},
                        "stdio":["pipe","pipe","pipe"], "pty":false}
    → {ok, "pid":int}                        // ENOENT if argv[0] unresolvable
req  "spawn.stdin"    body {"pid":int, "dataB64":"..."}   → {ok, "window":int}
req  "spawn.stdinEnd" body {"pid":int}                    → {ok}
evt  S→C "spawn.stdout" body {"pid":int, "dataB64":"..."}
evt  S→C "spawn.stderr" body {"pid":int, "dataB64":"..."}
evt  S→C "spawn.exit"   body {"pid":int, "code":int|null, "signal":"SIGKILL"|null}
req  "spawn.kill"   body {"pid":int, "signal":"SIGTERM"}  → {ok}   // ESRCH after exit
req  "spawn.resize" body {"pid":int, "cols":int, "rows":int} → {ok} // EINVAL unless pty:true
```

- Raw chunk ≤ 65,536 bytes before base64. Exactly one `spawn.exit` per pid,
  always last. `code`/`signal` mutually exclusive.

### `flow` domain (backpressure)

- The server keeps ≤ 262,144 bytes of unacknowledged stdout+stderr in flight
  per pid. **You must ack what you consume**:
  `evt C→S "flow.ack" body {"pid":int, "bytes":int}` — send it when the data
  has been delivered to the consuming stream (after any 'drain' if the
  destination applied backpressure).
- `spawn.stdin` responses carry `"window"` (server capacity in bytes). When
  ≤ 0, your writable stream buffers and `write()` returns `false`; resume and
  emit `'drain'` after a later response reports window > 0.

## Deliverable layout (FROZEN)

```
tether-shim-v2/
  lib/index.js          // patch entry: require('tether-shim-v2').install(options)
  lib/ipc/framing.js    // frame encode/decode (stream-safe, partial-chunk safe)
  lib/ipc/client.js     // handshake, req/res correlation, evt dispatch
  lib/tty.js            // isatty/ReadStream/WriteStream
  lib/child_process.js  // spawn/spawnSync/exec/execFile over spawn domain
  lib/signals.js        // tty.signal + tty.resize → process wiring
  lib/stdio.js          // stdout/stderr flow-ack, stdin bridging
  test/                 // node:test suites
  test/harness/mock-server.js
  HANDOFF.md
  package.json          // "name": "tether-shim-v2", no dependencies
```

`install(options)` accepts `{ connect }` where `connect()` returns a duplex
stream (net.Socket in production, a PassThrough pair in tests). When
`options.connect` is absent, connect to `process.env.TETHER_IPC_SOCK`.

## Behavior specification

### `lib/tty.js`

- `isatty(fd)`: true **iff** `fd ∈ handshake.ttyFds`. Non-numeric, negative,
  or unknown fds → false. No env var may influence this.
- `ReadStream(fd)`: `isTTY` from handshake; `isRaw` starts false;
  `setRawMode(mode)` sends `tty.setRawMode`, updates `isRaw` from the reply,
  returns `this`. On `EINVAL` (not a TTY) throw the same error shape Node
  throws (`err.code = 'EINVAL'`).
- `WriteStream(fd)`: `columns`/`rows` from handshake (or `tty.get` if
  constructed later); `getWindowSize()` returns `[columns, rows]`.
- `getColorDepth(env)` — apply Node's real decision procedure to the
  handshake `colorTerm`, with env overrides honored in Node's priority order:
  `FORCE_COLOR` (0→1, 1→4, 2→8, 3→24), `NO_COLOR`/`NODE_DISABLE_COLORS` → 1,
  otherwise truecolor→24, 256→8, 16→4, none→1.
- `hasColors(count, env)` consistent with `getColorDepth`
  (`2**depth >= count`).

### `lib/signals.js`

- On `tty.resize`: update `columns`/`rows` on **all** live WriteStreams,
  then emit `'resize'` on each, then emit `'SIGWINCH'` on `process`. This
  ordering matters — Ink reads `stdout.columns` inside its resize handler.
- On `tty.signal`: `process.emit(name)`. If the signal is `SIGINT` or
  `SIGTERM` and there are zero listeners, perform the default action:
  `process.exit(128 + signo)` (INT=2, TERM=15). `SIGTSTP`/`SIGCONT`/`SIGHUP`
  with no listeners are no-ops (document why: no suspend semantics in-app).

### `lib/child_process.js`

- `spawn(cmd, args, opts)` → sends `spawn.start` with
  `argv=[cmd, ...args]`, `cwd` (default `process.cwd()`), `env` (default
  `process.env`), `stdio` normalized to the 3-entry string form, `pty` true
  when `opts.stdio === 'inherit'` and fd 0 is a TTY.
- Returns a `ChildProcess`-compatible object **synchronously** (Node
  semantics): `pid` is set after the async `spawn.start` reply; on `ENOENT`
  emit `'error'` with `err.code='ENOENT'` and never emit `'exit'` — matching
  real Node.
- `stdout`/`stderr` are Readables fed from evt frames (base64-decoded), with
  `flow.ack` sent as consumed; `stdin` is a Writable that respects the
  window per the flow spec.
- Event order: `'spawn'` after pid arrives; on exit evt: emit `'exit'(code,
  signal)`, end stdio readables, then `'close'(code, signal)` after both
  readables have emitted `'end'`.
- `kill(signal='SIGTERM')` → `spawn.kill`; returns true if the request was
  sent, and an `ESRCH` reply is swallowed (matches Node returning false /
  no-op on dead process — document your exact choice).
- `spawnSync`: implement over the async path with a deasync-free strategy:
  drive your own message loop against the injected duplex stream until exit
  (this is possible because the connection object is yours — buffer and
  process frames synchronously via `readSync`-style polling on the test
  harness; in production the host guarantees the socket supports blocking
  reads through a dedicated sync connection: open a **second** connection,
  send `hello` with `role:"node-shim-sync"`, then the whole job runs
  request-by-request). Document the two-connection design in HANDOFF.md.
- `exec`/`execFile`: thin wrappers over `spawn` with shell argv
  `["/bin/sh","-c",command]` for `exec`, buffering with `maxBuffer` default
  1 MB and the standard `(error, stdout, stderr)` callback contract.

### `lib/ipc/client.js`

- Strictly increasing ids; a map of pending requests; per the spec both sides
  may send requests, so also dispatch incoming reqs (reply `ENOSYS` to
  unknown ones).
- Partial frames: accumulate; a frame may arrive across many `'data'` events,
  or many frames in one event. Declared length > 1 MiB → fatal.
- Fatal error path (bad JSON, connection close mid-session): print one line
  `tether-shim: IPC connection lost (<reason>)` to stderr, restore cooked
  mode is the server's job, `process.exit(1)`.

## Edge cases you MUST handle (each needs a test)

1. Handshake `ttyFds:[0,2]` → `isatty(0)`=true, `isatty(1)`=false — piped
   stdout with interactive stdin works (this exact mix happens with
   `claude | tee log`).
2. `tty.resize` with 5 live WriteStreams → all updated before any event fires;
   `'SIGWINCH'` observed on process exactly once.
3. `getColorDepth` matrix: every `colorTerm` × (`NO_COLOR`, `FORCE_COLOR=3`,
   no override) → correct depths.
4. `setRawMode` on a non-TTY fd → throws `EINVAL`-coded error synchronously
   from the caller's perspective (promise/callback design is yours; the shim
   API surface must match Node's synchronous signature — document how you
   bridge, e.g. optimistic local state + async reconciliation, and test the
   reconciliation failure path).
5. spawn ENOENT → `'error'` emitted once, no `'exit'`, no `'close'`.
6. Exit before stdin flushed → pending writes error with `EPIPE`, writable
   destroyed, no crash, no unhandled rejection.
7. 1 MB of stdout in 64 KiB chunks → all delivered in order; `flow.ack`
   totals exactly 1 MB; memory in the readable never exceeds the window when
   the consumer is slow (use a paused consumer in the test).
8. stdin window drops to 0 → `write()` returns false; window reopens →
   `'drain'` fires once, queued data flushes in order.
9. Two frames in one TCP chunk; one frame split across 7 chunks including
   mid-length-header.
10. Server sends unknown evt `"future.thing"` → ignored, session healthy.
11. `spawn.exit` with `signal:"SIGKILL"` → `exit(null, 'SIGKILL')` then
    `close(null, 'SIGKILL')`.
12. Ctrl-C default action: `tty.signal SIGINT` with no listener →
    process exits 130 (test via child process running the shim).
13. `install()` twice → idempotent (second call is a no-op).
14. User code replaces `process.stdout.write` (some CLIs do) → shim still
    functions; no prototype freeze assumptions.

## Test plan (minimum)

- `test/harness/mock-server.js`: an in-process TJIP/2 server implementing the
  spec (handshake, scripted responses, push injection). It is a test
  utility, but write it spec-faithful — it doubles as executable
  documentation.
- Suites: `framing.test.js`, `tty.test.js`, `signals.test.js`,
  `child_process.test.js`, `flow.test.js`, `install.test.js`,
  `default-actions.test.js` (spawns real `node` subprocesses to observe exit
  codes).
- Target ≥ 120 assertions. All tests deterministic: fake timers or event
  awaiting, no `setTimeout`-based sleeps except in the subprocess tests.

## Acceptance checklist

- [ ] `node --test test/` passes on Node 18, 20, and 22 (use whatever is
      installed; document the version you verified).
- [ ] Zero npm dependencies; `npm ls` shows nothing.
- [ ] All 14 edge cases have named tests.
- [ ] No env-flag TTY faking anywhere (grep proves no `TETHER_INTERACTIVE`).
- [ ] No hardcoded command names.
- [ ] HANDOFF.md documents: install/require order, the two-connection
      spawnSync design, the raw-mode sync-bridge decision, flow-ack rules,
      and a 10-line usage example.

## Non-goals

- No server side, no Swift, no real Unix sockets in tests.
- No PTY creation; the host owns PTYs.
- No polyfills for Bun APIs (separate component).
- No reconnect/retry logic.
