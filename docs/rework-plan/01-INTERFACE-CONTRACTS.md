# Canonical interface contracts

This file is the single source of truth for every cross-component interface.
The agent briefs copy the sections they need **verbatim**. If a contract ever
has to change, change it here first, then update the affected briefs, then the
glue guide. Agents may **add** public API; they may never rename, remove, or
change the semantics of anything written here.

Shared toolchain rules (all Swift components):

- Swift 5.9+, `// swift-tools-version:5.9`, platforms `.macOS(.v13), .iOS(.v16)`.
- Core targets import **Foundation only** and must build/test on Linux Swift.
- No third-party dependencies. `swift test` passes offline.
- Darwin-only code (ioctl/openpty/etc.) is out of scope for agents; they ship
  protocols + in-memory fakes, the integrator ships the Darwin adapter.

Shared toolchain rules (all Node components):

- Node 18+, CommonJS, zero npm dependencies, tests via built-in `node:test`
  (`node --test test/`).

---

## 1. TJIP/2 — Tether Job IPC Protocol, version 2

Used by: `TetherJobIPC` (Swift, server side), `tether-shim-v2` (JS, client
side). Both implement this spec exactly; interoperability is verified in the
glue step by replaying the same golden frame fixtures on both sides.

### Transport and framing

- Transport: any reliable ordered byte stream. Production uses an
  `AF_UNIX SOCK_STREAM` socket; tests use in-memory duplex pipes.
- Frame = 4-byte **big-endian unsigned length** `N`, then `N` bytes of UTF-8
  JSON. Length counts the JSON bytes only.
- Max frame: 1,048,576 bytes. On a longer declared length the receiver closes
  the connection (protocol error `EMSGSIZE`).
- Frames never interleave; the stream is a strict sequence of frames.

### Envelope

Every frame is a JSON object:

```json
{ "v": 2, "kind": "req" | "res" | "evt", "id": 7, "type": "domain.op", "body": { } }
```

- `v` is always `2`. A peer receiving any other value closes with `EPROTO`.
- `kind: "req"` — sender expects exactly one `res` with the same `id`.
- `kind: "res"` — `id` matches the request. `body.ok` is always present
  (`true`/`false`). On `false`, `body.code` (errno-style string) and
  `body.message` (human string) are present.
- `kind: "evt"` — fire-and-forget; `id` is absent.
- `id` is a per-connection unsigned integer chosen by the requester,
  strictly increasing. Both sides may send requests (full duplex).
- Unknown `type` in a `req` → `res {ok:false, code:"ENOSYS"}`. Unknown `evt`
  → silently ignored. Unknown extra body fields → ignored (forward compat).

Error codes are errno-style strings: `ENOENT`, `EACCES`, `EPERM`, `EINVAL`,
`ESRCH`, `EPIPE`, `ENOSYS`, `EPROTO`, `EMSGSIZE`, `EAGAIN`.

### Handshake

First request on a connection, sent by the client (JS shim):

```json
req  "hello"  body: { "proto": 2, "role": "node-shim", "features": ["tty","spawn","flow"] }
res           body: { "ok": true, "proto": 2, "features": ["tty","spawn","flow"],
                      "ttyFds": [0,1,2], "cols": 80, "rows": 24,
                      "termName": "xterm-256color", "colorTerm": "truecolor" }
```

- `ttyFds` lists which of the job's fds 0–2 are genuinely bound to the PTY.
  **This is the only source of `isTTY` truth.** A piped job gets `[]`.
- `colorTerm` is `"truecolor"`, `"256"`, `"16"`, or `"none"`.
- Any request other than `hello` before the handshake completes →
  `{ok:false, code:"EPROTO"}`.

### `tty` domain

```json
req "tty.get"        body {"fd":0}                → {ok, "isTTY":bool, "isRaw":bool, "cols":int, "rows":int}
req "tty.setRawMode" body {"fd":0,"mode":true}    → {ok, "wasRaw":bool}      // EINVAL if fd not a TTY
req "tty.windowSize" body {"fd":1}                → {ok, "cols":int, "rows":int}
evt S→C "tty.resize" body {"cols":int,"rows":int}                            // client emits process SIGWINCH
evt S→C "tty.signal" body {"signal":"SIGINT"|"SIGTERM"|"SIGTSTP"|"SIGCONT"|"SIGHUP"}
evt S→C "tty.stdin"  body {"dataB64":"..."}                                  // live PTY bytes; never EOF on idle
```

Semantics:

- `tty.resize` is pushed by the server on every real window-size change. The
  client updates all live `WriteStream.columns/rows` **before** emitting
  `SIGWINCH` on `process`.
- `tty.signal` delivers a named signal to the JS process via
  `process.emit(signal)`; if no listener exists for `SIGINT`/`SIGTERM`, the
  client performs the default action (exit with the conventional code
  `128 + signo`).

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

- `stdio` entries: `"pipe"` (data flows via stdout/stderr/stdin frames),
  `"inherit"` (bound to the job's own stdio; no frames flow), `"ignore"`.
- A raw stdin/stdout chunk is ≤ 65,536 bytes before base64.
- Exactly one `spawn.exit` per pid, always last; after it, `spawn.kill`
  returns `ESRCH` and further stdin returns `EPIPE`.
- `code` and `signal` are mutually exclusive (one is null), as in Node.

### `flow` domain (backpressure, feature `"flow"`)

- The server keeps ≤ 262,144 bytes of **unacknowledged** stdout+stderr in
  flight per pid. When the window is exhausted it pauses reading from the
  child until acks arrive.
- Client acknowledges consumption:

```json
evt C→S "flow.ack" body {"pid":int, "bytes":int}
```

- For stdin, the `window` field on each `spawn.stdin` response advises
  remaining server-side capacity in bytes; when ≤ 0 the client pauses the JS
  writable stream and resumes after a subsequent response reports > 0.

---

## 2. `TetherVTEngine` public API (Swift)

```swift
public enum VTToken: Equatable, Sendable {
    case text(Data)                       // printable runs, incl. UTF-8
    case c0(UInt8)                        // BEL, BS, TAB, LF, CR, ...
    case esc(final: UInt8, intermediates: [UInt8])
    case csi(params: [Int], intermediates: [UInt8], final: UInt8, isPrivate: Bool)
    case osc(code: Int, payload: Data)
    case dcs(payload: Data)
    case incomplete                       // internal marker, never emitted by feed()
}

public final class VTStreamTokenizer {
    public init()
    /// Incremental: safe to feed bytes split at any boundary, including
    /// mid-escape and mid-UTF-8. Buffers partial sequences internally.
    public func feed(_ bytes: Data) -> [VTToken]
    /// Flush any buffered partial sequence as raw text (stream ended).
    public func flush() -> [VTToken]
    /// Exact bytes of a token, for lossless pass-through re-emission.
    public static func serialize(_ token: VTToken) -> Data
}

public struct TUIModeState: Equatable, Sendable {
    public var alternateScreen: Bool          // DECSET 47 / 1047 / 1049
    public var cursorHidden: Bool             // DECSET 25 (l = hidden)
    public var mouseModes: Set<Int>           // 9,1000,1002,1003,1005,1006,1015
    public var bracketedPaste: Bool           // DECSET 2004
    public var applicationCursorKeys: Bool    // DECSET 1
    public var applicationKeypad: Bool        // ESC = / ESC >
    public var focusReporting: Bool           // DECSET 1004
    public var synchronizedOutput: Bool       // DECSET 2026
    public var scrollRegionSet: Bool          // DECSTBM with non-default args
    public var savedCursor: Bool              // DECSC without matching DECRC
    public var kittyKeyboardDepth: Int        // CSI > u pushes / CSI < u pops
    public var isClean: Bool { get }          // true when everything is default
    public init()
}

public final class TUIStateTracker {
    public init()
    public private(set) var state: TUIModeState
    public func observe(_ token: VTToken)
    /// Minimal byte sequence that returns a terminal in `state` to a clean,
    /// usable shell state (exit alt screen, show cursor, disable mouse /
    /// bracketed paste / focus events, reset SGR + scroll region + charset,
    /// pop kitty keyboard levels, end synchronized update). Empty if clean.
    public func restoreSequence() -> Data
    public func reset()
}

public struct TerminalIdentity: Sendable {
    public var termName: String               // e.g. "xterm-256color"
    public var da1: String                    // primary device attributes reply
    public var da2: String                    // secondary DA reply
    public var colorSchemeIsDark: Bool
    public var capabilities: [String: String] // XTGETTCAP name → value
    public init(termName: String, da1: String, da2: String,
                colorSchemeIsDark: Bool, capabilities: [String: String])
    public static var xterm256Color: TerminalIdentity { get }
}

/// Which query families the responder consumes (answers itself) vs forwards
/// to the downstream renderer untouched.
public struct ResponsePolicy: Sendable {
    public var answerColorScheme: Bool        // DECSET/DECRST 2031, CSI ?996n, CSI ?2031$p
    public var answerXTGETTCAP: Bool          // DCS + q ... ST
    public var answerDECRQM: Set<Int>         // modes it may answer from the tracker
    public var answerOSCColorQueries: Bool    // OSC 10/11 with '?' payload
    public init(answerColorScheme: Bool, answerXTGETTCAP: Bool,
                answerDECRQM: Set<Int>, answerOSCColorQueries: Bool)
    public static var conservativeDefault: ResponsePolicy { get } // 2031+996, XTGETTCAP, DECRQM {2026,2031}, no OSC
}

public final class VTQueryResponder {
    public init(identity: TerminalIdentity, policy: ResponsePolicy)
    public var identity: TerminalIdentity { get set }   // theme flips update this
    /// Splits input into bytes to forward downstream and reply bytes to write
    /// back to the PTY. Consumed queries are removed from `forward`.
    public func process(_ input: Data) -> (forward: Data, replies: Data)
    /// Emitted when identity.colorSchemeIsDark changes while 2031 reporting on.
    public var onUnsolicitedReply: ((Data) -> Void)? { get set }
}

public final class VTOutputPipeline {
    /// Convenience composition: tokenizer → responder → tracker, one feed.
    public init(identity: TerminalIdentity, policy: ResponsePolicy)
    public func feed(_ bytes: Data) -> (forward: Data, replies: Data)
    public var trackerState: TUIModeState { get }
    public func restoreSequence() -> Data
}
```

---

## 3. `TetherJobIPC` public API (Swift, server side of TJIP/2)

```swift
public protocol JIPTransport: AnyObject {
    /// Deliver raw bytes read from the peer (any chunking).
    var onReceive: ((Data) -> Void)? { get set }
    func send(_ data: Data) throws
    func close()
}

public struct JIPError: Error, Equatable {
    public let code: String        // errno-style string from the spec
    public let message: String
    public init(code: String, message: String)
}

public struct JIPHandshake: Equatable, Sendable {
    public var ttyFds: [Int32]
    public var cols: Int
    public var rows: Int
    public var termName: String
    public var colorTerm: String   // "truecolor" | "256" | "16" | "none"
    public init(ttyFds: [Int32], cols: Int, rows: Int, termName: String, colorTerm: String)
}

/// Everything the server needs from its host. The integrator implements this
/// against real termios/spawn services; tests use the provided fakes.
public protocol JIPHostDelegate: AnyObject {
    func handshake() -> JIPHandshake
    func ttyGet(fd: Int32) throws -> (isTTY: Bool, isRaw: Bool, cols: Int, rows: Int)
    func ttySetRawMode(fd: Int32, mode: Bool) throws -> Bool     // returns wasRaw
    func spawnStart(argv: [String], cwd: String, env: [String: String],
                    stdio: [String], pty: Bool) throws -> Int32  // returns pid
    func spawnStdin(pid: Int32, data: Data) throws -> Int        // returns window
    func spawnStdinEnd(pid: Int32) throws
    func spawnKill(pid: Int32, signal: String) throws
    func spawnResize(pid: Int32, cols: Int, rows: Int) throws
}

public final class JIPServerSession {
    public init(transport: JIPTransport, delegate: JIPHostDelegate)
    public private(set) var isHandshakeComplete: Bool
    // Server→client pushes (host calls these):
    public func pushResize(cols: Int, rows: Int)
    public func pushSignal(_ name: String)
    public func pushStdin(_ data: Data)              // live PTY bytes; empty is a no-op (not EOF)
    public func pushStdout(pid: Int32, data: Data)   // enforces flow window, chunks to ≤64 KiB
    public func pushStderr(pid: Int32, data: Data)
    public func pushExit(pid: Int32, code: Int32?, signal: String?)
    /// Fires when the flow window for a pid reopens after being exhausted.
    public var onFlowWindowOpen: ((Int32) -> Void)? { get set }
    /// Fires on any protocol violation, after the session closes itself.
    public var onProtocolError: ((JIPError) -> Void)? { get set }
    public func close()
}

/// In-memory transport pair for tests and for the glue's loopback checks.
public final class JIPInMemoryTransportPair {
    public init()
    public var a: JIPTransport { get }
    public var b: JIPTransport { get }
}
```

---

## 4. `TetherJobControl` public API (Swift)

```swift
public struct JobID: Hashable, Sendable { public let raw: Int32; public init(raw: Int32) }
public struct ProcessGroupID: Hashable, Sendable { public let raw: Int32; public init(raw: Int32) }

public enum JobState: Equatable, Sendable {
    case spawning
    case running
    case stopped                       // SIGTSTP/SIGSTOP
    case exited(code: Int32?, signal: String?)
}

public enum JobSignal: String, Sendable, CaseIterable {
    case int = "SIGINT", term = "SIGTERM", kill = "SIGKILL", hup = "SIGHUP",
         winch = "SIGWINCH", tstp = "SIGTSTP", cont = "SIGCONT", quit = "SIGQUIT"
}

/// The integrator implements this per execution lane (embedded Node job,
/// guest ELF, wasm). Tests use the provided FakeJobBackend.
public protocol JobBackend: AnyObject {
    /// Ask the underlying execution lane to deliver a signal. Return false if
    /// the lane has no native delivery (the table then applies the portable
    /// default action itself: e.g. treat KILL/TERM as cancellation).
    func deliver(_ signal: JobSignal, to job: JobID) -> Bool
    func forceTerminate(_ job: JobID)
}

public struct JobSpec: Sendable {
    public var argv: [String]
    public var group: ProcessGroupID?     // nil → new group led by this job
    public var isForegroundCandidate: Bool
    public init(argv: [String], group: ProcessGroupID?, isForegroundCandidate: Bool)
}

public final class JobTable {
    public init(backend: JobBackend, clock: JobClock)
    @discardableResult public func register(_ spec: JobSpec) -> JobID
    public func markRunning(_ id: JobID)
    public func markExited(_ id: JobID, code: Int32?, signal: String?)
    public func state(of id: JobID) -> JobState?
    public func jobs(in group: ProcessGroupID) -> [JobID]
    public private(set) var foreground: ProcessGroupID?
    public func setForeground(_ group: ProcessGroupID?)
    /// Routing rules (portable subset of POSIX):
    /// - signal(to: .foreground) → every non-exited job in the foreground group
    /// - SIGWINCH broadcast → every running job that opted into winch
    /// - SIGCONT moves .stopped → .running before delivery
    /// - delivery to an exited job is a no-op that reports ESRCH
    public enum Target { case job(JobID), group(ProcessGroupID), foreground }
    @discardableResult public func signal(_ sig: JobSignal, to target: Target) -> SignalOutcome
    /// Escalation: TERM, then KILL after `graceMillis` on the injected clock.
    public func terminate(_ id: JobID, graceMillis: Int)
    /// Jobs still not exited after force-terminate → surfaced here for logging.
    public var onOrphanDetected: ((JobID) -> Void)? { get set }
    public func reapExited() -> [JobID]
    public var onStateChange: ((JobID, JobState) -> Void)? { get set }
}

public struct SignalOutcome: Equatable, Sendable {
    public var delivered: [JobID]
    public var failed: [JobID]         // backend returned false
    public var noSuchTarget: Bool      // ESRCH-equivalent
}

public protocol JobClock: AnyObject {
    func schedule(afterMillis: Int, _ work: @escaping () -> Void) -> JobClockToken
}
public protocol JobClockToken { func cancel() }
public final class FakeJobClock: JobClock { /* manual advance(millis:) for tests */ }
public final class FakeJobBackend: JobBackend { /* records deliveries, scriptable */ }
```

---

## 5. `TetherSessionCore` public API (Swift)

```swift
public enum SessionPhase: Equatable, Sendable {
    case idle
    case bootstrapping                 // rootfs download / validation
    case startingShell
    case active
    case suspended                     // app backgrounded
    case tearingDown
    case failed(SessionFailure)
    case closed
}

public enum SessionFailure: Equatable, Sendable {
    case bootstrapFailed(String)
    case engineCrashed(exitCode: Int32)
    case ptyError(String)
    case workspaceUnavailable          // bookmark stale / folder gone
    case rootfsRemoved
}

public enum SessionEvent: Equatable, Sendable {
    case workspaceOpened
    case bootstrapSucceeded, bootstrapFailed(String)
    case shellStarted, shellExited(code: Int32)
    case appBackgrounded, appForegrounded
    case rootfsRemovedExternally
    case workspaceBecameUnavailable
    case ptyFailed(String)
    case userRequestedClose
    case teardownFinished
    case retryRequested
}

/// Ordered side effects. The state machine emits these; the integrator
/// performs them. The machine never touches a PTY or process itself.
public enum SessionCommand: Equatable, Sendable {
    case startBootstrap
    case startShell
    case emitRestoreSequence           // ask VT layer to clean TUI modes
    case snapshotScrollback
    case stopOutputPump
    case signalShell(String)           // "SIGHUP" etc.
    case waitForEngineExit(graceMillis: Int)
    case closePTYAfterReaderStops      // encodes the never-close-under-a-reader rule
    case releaseWorkspaceScope
    case showFailure(SessionFailure)
    case markNeedsBootstrap
}

public final class SessionStateMachine {
    public init()
    public private(set) var phase: SessionPhase
    /// Pure transition: returns the commands to execute, in order.
    /// Illegal events for the current phase return [] and leave phase intact
    /// (recorded in `diagnostics`).
    public func handle(_ event: SessionEvent) -> [SessionCommand]
    public private(set) var diagnostics: [String]
    /// Teardown is idempotent: a second userRequestedClose while tearingDown
    /// returns [] — never a duplicate close command.
}

/// Versioned scrollback snapshot so a session can restore its screen.
public struct ScrollbackSnapshot: Equatable, Sendable {
    public static let formatVersion: Int
    public var cols: Int, rows: Int
    public var rawBytes: Data                 // last N bytes of the PTY stream
    public var trailingModeState: Data        // TUIModeState restore bytes, may be empty
    public func serialized() -> Data          // versioned, checksummed
    public init(cols: Int, rows: Int, rawBytes: Data, trailingModeState: Data)
    public static func deserialize(_ data: Data) throws -> ScrollbackSnapshot
    // deserialize throws on version mismatch or checksum failure — callers
    // then discard the snapshot and start clean, never crash.
}
```

---

## 6. `TetherStorageCore` public API (Swift)

```swift
public struct ManagedAreaID: Hashable, Sendable, RawRepresentable {
    public let rawValue: String; public init(rawValue: String)
    public static let linuxRootfs: ManagedAreaID     // "linux"
    public static let nodeHome: ManagedAreaID        // "node"
    public static let claudeInstall: ManagedAreaID   // "claude"
    public static let pythonPackages: ManagedAreaID  // "python"
    public static let caches: ManagedAreaID          // "caches"
}

public struct ManagedArea: Sendable {
    public var id: ManagedAreaID
    public var displayName: String
    public var relativePath: String            // relative to the container root
    public var deletable: Bool
    public var requiresRebootstrapAfterDelete: Bool
    public init(id: ManagedAreaID, displayName: String, relativePath: String,
                deletable: Bool, requiresRebootstrapAfterDelete: Bool)
}

/// Filesystem abstraction so all logic is testable with the in-memory fake.
public protocol StorageFileSystem: AnyObject {
    func exists(_ relativePath: String) -> Bool
    func isDirectory(_ relativePath: String) -> Bool
    func sizeOfTree(_ relativePath: String) throws -> Int64
    func removeTree(_ relativePath: String) throws
    func list(_ relativePath: String) throws -> [String]
    func destinationOfSymlink(_ relativePath: String) throws -> String?
}
public final class InMemoryStorageFileSystem: StorageFileSystem { /* seedable */ }

public struct DeletePlan: Equatable, Sendable {
    public var area: ManagedAreaID
    public var paths: [String]
    public var estimatedBytes: Int64
    public var blockedBy: [ActiveUseToken]     // non-empty ⇒ must not execute
    public var postActions: [PostDeleteAction] // e.g. .markNeedsBootstrap
}
public enum PostDeleteAction: Equatable, Sendable {
    case markNeedsBootstrap, invalidateRuntime(String), none
}
public struct ActiveUseToken: Hashable, Sendable {
    public let owner: String                   // e.g. "terminal-session"
    public init(owner: String)
}

public final class StorageCatalog {
    public init(areas: [ManagedArea], fileSystem: StorageFileSystem)
    public func acquire(_ token: ActiveUseToken, on area: ManagedAreaID)
    public func release(_ token: ActiveUseToken, from area: ManagedAreaID)
    public func plan(delete area: ManagedAreaID) throws -> DeletePlan
    /// Refuses (throws StorageError.blocked) when plan.blockedBy is non-empty.
    public func execute(_ plan: DeletePlan) throws -> [PostDeleteAction]
    public func integrityReport(for area: ManagedAreaID) -> IntegrityReport
}
public struct IntegrityReport: Equatable, Sendable {
    public var area: ManagedAreaID
    public var present: Bool
    public var missingMarkers: [String]        // e.g. ".tether-bootstrapped"
    public var suspectPaths: [String]
}
public enum StorageError: Error, Equatable {
    case blocked([ActiveUseToken]), unknownArea, notDeletable, io(String)
}

/// Path confinement: pure logic that decides whether a guest-requested path
/// stays inside a confinement root, resolving `..` and symlinks via the
/// StorageFileSystem — rejects escape at any ancestor.
public struct ConfinedPathResolver {
    public init(confinementRoot: String, fileSystem: StorageFileSystem)
    public func resolve(_ guestPath: String) -> Result<String, ConfinementViolation>
}
public enum ConfinementViolation: Error, Equatable {
    case dotDotEscape, symlinkEscape(via: String), absoluteOutsideRoot, emptyPath
}
```

---

## 7. `tether-shim-v2` public surface (JS)

```
tether-shim-v2/
  lib/index.js          // patch entry: require('tether-shim-v2').install(options)
  lib/ipc/framing.js    // TJIP/2 frame encode/decode (stream-safe, partial-chunk safe)
  lib/ipc/client.js     // handshake, req/res correlation, evt dispatch, reconnect-never (fail loud)
  lib/tty.js            // isatty/ReadStream/WriteStream per contract below
  lib/child_process.js  // spawn/spawnSync/exec/execFile over spawn domain
  lib/signals.js        // tty.signal + tty.resize → process.emit wiring
  lib/stdio.js          // stdout/stderr flow-ack, stdin bridging
  test/                 // node:test suites with lib/ipc mock server harness
  test/harness/mock-server.js
  HANDOFF.md
  package.json          // no dependencies
```

Contract highlights (full behavior in the brief):

- `isatty(fd)` is true **iff** `fd` was listed in the handshake `ttyFds`.
  No environment flag can force it. Non-numeric/negative fds → false.
- `WriteStream.getColorDepth(env)` follows Node's real semantics applied to
  the handshake `colorTerm`: truecolor → 24, 256 → 8, 16 → 4, none → 1.
- `tty.resize` events update `columns`/`rows` on every live stream *then*
  emit `'resize'` on those streams *then* emit `'SIGWINCH'` on `process`.
- `ChildProcess` objects expose `pid`, `stdio` streams, `kill(signal)`,
  events `spawn`, `error`, `exit`, `close` with Node-faithful ordering
  (`exit` before `close`; `close` only after stdio streams end).
- All writes respect the flow window; `stream.write()` returns false when
  paused and emits `'drain'` on reopen.

## 8. `tether-bun-compat` public surface (JS)

```
tether-bun-compat/
  lib/index.js          // installBunGlobal({ platformInfo, pathDirs, fs, spawnImpl })
  lib/which.js          // real PATH directory scan; zero hardcoded names
  lib/file.js           // Bun.file / Bun.write over node:fs
  lib/spawn.js          // Bun.spawn/spawnSync mapped onto child_process API shape
  lib/util.js           // Bun.sleep, Bun.env, Bun.version, stringWidth, deepEquals
  test/                 // node:test suites, injected fakes, no real processes
  HANDOFF.md
  package.json          // no dependencies
```

- `Bun.which(name)` scans injected `pathDirs` for an existing executable via
  the injected `fs` — behavior identical for `claude`, `ls`, or any name.
- `installBunGlobal` never overwrites an existing global `Bun` unless
  `force: true`.

---

## 9. Deliverable folder conventions (all agents)

Every returned folder contains:

- `README.md` — what it is, 5-line quick start.
- `HANDOFF.md` — public entry points, how to run tests, **exactly which
  protocols the integrator must implement** (the abstract host/system edges),
  and any deviations from the brief (should be none).
- Full test suite runnable offline: `swift test` or `node --test test/`.
- No git metadata, no CI config, no binaries, no network access at build or
  test time, no third-party dependencies.
