# tether-shim-v2 — HANDOFF

Client side of **TJIP/2** for embedded Node.js on iOS. Replaces the legacy
shim whose defects (env-flag `isatty` faking, hardcoded color depth, polled
window size, unbounded stdout buffering, fake PIDs) are all structurally
impossible here: every answer is derived from the protocol handshake and
pushed events — there is no environment-flag TTY faking anywhere (`grep -r
TETHER_INTERACTIVE lib/` returns nothing; an acceptance test enforces it).

- Zero npm dependencies. Tests: `node --test test/` (built-in runner only).
- **Verified green (99/99) on Node v18.20.8, v20.20.2, and v22.20.0.**
  Note a Node CLI change (not a package issue): since Node 22, `--test`
  positional args are glob patterns, so the literal directory form
  `node --test test/` no longer scans the directory on Node 22. There, use
  `node --test "test/**/*.js"` or bare `node --test` (both verified 99/99).
  `npm test` chains the two invocations so it is correct on 18/20/22;
  `npm run test:spec` is the exact spec command.

---

## 1. Install / require order

```
require('tether-shim-v2').install(options) → Promise<{ client, handshake }>
```

1. `install()` opens the duplex IPC stream: `options.connect()` if provided
   (tests, or hosts with a custom transport), else
   `net.createConnection(process.env.TETHER_IPC_SOCK)`.
2. The client sends `hello` first (`{proto:2, role:"node-shim",
   features:["tty","spawn","flow"]}`); request ids are strictly increasing
   from 1.
3. **Only after** the handshake reply arrives does the shim:
   - attach `lib/tty.js`, `lib/signals.js`, `lib/stdio.js`,
     `lib/child_process.js` to the session state;
   - intercept `Module._load` so `require('tty')`, `require('node:tty')`,
     `require('child_process')`, `require('node:child_process')` return the
     shim modules;
   - patch `process.stdout/stderr/stdin` TTY properties.
4. `install()` is **idempotent**: a second call returns the first promise;
   no second connection, no second `hello` (edge case 13 has a test).

Ordering rule for embedders: load with `--require tether-shim-v2` (it
auto-installs when `TETHER_IPC_SOCK` is set) or call `install()` explicitly
before any user code that consults TTY state. The handshake completes within
the first event-loop turns; code that needs TTY truth at the very first
synchronous instant should `await require('tether-shim-v2').ready()`.
Before the handshake resolves, the unpatched Node `tty` module is still in
place — we never answer TTY questions from guesses or env flags.

`isatty(fd)` is true **iff** `fd ∈ handshake.ttyFds`. Non-numeric, negative,
fractional, or unknown fds return `false`. With `ttyFds:[0,2]` (the
`claude | tee log` mix): stdin interactive, stdout piped — covered by test.

## 2. Fatal path

Any protocol violation (declared frame length > 1 MiB, invalid JSON, wrong
`v`, unknown envelope kind) or transport loss (stream error/close) is
**fatal**: all pending requests are rejected, one line
`tether-shim: IPC connection lost (<reason>)` is written **directly to
fd 2** via `fs.writeSync` (so a user-replaced `process.stderr.write` cannot
swallow it), and the process exits 1. Never hangs, never silently degrades.
Restoring cooked mode on the PTY is the server's job, per spec. Tests can
inject `options.onFatal` to observe the path in-process; subprocess fixtures
verify the real exit code and stderr line.

## 3. The two-connection spawnSync design

`spawnSync` cannot multiplex the async main connection (its responses are
delivered by event-loop turns). Instead it opens a **second, dedicated
connection**:

1. `options.connectSync()` (defaulting to `options.connect()`) produces a
   fresh duplex stream; a sync-mode `Client` attaches **no** `'data'`/
   `'close'` listeners — the caller drives the stream.
2. Handshake with `role: "node-shim-sync"`.
3. `spawn.start`, then the whole job runs **request-by-request**:
   `spawn.stdin` chunks (≤ 64 KiB raw) while the reported `window > 0`,
   `spawn.stdinEnd` when input is exhausted, otherwise synchronous
   `stream.read()` pumping that dispatches `spawn.stdout`/`spawn.stderr`
   (each immediately `flow.ack`ed — the sync consumer consumes on receipt)
   until `spawn.exit` arrives.
4. The sync connection is retired (`dispose()`) in a `finally` block.

In production the host guarantees the sync connection supports **blocking
reads**. The client honors that contract and additionally carries a
zero-dependency fallback for plain POSIX Node: when the sync stream is a
libuv-managed `net.Socket` (whose `read()` cannot deliver bytes while we
hold the thread), the sync client reads/writes the socket fd directly
(`fs.readSync`/`fs.writeSync` — the kernel buffers both directions
independently of the event loop), parking between `EAGAIN` retries with
`Atomics.wait` (no deasync, no worker). Host-provided genuinely blocking
streams take precedence: `stream.read()` is always tried first. This
production path — auto-install via `TETHER_IPC_SOCK`, `--require`, and
spawnSync's second connection over a real Unix socket — was verified
end-to-end against the mock host. If a pump finds nothing to send and
nothing readable within the attempt budget, spawnSync fails loud with
`result.error.code = 'EAGAIN'` instead of spinning (tested). The mock
server processes frames synchronously inside `write()`, which is exactly
what makes the in-process tests exercise the same request-by-request loop.

## 4. Raw-mode sync bridge

Node's `setRawMode(mode)` is synchronous; `tty.setRawMode` on the wire is a
round trip. The bridge:

- fd not a TTY per handshake → **throw synchronously** with
  `err.code = 'EINVAL'` (same shape Node throws), no request sent.
- Otherwise: flip local `isRaw` **optimistically**, send the request, return
  `this` immediately.
- **Async reconciliation**: if the reply is `ok:false`, roll `isRaw` back to
  its prior value and emit `'error'` (`err.code` from the reply) on the
  stream. Embedders wiring raw mode should attach an `'error'` listener to
  the input stream. The reconciliation-failure path has a dedicated test.

## 5. flow-ack rules

- Server keeps ≤ 262,144 bytes of unacked `spawn.stdout` + `spawn.stderr`
  in flight per pid; raw chunks are ≤ 65,536 bytes before base64.
- The child's Readables push **one chunk at a time** into Node's buffer.
  A chunk is acked (`flow.ack {pid, bytes}`) when `_read()` runs again,
  i.e. after the previously pushed chunk has been **consumed** (delivered
  to the application, including past any backpressure — in paused mode that
  means after `read()` returns it). The unacked set (internal queue +
  Node's buffer) therefore never exceeds the window, so a slow consumer
  cannot balloon memory (edge 7 asserts the bound at every step and that
  the ack total is exactly 1,048,576 bytes).
- `_read()` is always eventually answered with a `push()` — refusing to
  push after `_read` would strand the Readable in Node's internal "reading"
  state forever (found and regression-tested during development).
- stdin: `spawn.stdin` responses carry `window`. While `window ≤ 0`,
  writes are queued and `write()` returns `false`; a later response
  reporting `window > 0` flushes the queue **in order** and emits `'drain'`
  exactly once. Because the window is only observable in responses, a
  stalled queue is retried with a **single probe request** whenever the
  server shows activity for that pid (output events / exit); if the probe
  response still says ≤ 0, we re-buffer. Documented choice — the spec's
  "a later response" implies a request has to happen.
- Exit before stdin flush: queued writes' callbacks receive `EPIPE`, the
  writable is destroyed, an `'error'` event fires once, and nothing crashes
  or rejects unhandled (edge 6).

## 6. ChildProcess semantics (documented choices)

- `spawn()` returns synchronously; `pid` appears when `spawn.start`
  replies; `'spawn'` fires after that. Events arriving before the reply
  (a fast producer racing the round trip) are buffered per pid and
  replayed in arrival order after `'spawn'` — real servers do this.
- Event order: `'spawn'` → `'exit'(code, signal)` → readables reach EOF →
  `'close'(code, signal)` after **both** readables emitted `'end'`.
  As in real Node, `'end'` requires the EOF to be consumed; a never-read
  stream delays `'close'`.
- `spawn.start` `ENOENT` → one `'error'` (`err.code='ENOENT'`,
  `err.path`, `err.syscall`), never `'exit'`/`'close'` (edge 5).
- `kill(signal='SIGTERM')` returns `true` when the request was sent (pid
  known, not yet exited) and `false` otherwise. An `ESRCH` reply is
  **swallowed**: by reply time the process is already gone, which Node
  callers observe as a no-op; other error codes surface asynchronously as
  `'error'` on the child.
- `spawn.resize` → EINVAL unless the child was started `pty:true`.
  `pty:true` is sent only when `opts.stdio === 'inherit'` **and**
  `isatty(0)` per the handshake.
- `exec` uses the spec shell argv `["/bin/sh", "-c", command]` —
  `/bin/sh` is the spec-mandated default constant (overridable via
  `options.shell`), not a hardcoded program special-case. `execFile` runs
  without a shell; both buffer with `maxBuffer` default 1 MB and use the
  standard `(error, stdout, stderr)` contract (numeric exit code in
  `error.code`, `ENOBUFS` + kill on overflow). `execSync` is implemented
  over the spawnSync path; `fork` delegates to the real module (IPC-based,
  outside the protocol surface).

## 7. Color

`getColorDepth(env)` applies Node's real decision procedure to the
handshake `colorTerm`, in Node's priority order: `FORCE_COLOR`
(0→1, 1→4, 2→8, 3→24; `''`/`'true'`→4), then `NO_COLOR`/
`NODE_DISABLE_COLORS` → 1, then non-TTY stdout → 1, then `TERM=dumb` → 1,
then truecolor→24, 256→8, 16→4, none→1. `hasColors(count, env)` is
`2**depth >= count`. The full matrix (4 colorTerms × 3 env cases) is
tested; `WriteStream#getColorDepth` answers for the stream's own fd.

## 8. Resize & signals

On `tty.resize`: update `columns`/`rows` on **all** live streams (incl.
`process.stdout/stderr` when TTY) → emit `'resize'` on each → emit
`'SIGWINCH'` on `process`, exactly once, in that order (Ink reads
`stdout.columns` inside its resize handler). On `tty.signal`:
`process.emit(name)`; `SIGINT`/`SIGTERM` with zero listeners perform the
default action `process.exit(128+signo)` (130/143, verified via real
subprocesses). `SIGTSTP`/`SIGCONT`/`SIGHUP` with zero listeners are
**no-ops**: there is no job-control suspend/resume state inside the host
app, so dropping them is the only honest behavior.

## 9. Usage example (10 lines)

```js
// app.js — run: node --require tether-shim-v2 app.js
const { spawn } = require('child_process');   // intercepted → shim
const tty = require('tty');                   // intercepted → shim
process.stdout.write(`tty? ${tty.isatty(1)} colors=${tty.getColorDepth()}\n`);
process.on('SIGWINCH', () => console.log('resized to', process.stdout.columns));
const [cmd, ...args] = (process.env.MY_TOOL_ARGV || 'echo hi').split(' ');
const child = spawn(cmd, args, { stdio: 'inherit' });
child.on('exit', (code, signal) => console.log('done', code, signal));
// ...later, from the host: a tty.resize event updates every stream and
// fires SIGWINCH; a tty.signal SIGINT exits 130 unless handled.
```

## 10. Testing notes

- `node --test test/` — 99 tests, ~370 assertions, deterministic
  (promise/event awaiting; the only subprocess waits are in
  `default-actions.test.js`). Verified green on Node v18.20.8, v20.20.2,
  and v22.20.0 (see the Node-22 invocation note at the top).
- `test/harness/mock-server.js` is a spec-faithful in-process TJIP/2
  server (framing, envelope rules, ENOSYS for unknown reqs, ENOENT/ESRCH/
  EINVAL paths, per-pid 256 KiB flow-window enforcement with ack-gated
  release, raw-byte injection). It processes frames synchronously inside
  `write()`, which doubles as executable documentation of the sync design.
- No real sockets anywhere: subprocess fixtures run their own in-process
  mock server; they are armed with `TETHER_FIXTURE_ARM=1` by the parent
  test so the runner's directory walk treats them as inert modules.
- `_resetForTests()` (exported from `lib/index.js`) undoes install
  bookkeeping between fatal-path tests; it is a test seam, not production
  API.

## 11. Layout

```
lib/index.js          install()/ready(), Module._load interception, auto-install
lib/ipc/framing.js    4-byte BE length framing, >1 MiB fatal, partial-safe parser
lib/ipc/client.js     handshake, req/res correlation, evt dispatch, ENOSYS
                      replies, sync request/pump for the spawnSync connection
lib/tty.js            isatty/ReadStream/WriteStream/getColorDepth/hasColors
lib/signals.js        tty.resize + tty.signal → process wiring
lib/stdio.js          process.stdout/stderr/stdin patching, raw-mode bridge
lib/child_process.js  spawn/spawnSync/exec/execFile/execSync over spawn domain
test/                 7 suites + harness + armed fixtures
```
