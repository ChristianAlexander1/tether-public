# Agent brief D — `TetherJobControl` (job table, process groups, signal routing)

> **How to use this file:** copy everything below the horizontal rule into a
> fresh agent session as its complete instructions. The agent needs no access
> to any repository, macOS machine, or other document — this brief is
> self-contained.

---

## Mission

Build **`TetherJobControl`**, a pure-Swift package that gives an iOS terminal
app the job-control semantics a Unix kernel normally provides: a table of
jobs (virtual processes) organized into process groups, a foreground group,
portable signal routing (Ctrl-C → foreground group, SIGWINCH broadcast,
CONT/STOP transitions), graceful termination with escalation, and reaping.

Context: the host app runs "jobs" on several execution lanes — an embedded
Node.js runtime, an emulated Linux guest, wasm modules. None of these are real
Darwin child processes, so `kill(2)` does not apply; today signal delivery is
a no-op stub and Ctrl-C only works by accident on some lanes. Your package is
the single source of truth for job state and signal routing. Actual delivery
is behind an injected `JobBackend` protocol; you ship a scriptable fake.

## Ground rules

- Swift 5.9+ package: `// swift-tools-version:5.9`, platforms
  `.macOS(.v13), .iOS(.v16)`.
- **Foundation only.** Must `swift build` / `swift test` on Linux Swift.
- Zero third-party dependencies; offline tests.
- Fully deterministic: time comes only from the injected `JobClock`; no
  threads, no locks, no DispatchQueue. All calls arrive on one serial queue
  owned by the integrator (state this in HANDOFF.md).
- Never crash on nonsense input (signaling unknown jobs, double exits,
  negative grace) — every such case has defined behavior and a test.

## Public API contract (FROZEN — implement exactly; you may add, never change)

```swift
public struct JobID: Hashable, Sendable { public let raw: Int32; public init(raw: Int32) }
public struct ProcessGroupID: Hashable, Sendable { public let raw: Int32; public init(raw: Int32) }

public enum JobState: Equatable, Sendable {
    case spawning
    case running
    case stopped
    case exited(code: Int32?, signal: String?)
}

public enum JobSignal: String, Sendable, CaseIterable {
    case int = "SIGINT", term = "SIGTERM", kill = "SIGKILL", hup = "SIGHUP",
         winch = "SIGWINCH", tstp = "SIGTSTP", cont = "SIGCONT", quit = "SIGQUIT"
}

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
    public enum Target { case job(JobID), group(ProcessGroupID), foreground }
    @discardableResult public func signal(_ sig: JobSignal, to target: Target) -> SignalOutcome
    /// Escalation: TERM now, then KILL via forceTerminate after `graceMillis`
    /// on the injected clock, unless the job exits first.
    public func terminate(_ id: JobID, graceMillis: Int)
    public var onOrphanDetected: ((JobID) -> Void)? { get set }
    public func reapExited() -> [JobID]
    public var onStateChange: ((JobID, JobState) -> Void)? { get set }
}

public struct SignalOutcome: Equatable, Sendable {
    public var delivered: [JobID]
    public var failed: [JobID]
    public var noSuchTarget: Bool
}

public protocol JobClock: AnyObject {
    func schedule(afterMillis: Int, _ work: @escaping () -> Void) -> JobClockToken
}
public protocol JobClockToken { func cancel() }
public final class FakeJobClock: JobClock {
    public init()
    public func advance(millis: Int)   // fires due work in order
}
public final class FakeJobBackend: JobBackend {
    public init()
    public var deliveries: [(JobSignal, JobID)] { get }
    public var forceTerminated: [JobID] { get }
    /// Script per-job responses: which signals report native delivery.
    public func setDeliverable(_ signals: Set<JobSignal>, for job: JobID)
}
```

## Behavior specification (portable subset of POSIX job control)

### Registration and groups

- `register` assigns monotonically increasing `JobID`s starting at 1000
  (leaves room below for reserved ids). If `spec.group == nil`, create a new
  group whose `ProcessGroupID.raw == JobID.raw` (the job is the group
  leader); otherwise join the existing group (unknown group → create it, but
  record a diagnostic — this must not crash).
- If `isForegroundCandidate` and there is currently no foreground group, the
  job's group becomes foreground automatically.
- New jobs start in `.spawning`. Transitions: spawning→running (markRunning),
  spawning/running/stopped→exited (markExited), running→stopped (successful
  TSTP delivery), stopped→running (CONT).

### Signal routing

- `.job(id)`: deliver to that job if not exited; exited/unknown →
  `noSuchTarget = true`, nothing delivered.
- `.group(g)`: deliver to every non-exited job in `g`, in JobID order.
  Empty/unknown group → `noSuchTarget = true`.
- `.foreground`: resolve to the current foreground group; if none,
  `noSuchTarget = true`.
- Per-job delivery procedure:
  1. `SIGCONT` to a `.stopped` job: set `.running` (fire `onStateChange`)
     **then** call backend.
  2. `SIGTSTP` to a `.running` job: call backend; if it returns true, set
     `.stopped`. If false, do not change state (lane can't suspend) and count
     the job in `failed`.
  3. `SIGKILL`/`SIGTERM` when backend returns false: apply the portable
     default — call `backend.forceTerminate(job)` and count as delivered.
  4. `SIGWINCH`/`SIGHUP`/`SIGINT`/`SIGQUIT` when backend returns false: count
     in `failed`, no state change (the caller decides policy).
  5. Signals to `.stopped` jobs other than `SIGCONT`/`SIGKILL` are queued —
     keep at most one pending instance per signal per job, delivered in
     `JobSignal.allCases` order immediately after the job continues.
- `signal` never throws; every path is reported through `SignalOutcome`.

### Termination and reaping

- `terminate(id, graceMillis:)`: send TERM per the routing rules above; if
  the job hasn't reached `.exited` when the clock fires after `graceMillis`,
  call `backend.forceTerminate`; if after a further `graceMillis` it is
  *still* not exited, fire `onOrphanDetected(id)` (once). A job exiting at
  any point cancels the pending escalation via the clock token.
  `graceMillis <= 0` escalates on the next clock fire of 0 ms.
- `markExited` on an already-exited job is a recorded no-op (no double
  `onStateChange`, no crash).
- `reapExited()` returns exited jobs, removes them from the table, prunes
  empty groups, and clears foreground if its group emptied. Signaling a
  reaped id → `noSuchTarget`.
- If the foreground group becomes empty through exits (before reaping),
  `foreground` stays until reaped, but `.foreground` targeting skips exited
  jobs (may produce `delivered: []`, `noSuchTarget: false`).

### Ordering guarantees

- `onStateChange` fires synchronously inside the mutating call, after state
  is updated, before the call returns.
- All lists (`delivered`, `failed`, `reapExited`) are in ascending JobID
  order for deterministic tests.

## Edge cases you MUST handle (each needs a test)

1. Ctrl-C storm: `signal(.int, to: .foreground)` called 3× in a row → 3
   deliveries per running job, no state corruption.
2. TERM→KILL escalation: backend never exits the job → forceTerminate at
   grace, orphan callback at 2× grace; then `markExited` arrives late →
   handled cleanly, orphan already reported (no un-report).
3. Job exits between TERM and the KILL timer → clock token cancelled,
   no forceTerminate, no orphan.
4. `SIGCONT` on a running job → backend called, state unchanged.
5. Queued signals: TSTP-stop a job, send INT and WINCH and INT again →
   exactly one INT + one WINCH queued; CONT → delivery order INT, WINCH
   (allCases order), all through backend.
6. Foreground handoff: fg group exits fully and is reaped → foreground nil;
   next `isForegroundCandidate` registration takes foreground.
7. `signal` to `.group` where half the jobs exited → delivered only to live
   ones, `noSuchTarget == false`.
8. Unknown JobID/group everywhere → `noSuchTarget`, never a crash.
9. WINCH broadcast to a group of 50 jobs where backend fails for 7 → 43
   delivered, 7 failed, correct ordering.
10. Reentrancy: an `onStateChange` handler that calls `state(of:)` and
    `jobs(in:)` observes consistent post-transition state (no partially
    updated table). Do NOT allow handlers to mutate the table reentrantly —
    detect and record a diagnostic instead of deadlocking/corrupting (assert
    via a test that a reentrant `markExited` from a handler is deferred or
    rejected — pick one, document it).
11. `terminate` twice on the same job → single escalation chain (second call
    replaces or joins the first; document which, test it).
12. 10,000 registered jobs → register + signal(.group) + reap complete well
    under a second (simple performance sanity test with `measure` or a time
    bound; no accidental O(n²)).

## Test plan (minimum)

- Suites: `RegistrationTests`, `RoutingTests`, `StopContQueueTests`,
  `TerminateEscalationTests`, `ReapTests`, `ForegroundTests`,
  `ReentrancyTests`, `ScaleTests`.
- Everything driven by `FakeJobClock.advance` and `FakeJobBackend` scripts.
- Target ≥ 100 assertions.

## Acceptance checklist

- [ ] `swift build` / `swift test` pass, zero warnings, Linux Swift 5.9+.
- [ ] Public API matches the frozen contract exactly.
- [ ] All 12 edge cases have named tests.
- [ ] No Foundation-external imports, no concurrency primitives.
- [ ] HANDOFF.md: serial-queue assumption, how the integrator maps lanes
      (embedded Node job / guest process / wasm run) onto `JobBackend`,
      the queued-signal and reentrancy decisions, 10-line wiring example.

## Non-goals

- No real processes, kill(2), or Darwin signals.
- No PTY or terminal knowledge (WINCH is just a routed name here).
- No persistence.
- No async/await surface — synchronous calls on one queue.
