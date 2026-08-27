# TetherJobIPC — HANDOFF

Server side of **TJIP/2**, the framed JSON protocol connecting an embedded Node.js
runtime (the client, built separately in JavaScript) to its iOS host app. This
package owns framing, envelope validation, request/response correlation, the
handshake, the per-connection session state machine, and flow-control accounting.
It does **not** own any socket, PTY, termios, or process — those arrive through the
two injected protocols (`JIPTransport`, `JIPHostDelegate`). In-memory fakes are
provided for both so the whole package is testable offline.

```
TetherJobIPC/
├── Package.swift                       Swift 5.9 tools; zero third-party deps
├── HANDOFF.md                          you are here
├── Fixtures/frames.txt                 human-readable golden wire frames (interop)
├── Sources/TetherJobIPC/               the library (Foundation-only)
│   ├── JIPTransport.swift              JIPTransport protocol (byte stream)
│   ├── JIPInMemoryTransportPair.swift  in-memory duplex pair (offline testing)
│   ├── JIPError.swift                  JIPError + errno-style code constants
│   ├── JIPHandshake.swift              static TTY capability snapshot
│   ├── JIPHostDelegate.swift           the host-side service protocol
│   ├── JIPFrameCodec.swift             length-prefixed frame encode/decode (incremental)
│   ├── JIPJSON.swift                   deterministic JSON encoder (internal)
│   └── JIPServerSession.swift          the per-connection state machine
├── Tests/TetherJobIPCTestSupport/      {test-support} product
│   ├── FakeHostDelegate.swift          scriptable JIPHostDelegate fake
│   ├── JIPTestHarness.swift            drives a session from the client side
│   └── GoldenFrames.swift              literal golden frame byte arrays
└── Tests/TetherJobIPCTests/            FrameCodec / Handshake / Tty / Spawn /
                                        FlowControl / GoldenFrame test suites
```

## 1. The serial-queue assumption (single-threaded discipline)

The session is **not thread-safe**. It assumes every call — `transport.onReceive`
delivery of inbound bytes, every `push*` from the host, and the delegate methods it
invokes — happens on **one single serial queue owned by the integrator**. Because of
this, the session uses **no locks, no queues/timers/threads, no `Dispatch`/`Darwin`**
(stdlib `Foundation` only). If the integrator already has a serial `DispatchQueue`
per connection (typical for a socket read loop), just hop all `push*` calls and all
`onReceive` deliveries onto it. The session is neither thread-safe nor re-entrant
beyond that assumption. This mirrors Unix fd semantics: a socket's read side and the
host's push side are serialized by one runloop/queue.

`onProtocolError` and pushes after `close()` are silent no-ops; `close()` is
idempotent.

## 2. Implementing `JIPTransport` over a real fd (`AF_UNIX SOCK_STREAM`)

```swift
final class SocketTransport: JIPTransport {
    var onReceive: ((Data) -> Void)?
    private let fd: Int32
    private let queue: DispatchQueue            // integrator-owned serial queue
    init(fd: Int32, queue: DispatchQueue) { ... }

    func send(_ data: Data) throws {
        // write the whole buffer; loop while more bytes remain.
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { p in
                write(fd, p.baseAddress! + written, data.count - written) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 { throw JIPError(code: "EIO", message: ...) }
            written += n
        }
    }

    func close() { close(fd) }
    // read loop (on `queue`): read(...) into a buffer, then queue.async { onReceive?(chunk) }
    // on EAGAIN → stop; on error/EOF → stop.
}
```

- `onReceive(value)` is called with **arbitrary byte sub-chunks** of the stream — a
  chunk may hold a partial frame, one frame, or many frames. The session feeds it
  straight into `JIPFrameCodec`, which handles exact boundaries, header splits, and
  multi-frame chunks. Do **not** re-frame in the transport.
- `send` writes whole framed chunks produced by `JIPServerSession` (which wraps the
  JSON in `JIPFrameCodec.encode`). `send` must be best-effort ordered and reliable.
- The integrator owns the serial `DispatchQueue`.

The same shapes apply to the loopback pair shipped here, `JIPInMemoryTransportPair`
(`a`/`b`), used by the tests and by integrator loopback tests.

## 3. Mapping `JIPHostDelegate` onto real services

The session never creates a process or touches termios. The integrator maps each
method:

| Delegate method                                     | Real service                                            |
|-----------------------------------------------------|---------------------------------------------------------|
| `handshake()`                                       | static PTY wiring for the job: which of fds 0–2 are on a PTY, current winsize, `TERM`/color depth |
| `ttyGet(fd:)`                                        | `isatty(fd)` + `tcgetattr(fd)` (raw flag) + `ioctl(TIOCGWINSZ)` |
| `ttySetRawMode(fd:mode:)`                            | `tcgetattr` → set/clear `ICANON|ECHO` etc. → `tcsetattr`; return previous raw state; `EINVAL` if `!isatty` |
| `spawnStart(argv:cwd:env:stdio:pty:)`                | `posix_spawn`/`fork`+`exec`; open pipes and a `openpty()` when `pty`; return pid; `ENOENT` on unresolvable `argv[0]` |
| `spawnStdin(pid:data:)`                              | `write()` into the child's stdin pipe; return remaining stdin buffer capacity (advisory "window") |
| `spawnStdinEnd(pid:)`                                | `close()`/`shutdown()` the child's stdin pipe (EOF)  |
| `spawnKill(pid:signal:)`                             | `kill(pid, sig)`; throw `ESRCH` if pid reaped        |
| `spawnResize(pid:cols:rows:)`                        | `ioctl(TIOCSWINSZ)` on a pty-spawned child; throw `EINVAL` unless `pty:true` |

Errors: throw `JIPError(code:message:)` from any method. The session turns a thrown
`JIPError` into `{"ok":false,"code":…,"message":…}`; any other thrown `Error`
becomes `EINVAL`.

**After `pushExit`** the session answers `spawn.kill`→`ESRCH`, `spawn.stdin`/
`spawn.stdinEnd`→`EPIPE`, and `spawn.resize`→`ESRCH` **without** calling the
delegate, so the integrator can reclaim the pid.

## 4. Flow-control model

- The server keeps at most **262,144** raw (pre-base64) bytes of **unacknowledged**
  `stdout`+`stderr` **in flight per pid** — they share one window.
- `pushStdout`/`pushStderr` split the input into ≤65,536-byte raw chunks. A chunk
  that still fits in the window is sent immediately and its size is added to the
  per-pid in-flight count. A chunk that would exceed the window is buffered
  (per pid, preserving arrival order) and the pid is marked "backpressured".
- The client acks consumption with `evt flow.ack {"pid", "bytes"}`. The session
  subtracts `bytes` from in-flight and, if the window reopens, flushes buffered
  chunks (in order) and fires `onFlowWindowOpen(pid)` **once** per reopening.
- Exactly one `spawn.exit` per pid, always the last frame for that pid: `pushExit`
  first flushes all buffered stdout/stderr (ignoring the window), then sends the
  exit frame, then **releases** the pid's accounting. After that the pid is
  remembered only as "exited". Late `flow.ack`s, extra `push*`, and further I/O are
  ignored; `spawn.kill`/`spawn.stdin` fail fast.
- `spawn.stdin` echoes the delegate's returned remaining stdin capacity as `window`.
  **The server never rejects on a zero window** — pausing is the client's job.

## 5. Golden wire fixtures (interop contract)

- `Tests/TetherJobIPCTestSupport/GoldenFrames.swift` holds **20 literal `[UInt8]`
  frames** (name + canonical JSON + exact bytes).
- `Fixtures/frames.txt` is the human/JS-readable copy (name + JSON + hex),
  regenerated from `GoldenFrames.swift`.
- Each fixture is a real wire frame: 4-byte big-endian length + UTF-8 JSON. The JSON
  is serialized with **sorted object keys** (deterministic), which is what makes the
  bytes exact; JSON parsers ignore key order, so the JS client can consume them
  directly. The JS integration should replay the `*.req`/`*.evt` fixtures as input
  and, for the `*.res` fixtures, assert the server emits those exact bytes.
- `GoldenFrameTests` round-trips each fixture through `JIPFrameCodec` and replays
  request fixtures through a real session, asserting byte-for-byte output.
- To regenerate (e.g. after a wire change): add the canonical dicts to a temporary
  `swift test` that prints `JIPJSON.encode(dict)` + hex, then paste into
  `GoldenFrames.swift` and re-run the fixture regeneration (or edit bytes inline).
  **Do not hand-edit the byte arrays.**

## 6. Behavior → test map (all 16 required behaviors)

| # | Behavior                                                          | Tests |
|---|-------------------------------------------------------------------|-------|
| 1 | Framing resilience (byte-at-a-time, two-in-one, header split)      | `FrameCodecTests` |
| 2 | Oversize frame → `EMSGSIZE` close, `onProtocolError`, no delegate  | `FrameCodecTests.testOversizeDeclaredLengthThrows`, `HandshakeTests.testOversizeFrameClosesSessionWithEMSGSIZE` |
| 3 | Invalid JSON / wrong `v` / missing `kind` → `EPROTO` close         | `HandshakeTests.testInvalidJSON…`, `.testWrongVersion…`, `.testMissingKind…` |
| 4 | Pre-handshake request → `EPROTO` res, session stays open           | `HandshakeTests.testPreHandshakeRequestReturnsEPROTOAndSessionStaysOpen` |
| 5 | Duplicate hello → `EPROTO` close                                   | `HandshakeTests.testDuplicateHelloClosesWithEPROTO` |
| 6 | Unknown request type → `ENOSYS`, session healthy                   | `HandshakeTests.testUnknownRequestTypeReturnsENOSYS` |
| 7 | Unknown event type → ignored                                       | `HandshakeTests.testUnknownEventTypeIsIgnored` |
| 8 | Reused/decreasing request id → `EPROTO` close                      | `HandshakeTests.testReusedRequestId…`, `.testDecreasingRequestId…` |
| 9 | Spawn lifecycle (start→stdout→exit; kill/stdin after exit)         | `SpawnDomainTests` |
| 10| Flow window (262,144 cap, ack reopen, `onFlowWindowOpen` once)     | `FlowControlTests.testWindowSendsExactlyBudgetThenBuffersUntilAck` |
| 11| Chunk splitting ≤64 KiB, ordered, exact reassembly                 | `SpawnDomainTests.testChunkSplitting_200KBEmitsOrderedBase64Chunks` |
| 12| stdin window advisory (0 still forwarded)                          | `FlowControlTests.testZeroStdinWindowIsAdvisoryAndStillForwards`, `.testStdinWindowEchoesDelegateValue` |
| 13| Exit flushes pending buffer, exit last, accounting freed           | `FlowControlTests.testExitFlushesBufferedChunkLastAndFreesAccounting` |
| 14| Delegate throws `JIPError` → mapped `res`, session healthy         | `SpawnDomainTests.testDelegateThrowsJIPErrorProducesCode` |
| 15| `close()` idempotent; pushes after close no-op                     | `HandshakeTests.testDoubleCloseIsSafe`, `FlowControlTests.testPushesAfterCloseAreNoOps` |
| 16| Golden fixtures decoded/encoded exactly and replayed               | `GoldenFrameTests` |

Run: `swift build && swift test` (debug and `-c release` build clean, zero warnings).

## 7. Non-goals

No real sockets/PTYs/termios/processes, no client (JS) side, no reconnect logic
(a broken session closes loudly and stays closed via `onProtocolError`), no TLS/auth
(same-process trust domain). `JIPError` (and the added `JIPFrameError`,
`JIPErrorCode`) are the only error surfaces.
