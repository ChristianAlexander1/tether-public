# HANDOFF — TetherSessionCore

This document tells the integrator how to run the state machine and the command
lists it produces, and records the two documented design decisions. It assumes
you are integrating an **iOS host app** that does the real PTY/file/process
work; `TetherSessionCore` itself is pure and does none of it.

---

## 1. How the integrator drives the machine

The machine is **synchronous and front-driven**. You feed it events; it returns
an ordered `[SessionCommand]`. Your job is to execute those commands **serially,
in order**, and to feed back the completion events they spawn. It is *not*
asynchronous: `handle` returns immediately.

The loop, in the abstract:

```
let machine = SessionStateMachine()

// 1. Advance it with an event.
let commands = machine.handle(.someEvent)

// 2. Execute every command, strictly in the order returned.
for command in commands { execute(command) }

// 3. When the work a command triggered completes (or fails), convert that
//    outcome into the matching SessionEvent and call handle again.
```

### Command → event contract (what each command  *means*, and what to feed back)

| Command | What you must do | Completion event to feed back |
|---|---|---|
| `.startBootstrap` | Begin rootfs bootstrap (ensure workspace scope valid, mount/extract rootfs) | `.bootstrapSucceeded` or `.bootstrapFailed(msg)` |
| `.startShell` | Spawn the guest engine and attach a PTY reader | `.shellStarted` or `.ptyFailed(msg)` |
| `.emitRestoreSequence` | Re-render the screen from the most recent `ScrollbackSnapshot` | — (no feedback event) |
| `.snapshotScrollback` | Serialize current scrollback+screen into a snapshot (see §4) | — (no feedback event) |
| `.stopOutputPump` | Signal the reader thread to stop and join it | — (no feedback event) |
| `.signalShell("SIGHUP")` | Send the named signal to the guest process | — (no feedback event) |
| `.waitForEngineExit(graceMillis:)` | Wait up to the grace period for the engine to exit; then proceed regardless | — (no feedback event) |
| `.closePTYAfterReaderStops` | Close the PTY descriptor **only after the reader has stopped** | — (no feedback event) |
| `.releaseWorkspaceScope` | Release the security-scoped bookmark scope | — (no feedback event) |
| `.showFailure(f)` | Present `f` to the user / surface it to UI | — (no feedback event) |
| `.markNeedsBootstrap` | Mark that the rootfs must be re-bootstrapped on next attempt | — (no feedback event) |

### The hard teardown invariant

The commands in a teardown sequence are **ordered for a reason** and must be
executed in exactly that order:

`signalShell` → `waitForEngineExit` → `stopOutputPump` → `closePTYAfterReaderStops`
→ `releaseWorkspaceScope`.

The critical one is **(reader stops) before (PTY close)**. A PTY descriptor must
**never** be closed while a reader thread is still blocked in a read on it —
closing it under the reader is a race that can crash the process. So: drain the
guest, wait for the engine to exit, stop the reader, and only then close the
descriptor. `releaseWorkspaceScope` is always last, because every other step may
still be touching the workspace.

`snapshotScrollback` comes **before** `emitRestoreSequence`: the snapshot
captures the live TUI screen; the restore sequence is what re-renders a clean
screen from it. Snapshot first, restore second.

`markNeedsBootstrap` appears **before** `showFailure(.rootfsRemoved)` in the
rootfs-removal path so that the pending "needs bootstrap" flag is set before the
failure is surfaced/acted on.

---

## 2. The two documented design decisions

### Decision A — `appBackgrounded` during bootstrapping / startingShell is illegal

`appBackgrounded` is only a legal transition from `.active` (→ `.suspended`,
emitting `[.snapshotScrollback]`). If it arrives while `.bootstrapping` or
`.startingShell`, the machine returns `[]`, **keeps the phase unchanged**, and
records a diagnostic. Reason: a session that is not yet `active` has nothing to
snapshot and nothing to suspend; letting the machine "suspend" it there would
misplace the state and risk resuming from a half-built rootfs. During bootstrap
iOS grants background time, so the bootstrap simply continues; once the shell
becomes `.active`, backgrounding is handled normally. The integrator should not
forward `appBackgrounded` to the machine before `.active`.

### Decision B — `workspaceBecameUnavailable` while suspended is deferred

`workspaceBecameUnavailable` is **not** a legal transition from `.suspended`.
The machine returns `[]`, keeps `.suspended`, and records a diagnostic. Reason:
while suspended the app cannot reliably act (e.g. a security-scoped bookmark can
be stale; we can't safely re-acquire scopes or touch the rootfs mid-suspension).
Instead, on `appForegrounded` the integrator **re-checks** workspace validity and,
if still missing, sends `workspaceBecameUnavailable` **from `.active`**, where it
is legal and produces the full shutdown sequence (but without
`markNeedsBootstrap`, since the workspace itself is gone). The machine tolerates
the deferred sequence — it never treats the deferred event as an error, just as
an ignored one, and it is fully ready to handle the real one after foreground.

---

## 3. The integrator's responsibilities (summary)

* One `SessionStateMachine` per session. The app layer may own several.
* Execute returned command lists serially; never reorder them.
* Feed completion events back synchronously (or on the actor/queue you own).
* **Do not** call `.handle` from multiple threads concurrently — the machine is
  deliberately not thread-safe; serialize all access.
* Never close a PTY before the reader is stopped (the machine guarantees it
  returns those commands in that order; you must honor it).
* Pull `machine.diagnostics` for logging; it is human-readable and grows
  monotonically. It never traps and never throws.

---

## 4. ScrollbackSnapshots for restore

`ScrollbackSnapshot` is the persistence format for recent terminal output. To
restore after relaunch you persist `serialized()` (version 1, CRC32-checked).
On launch, `deserialize(_:)` returns the snapshot or throws; on any throw the
caller **discards and starts clean** (never `fatalError`). `rawBytes` is capped
at 4 MiB: oversized payloads are truncated keeping the tail (recent output
matters) at serialize, and rejected at deserialize.

---

## 5. About the test suite

* `TransitionTableTests` — every legal row asserted verbatim + numbered edge
  cases 1–7.
* `TransitionMatrixTests` — full phase×event cross-product (edge case 12),
  driven against an independent reference table.
* `TeardownIdempotenceTests` / `RetryLoopTests` — idempotent close and crash
  loops.
* `SnapshotFormatTests` — CRC32 vectors, seeded round-trip, byte-flip sweep,
  truncation cap, version reject.

All tests are deterministic, offline, no threads/timers.

---

## 6. ~15-line wiring example

```swift
import TetherSessionCore

func run(_ machine: SessionStateMachine, _ event: SessionEvent) {
    for command in machine.handle(event) {
        switch command {
        case .startBootstrap:       startBootstrap()                      // → returns bootstrapSucceeded/failed
        case .startShell:           startShell()                          // → returns shellStarted/ptyFailed
        case .emitRestoreSequence:  emitRestoreFrom(snapshot())           // → nothing
        case .snapshotScrollback:   saveScrollback(snapshot())            // → nothing
        case .stopOutputPump:       reader.stopAndJoin()                  // → nothing
        case .signalShell(let s):   engine.send(signal: s)               // → nothing
        case .waitForEngineExit(let ms): engine.waitForExit(graceMillis: ms) // → nothing
        case .closePTYAfterReaderStops: pty.closeAfterReaderStopped()     // → nothing
        case .releaseWorkspaceScope: scope.release()                      // → nothing
        case .showFailure(let f):   present(f)                            // → nothing
        case .markNeedsBootstrap:   needsBootstrap = true                 // → nothing
        }
    }
}

// Launch path:
let machine = SessionStateMachine()
run(machine, .workspaceOpened)      // → [.startBootstrap]
run(machine, .bootstrapSucceeded)   // → [.startShell]
run(machine, .shellStarted)         // → [] ; phase == .active
// When the user closes:
run(machine, .userRequestedClose)   // → full, ordered teardown list
run(machine, .teardownFinished)     // → [] ; phase == .closed
```

The app's SwiftUI lifecycle callbacks and notifications simply become:
`machine.handle(.appBackgrounded)` / `machine.handle(.appForegrounded)`,
`machine.handle(.workspaceBecameUnavailable)`, `machine.handle(.userRequestedClose)`,
and so on — replacing the old scattered/duplicated logic with one tested machine.
