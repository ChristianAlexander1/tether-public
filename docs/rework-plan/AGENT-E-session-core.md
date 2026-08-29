# Agent brief E — `TetherSessionCore` (session lifecycle state machine + scrollback snapshot)

> **How to use this file:** copy everything below the horizontal rule into a
> fresh agent session as its complete instructions. The agent needs no access
> to any repository, macOS machine, or other document — this brief is
> self-contained.

---

## Mission

Build **`TetherSessionCore`**, a pure-Swift package containing:

1. **`SessionStateMachine`** — one exhaustively tested state machine for the
   entire lifecycle of a terminal session in an iOS app: workspace opened,
   rootfs bootstrap, shell start, app backgrounding/foregrounding, external
   rootfs deletion, engine crash, PTY failure, stale workspace, user close,
   teardown, retry. The machine is **pure**: it receives events and returns
   ordered lists of commands; it never touches a PTY, file, or process.
2. **`ScrollbackSnapshot`** — a versioned, checksummed serialization format
   for the terminal's recent output, so a session can restore its screen
   after the app is relaunched.

Context: the host app is an iOS terminal. Its session today is managed by
scattered SwiftUI lifecycle callbacks and notifications; edge cases (rootfs
deleted mid-session, backgrounding during a full-screen TUI, engine crash)
are handled inconsistently and sometimes crash. iOS specifics you must design
for: the app can be suspended at any moment; a security-scoped folder
bookmark can go stale while suspended; the emulated-Linux rootfs directory
can be deleted from a Storage screen while a shell is running; only one guest
machine may run at a time; and a hard invariant — **a PTY descriptor must
never be closed while a reader thread is still blocked on it** (that is why
teardown is expressed as ordered commands).

## Ground rules

- Swift 5.9+ package: `// swift-tools-version:5.9`, platforms
  `.macOS(.v13), .iOS(.v16)`.
- **Foundation only**; `swift build` / `swift test` must pass on Linux Swift.
- Zero dependencies; offline, deterministic tests; no threads/queues/timers.
- The machine is synchronous: `handle(event) -> [SessionCommand]`. The
  integrator executes commands and feeds resulting events back in.
- Illegal event for the current phase → return `[]`, leave phase unchanged,
  append a human-readable line to `diagnostics`. Never trap, never crash.

## Public API contract (FROZEN — implement exactly; you may add, never change)

```swift
public enum SessionPhase: Equatable, Sendable {
    case idle
    case bootstrapping
    case startingShell
    case active
    case suspended
    case tearingDown
    case failed(SessionFailure)
    case closed
}

public enum SessionFailure: Equatable, Sendable {
    case bootstrapFailed(String)
    case engineCrashed(exitCode: Int32)
    case ptyError(String)
    case workspaceUnavailable
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

public enum SessionCommand: Equatable, Sendable {
    case startBootstrap
    case startShell
    case emitRestoreSequence
    case restoreSavedScrollback
    case snapshotScrollback
    case stopOutputPump
    case signalShell(String)
    case waitForEngineExit(graceMillis: Int)
    case closePTYAfterReaderStops
    case releaseWorkspaceScope
    case showFailure(SessionFailure)
    case markNeedsBootstrap
}

public final class SessionStateMachine {
    public init()
    public private(set) var phase: SessionPhase
    public func handle(_ event: SessionEvent) -> [SessionCommand]
    public private(set) var diagnostics: [String]
}

public struct ScrollbackSnapshot: Equatable, Sendable {
    public static let formatVersion: Int
    public var cols: Int, rows: Int
    public var rawBytes: Data
    public var trailingModeState: Data
    public func serialized() -> Data
    public init(cols: Int, rows: Int, rawBytes: Data, trailingModeState: Data)
    public static func deserialize(_ data: Data) throws -> ScrollbackSnapshot
}
```

## Behavior specification — the transition table

Implement exactly this table. Rows are (phase, event) → new phase + ordered
commands. Anything not listed is illegal (→ `[]` + diagnostic).

### From `idle`

| Event | New phase | Commands |
|---|---|---|
| `workspaceOpened` | `bootstrapping` | `[.startBootstrap]` |

### From `bootstrapping`

| Event | New phase | Commands |
|---|---|---|
| `bootstrapSucceeded` | `startingShell` | `[.startShell]` |
| `bootstrapFailed(msg)` | `failed(.bootstrapFailed(msg))` | `[.showFailure(...), .releaseWorkspaceScope]` |
| `userRequestedClose` | `tearingDown` | `[.releaseWorkspaceScope]` then the machine expects `teardownFinished` |
| `workspaceBecameUnavailable` | `failed(.workspaceUnavailable)` | `[.showFailure(...), .releaseWorkspaceScope]` |

### From `startingShell`

| Event | New phase | Commands |
|---|---|---|
| `shellStarted` | `active` | `[.restoreSavedScrollback]` |
| `ptyFailed(msg)` | `failed(.ptyError(msg))` | `[.showFailure(...), .releaseWorkspaceScope]` |
| `shellExited(code)` | `failed(.engineCrashed(exitCode: code))` | `[.showFailure(...), .stopOutputPump, .closePTYAfterReaderStops, .releaseWorkspaceScope]` |
| `userRequestedClose` | `tearingDown` | full teardown sequence (below) |

### From `active`

| Event | New phase | Commands |
|---|---|---|
| `userRequestedClose` | `tearingDown` | **full teardown sequence**: `[.snapshotScrollback, .emitRestoreSequence, .signalShell("SIGHUP"), .waitForEngineExit(graceMillis: 2000), .stopOutputPump, .closePTYAfterReaderStops, .releaseWorkspaceScope]` |
| `shellExited(code == 0)` | `tearingDown` | `[.stopOutputPump, .closePTYAfterReaderStops, .releaseWorkspaceScope]` (clean exit: user typed `exit`) |
| `shellExited(code != 0)` | `failed(.engineCrashed(exitCode: code))` | `[.emitRestoreSequence, .showFailure(...), .stopOutputPump, .closePTYAfterReaderStops, .releaseWorkspaceScope]` |
| `ptyFailed(msg)` | `failed(.ptyError(msg))` | `[.showFailure(...), .stopOutputPump, .closePTYAfterReaderStops, .releaseWorkspaceScope]` |
| `rootfsRemovedExternally` | `failed(.rootfsRemoved)` | `[.emitRestoreSequence, .signalShell("SIGHUP"), .waitForEngineExit(graceMillis: 1000), .stopOutputPump, .closePTYAfterReaderStops, .markNeedsBootstrap, .showFailure(.rootfsRemoved), .releaseWorkspaceScope]` |
| `workspaceBecameUnavailable` | `failed(.workspaceUnavailable)` | same as rootfs removal but `.showFailure(.workspaceUnavailable)` and no `.markNeedsBootstrap` |
| `appBackgrounded` | `suspended` | `[.snapshotScrollback]` (session stays alive; iOS may or may not kill it) |

### From `suspended`

| Event | New phase | Commands |
|---|---|---|
| `appForegrounded` | `active` | `[]` |
| `shellExited(code)` | `failed(.engineCrashed(exitCode: code))` | as in active |
| `rootfsRemovedExternally` | `failed(.rootfsRemoved)` | as in active |
| `userRequestedClose` | `tearingDown` | full teardown sequence |

### From `tearingDown`

| Event | New phase | Commands |
|---|---|---|
| `teardownFinished` | `closed` | `[]` |
| `shellExited(_)` | `tearingDown` (unchanged) | `[]` (already tearing down; recorded in diagnostics as informational) |
| `userRequestedClose` | `tearingDown` | `[]` — **idempotent teardown**: never a duplicate command list |

### From `failed(_)`

| Event | New phase | Commands |
|---|---|---|
| `retryRequested` | `bootstrapping` | `[.startBootstrap]` |
| `userRequestedClose` | `tearingDown` | `[.releaseWorkspaceScope]` (rest was already done on the failure path); machine then expects `teardownFinished` |

### From `closed`

| Event | New phase | Commands |
|---|---|---|
| `workspaceOpened` | `bootstrapping` | `[.startBootstrap]` (a machine is reusable) |

Ordering rationale you must preserve (and state in doc comments):
`snapshotScrollback` before `emitRestoreSequence` (snapshot captures the TUI
bytes and mode repair, then the live renderer is repaired); saved snapshot
replay is the distinct startup command `restoreSavedScrollback`;
`signalShell` before `waitForEngineExit` before
`stopOutputPump` before `closePTYAfterReaderStops` (drain output, stop the
reader, only then close descriptors); `releaseWorkspaceScope` always last.

## ScrollbackSnapshot format

- `formatVersion = 1`.
- `serialized()` layout: ASCII magic `TSSB` (4 bytes) • version (4-byte BE) •
  cols (4-byte BE) • rows (4-byte BE) • rawBytes length (8-byte BE) •
  rawBytes • trailingModeState length (4-byte BE) • trailingModeState •
  CRC32 of everything before the checksum (4-byte BE).
- Implement CRC32 (IEEE 802.3 polynomial) yourself; ~20 lines, include tests
  against known vectors (e.g. CRC32 of ASCII `"123456789"` is `0xCBF43926`).
- `deserialize` throws a descriptive error on: short data, bad magic, version
  ≠ 1, length fields exceeding remaining data, checksum mismatch. Callers
  discard and start clean — so errors must be thrown, never `fatalError`.
- Cap: reject rawBytes length > 4 MiB at both serialize (truncate keeping the
  **tail**, since recent output matters) and deserialize (throw).

## Edge cases you MUST handle (each needs a test)

1. Full happy path: idle→bootstrapping→startingShell→active→(close)→
   tearingDown→closed, asserting every command list verbatim.
2. Rootfs deleted while `active` → exact command sequence from the table,
   including `.markNeedsBootstrap` before `.showFailure`.
3. Double `userRequestedClose` (second while tearingDown) → second returns
   `[]`.
4. `shellExited` arriving during tearingDown → `[]`, no duplicate close
   commands.
5. Crash loop guard: active→failed(engineCrashed)→retry→bootstrapping→…
   works twice in a row on one machine instance; diagnostics accumulate.
6. `appBackgrounded` in `bootstrapping` or `startingShell` → illegal (`[]` +
   diagnostic) — bootstrap continues; iOS grants background time. Document
   this decision.
7. `workspaceBecameUnavailable` while `suspended`? Not in the table → `[]` +
   diagnostic; then on `appForegrounded` the integrator re-checks and may
   send it from `active`. Add a test proving the machine tolerates the
   deferred sequence.
8. Snapshot round-trip: random cols/rows/payloads (seeded), serialize →
   deserialize → equal.
9. Snapshot corruption: flip any single byte of a serialized snapshot →
   deserialize throws (property-style test over every byte index of a small
   snapshot).
10. Snapshot truncation cap: 5 MiB rawBytes → serialized keeps the last
    4 MiB exactly.
11. Version-2 snapshot data (hand-built with version field = 2) → throws a
    version-specific error.
12. Diagnostics: every illegal (phase, event) pair in a generated
    cross-product test (all phases × all events) either matches the table or
    produces `[]` + one diagnostic line — this test enumerates the whole
    matrix so no transition is accidental.

## Test plan (minimum)

- `TransitionTableTests` — every legal row asserted verbatim.
- `TransitionMatrixTests` — full phase × event cross-product (edge case 12).
- `TeardownIdempotenceTests`, `RetryLoopTests`.
- `SnapshotFormatTests` — vectors, round-trip, corruption sweep, cap.
- Target ≥ 120 assertions.

## Acceptance checklist

- [ ] `swift build` / `swift test` pass, zero warnings, Linux Swift 5.9+.
- [ ] Public API matches the frozen contract exactly.
- [ ] The full transition matrix test exists and passes.
- [ ] CRC32 vectors verified.
- [ ] No Foundation-external imports, no timers/threads.
- [ ] HANDOFF.md: how the integrator runs the command lists (serial execution,
      feeding completion events back), the two documented design decisions
      (backgrounding during bootstrap; deferred workspace-check), and a
      15-line wiring example.

## Non-goals

- No SwiftUI, no UIKit, no NotificationCenter.
- No real file/PTY/process work — commands are values.
- No persistence of the machine itself (only the snapshot format).
- No multi-session orchestration (one machine = one session; the app layer
  may own several machines).
