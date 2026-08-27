# Agent brief B — `TetherJobIPC` (TJIP/2 protocol server, Swift)

> **How to use this file:** copy everything below the horizontal rule into a
> fresh agent session as its complete instructions. The agent needs no access
> to any repository, macOS machine, or other document — this brief is
> self-contained.

---

## Mission

Build **`TetherJobIPC`**, a pure-Swift package implementing the **server side**
of TJIP/2 — a framed JSON protocol that connects an embedded Node.js runtime
(the client, built separately in JavaScript) to its iOS host app. The protocol
carries TTY state (raw mode, window size, resize pushes, signals) and child
process spawning (start, stdio streaming with flow control, kill, exit).

Your package owns: framing, envelope validation, request/response correlation,
the handshake, the per-connection session state machine, and flow-control
accounting. It does **not** own any real socket, PTY, termios, or process —
those arrive through two injected protocols (`JIPTransport`,
`JIPHostDelegate`) that the integrator implements later. You ship in-memory
fakes for both so the whole package is testable offline.

## Context you need

- The host app is an iOS terminal. It runs Node jobs whose stdio may be
  attached to a real PTY (interactive TUIs) or piped. Today the app's IPC is
  ad-hoc JSON without versioning, push events, or backpressure; your package
  replaces it.
- A matching JavaScript client is being built independently from the same wire
  spec. Neither of you sees the other's code; the wire spec below is the only
  coupling. Follow it byte-for-byte — golden frame fixtures from your tests
  will be replayed against the JS client during integration.

## Ground rules

- Swift 5.9+ package: `// swift-tools-version:5.9`, platforms
  `.macOS(.v13), .iOS(.v16)`.
- **Foundation only**; must `swift build` / `swift test` on Linux Swift too.
- Zero third-party dependencies; tests pass offline.
- Single-threaded discipline: the session assumes all calls (transport
  receive, host pushes) arrive on one serial queue owned by the integrator.
  Do not create threads or queues; do not use locks. Document this in
  HANDOFF.md.
- Never crash on malformed input: every violation becomes a clean session
  close plus `onProtocolError`.

## The wire specification (FROZEN — implement exactly)

### Transport and framing

- Transport: any reliable ordered byte stream. Production uses an
  `AF_UNIX SOCK_STREAM` socket; tests use in-memory duplex pipes.
- Frame = 4-byte **big-endian unsigned length** `N`, then `N` bytes of UTF-8
  JSON. Length counts the JSON bytes only.
- Max frame: 1,048,576 bytes. On a longer declared length the receiver closes
  the connection (protocol error `EMSGSIZE`).
- Frames never interleave; the stream is a strict sequence of frames.

### Envelope

```json
{ "v": 2, "kind": "req" | "res" | "evt", "id": 7, "type": "domain.op", "body": { } }
```

- `v` is always `2`. Any other value → close with `EPROTO`.
- `kind: "req"` — sender expects exactly one `res` with the same `id`.
- `kind: "res"` — `id` matches the request. `body.ok` is always present
  (`true`/`false`). On `false`, `body.code` (errno-style string) and
  `body.message` (human string) are present.
- `kind: "evt"` — fire-and-forget; `id` absent.
- `id` is a per-connection unsigned integer chosen by the requester,
  strictly increasing. Both sides may send requests (full duplex).
- Unknown `type` in a `req` → `res {ok:false, code:"ENOSYS"}`. Unknown `evt`
  → silently ignored. Unknown extra body fields → ignored.

Error codes: `ENOENT`, `EACCES`, `EPERM`, `EINVAL`, `ESRCH`, `EPIPE`,
`ENOSYS`, `EPROTO`, `EMSGSIZE`, `EAGAIN`.

### Handshake

First request on a connection, sent by the client:

```json
req  "hello"  body: { "proto": 2, "role": "node-shim", "features": ["tty","spawn","flow"] }
res           body: { "ok": true, "proto": 2, "features": ["tty","spawn","flow"],
                      "ttyFds": [0,1,2], "cols": 80, "rows": 24,
                      "termName": "xterm-256color", "colorTerm": "truecolor" }
```

- `ttyFds` lists which of the job's fds 0–2 are genuinely bound to the PTY.
- `colorTerm` ∈ `"truecolor" | "256" | "16" | "none"`.
- Any request other than `hello` before handshake completion →
  `{ok:false, code:"EPROTO"}` (and the session stays open awaiting `hello`).
- A second `hello` → `EPROTO` and session close.

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
req  "spawn.kill"   body {"pid":int, "signal":"SIGTERM"}  → {ok}   // ESRCH after exit event
req  "spawn.resize" body {"pid":int, "cols":int, "rows":int} → {ok} // EINVAL unless pty:true
```

- `stdio` entries: `"pipe"`, `"inherit"`, `"ignore"`.
- A raw stdin/stdout chunk is ≤ 65,536 bytes before base64; larger pushes are
  split by the server automatically.
- Exactly one `spawn.exit` per pid, always the last frame for that pid; after
  it, `spawn.kill` → `ESRCH`, further `spawn.stdin` → `EPIPE`.
- `code` and `signal` are mutually exclusive (one is null).

### `flow` domain (backpressure)

- Server keeps ≤ 262,144 bytes of **unacknowledged** stdout+stderr in flight
  per pid. When exhausted, `pushStdout`/`pushStderr` buffer internally and
  `onFlowWindowOpen` fires when acks reopen the window.
- Client acks consumption: `evt C→S "flow.ack" body {"pid":int, "bytes":int}`.
- The `window` field on `spawn.stdin` responses advises remaining server-side
  stdin capacity in bytes (delegate-provided).

## Public API contract (FROZEN — implement exactly; you may add, never change)

```swift
public protocol JIPTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    func send(_ data: Data) throws
    func close()
}

public struct JIPError: Error, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String)
}

public struct JIPHandshake: Equatable, Sendable {
    public var ttyFds: [Int32]
    public var cols: Int
    public var rows: Int
    public var termName: String
    public var colorTerm: String
    public init(ttyFds: [Int32], cols: Int, rows: Int, termName: String, colorTerm: String)
}

public protocol JIPHostDelegate: AnyObject {
    func handshake() -> JIPHandshake
    func ttyGet(fd: Int32) throws -> (isTTY: Bool, isRaw: Bool, cols: Int, rows: Int)
    func ttySetRawMode(fd: Int32, mode: Bool) throws -> Bool
    func spawnStart(argv: [String], cwd: String, env: [String: String],
                    stdio: [String], pty: Bool) throws -> Int32
    func spawnStdin(pid: Int32, data: Data) throws -> Int
    func spawnStdinEnd(pid: Int32) throws
    func spawnKill(pid: Int32, signal: String) throws
    func spawnResize(pid: Int32, cols: Int, rows: Int) throws
}

public final class JIPServerSession {
    public init(transport: JIPTransport, delegate: JIPHostDelegate)
    public private(set) var isHandshakeComplete: Bool
    public func pushResize(cols: Int, rows: Int)
    public func pushSignal(_ name: String)
    public func pushStdout(pid: Int32, data: Data)
    public func pushStderr(pid: Int32, data: Data)
    public func pushExit(pid: Int32, code: Int32?, signal: String?)
    public var onFlowWindowOpen: ((Int32) -> Void)? { get set }
    public var onProtocolError: ((JIPError) -> Void)? { get set }
    public func close()
}

public final class JIPInMemoryTransportPair {
    public init()
    public var a: JIPTransport { get }
    public var b: JIPTransport { get }
}
```

Notes:

- Delegate methods signal failure by throwing `JIPError`; the session converts
  a thrown `JIPError` into `{ok:false, code, message}` and any other error
  into `EINVAL`.
- `pushExit` must first flush any flow-buffered stdout/stderr for that pid
  (exit is always the last frame for a pid), then release its accounting.
- You will also need (and should expose, since the JS side's tests can't be
  shared) a small internal `JIPFrameCodec` type: encode/decode of
  length-prefixed frames from arbitrary partial chunks. Make it `public` —
  the integrator reuses it for loopback tests.

## Behavior specification and edge cases (each needs a test)

1. **Framing resilience**: a frame delivered one byte at a time; two frames in
   one chunk; a frame boundary splitting the 4-byte length header.
2. **Oversize frame**: declared length 2 MB → session closes, transport
   `close()` called, `onProtocolError` fires with `EMSGSIZE`, no delegate call.
3. **Invalid JSON / wrong `v` / missing `kind`** → `EPROTO` close.
4. **Pre-handshake request** (`tty.get` first) → `{ok:false, code:"EPROTO"}`
   response, session remains open, subsequent `hello` still works.
5. **Duplicate hello** → `EPROTO` and close.
6. **Unknown req type** after handshake → `ENOSYS` response, session healthy.
7. **Unknown evt type** → ignored, session healthy.
8. **Request id reuse / decreasing id** → `EPROTO` close (ids must strictly
   increase).
9. **spawn lifecycle**: start → stdout pushes → exit; assert exit is last, a
   `spawn.kill` after exit returns `ESRCH` without hitting the delegate.
10. **Flow control**: push 300 KiB of stdout with no acks → transport received
    exactly 262,144 bytes worth of chunk frames (≤64 KiB each); send
    `flow.ack` for 100 KiB → remainder flushes in order;
    `onFlowWindowOpen` fired once with the pid.
11. **Chunk splitting**: `pushStdout` with 200 KB input emits ≤64 KiB-raw
    chunks, in order, base64 valid, reassembling to the exact input.
12. **stdin window**: delegate returns window 0 → response carries
    `"window":0`; next `spawn.stdin` still forwarded (policy: server never
    rejects on window; the client is responsible for pausing).
13. **Exit with pending buffer**: exhaust window, then `pushExit` → buffered
    chunks flush first, exit frame is last, accounting freed.
14. **Delegate throws** `JIPError(code:"ENOENT",…)` on spawnStart → response
    `{ok:false,"code":"ENOENT"}`, session healthy.
15. **close() idempotence**: double close is safe; pushes after close are
    silent no-ops.
16. **Golden fixtures**: write at least 12 canonical frames (hello req/res,
    each domain op, an error res) as exact byte arrays in a fixtures file, and
    test encode/decode against them. These bytes are the interop contract with
    the JS client — get them right.

## Test plan (minimum)

- `FrameCodecTests` — chunking matrix, oversize, header splits.
- `HandshakeTests` — cases 3–5, 8.
- `TtyDomainTests` — get/setRawMode/windowSize incl. EINVAL paths, resize and
  signal pushes appear as correct evt frames.
- `SpawnDomainTests` — cases 9, 11, 13, 14.
- `FlowControlTests` — case 10, 12, ack for unknown pid (ignored).
- `GoldenFrameTests` — case 16.
- Use `JIPInMemoryTransportPair` plus a scriptable `FakeHostDelegate`
  (ship it in the test target or as a `TetherJobIPCTestSupport` product —
  your choice, document it).

## Acceptance checklist

- [ ] `swift build` / `swift test` pass, zero warnings, on Linux Swift 5.9+.
- [ ] Public API matches the frozen contract exactly.
- [ ] All 16 numbered behaviors have named tests.
- [ ] Golden fixture bytes committed and documented in HANDOFF.md.
- [ ] No threads, locks, timers, or Darwin imports.
- [ ] HANDOFF.md explains: serial-queue assumption, how the integrator
      implements `JIPTransport` over an fd, how `JIPHostDelegate` maps onto
      real termios/spawn services, and the flow-control model in 10 lines.

## Non-goals

- No real sockets, PTYs, termios, or processes.
- No client (JavaScript) side.
- No reconnect logic — a broken session closes loudly and stays closed.
- No TLS/auth (same-process trust domain).
