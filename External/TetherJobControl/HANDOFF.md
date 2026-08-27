# TetherJobControl — Handoff

## Serial-queue assumption

`JobTable` is **not** thread-safe. The integrator must make every call (`register`, `signal`, `terminate`, `reapExited`, etc.) on a single serial queue it owns. There are no locks, no `DispatchQueue`, no `Task` — the package is fully synchronous and deterministic.

## Mapping lanes onto `JobBackend`

The integrator creates one `JobBackend` instance per execution lane (embedded Node, Linux guest, wasm module). Each lane is registered with `register()`; the `JobBackend` protocol asks the lane to deliver a signal (`deliver`) or force-terminate (`forceTerminate`). Actual signal routing (grouping, foreground, queuing) lives in `JobTable`; the backend is only the delivery endpoint.

Example wiring:

```swift
let backend = FakeJobBackend()
let clock   = FakeJobClock()
let table   = JobTable(backend: backend, clock: clock)

let id = table.register(JobSpec(argv: ["node", "app.js"],
                                group: nil,
                                isForegroundCandidate: true))
table.markRunning(id)

// Route Ctrl-C to foreground group
_ = table.signal(.int, to: .foreground)
```

## Queued-signal decision

Signals to `.stopped` jobs (other than `SIGCONT`/`SIGKILL`) are queued in a `Set<JobSignal>` per job. When `SIGCONT` continues the job, queued signals are delivered in `JobSignal.allCases` order **with queuing disabled** — this prevents a queued `SIGTSTP` from re-stopping the job and causing an unbounded loop.

## Reentrancy decision

Mutations (`register`, `markRunning`, `markExited`, `signal`, `setForeground`, `terminate`, `reapExited`) are **rejected** when called inside an `onStateChange` handler. A diagnostic string is appended to `table.diagnostics`. The table never deadlocks or corrupts its state.

## Termination escalation

`terminate(id, graceMillis:)` creates a single escalation chain (TERM → KILL after `graceMillis` → orphan after `2*graceMillis`). A second call to `terminate` on the same job **replaces** the previous chain (cancels old tokens, starts fresh). A job that exits at any point cancels its pending tokens.

## Performance

All operations on `JobTable` are `O(1)` or `O(n)` over the group size, with no hidden `O(n²)` loops. The `reapExited()` sweep is `O(jobs)`; `signal(.group)` is `O(group size)`.
