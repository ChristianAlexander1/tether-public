# Integration glue guide (local, repo-aware)

This file is for the **local agent working inside this repository** after one
or more agent deliverables have been dropped into the repo root. It is the
only file in this plan that references real paths in this codebase. Follow
the steps in order; each step is independently shippable and ends with its
own verification matrix.

## 0. Receiving a deliverable

For each returned folder (`TetherVTEngine/`, `TetherJobIPC/`,
`tether-shim-v2/`, `TetherJobControl/`, `TetherSessionCore/`,
`TetherStorageCore/`, `tether-bun-compat/`):

1. Move it under `External/` (repo convention for independently buildable
   components). Keep the folder name.
2. Run its own tests standalone first: `swift test` in the folder, or
   `node --test test/`. **Do not integrate a red component.**
3. Read its `HANDOFF.md`. If public API deviates from
   `01-INTERFACE-CONTRACTS.md`, fix the component (or the contract +
   this guide) before wiring anything.
4. Swift packages: add as a local dependency in `project.yml` /
   `Package.swift` of the consuming package, then regenerate
   `Tether.xcodeproj` (repo invariant: edit `project.yml`, regenerate).

## 0.5. Pre-integration cleanup (do once, before step 1)

Remove developer debug residue that will otherwise contaminate testing:

- `Packages/TermXUI/Sources/TermXUI/TerminalOutputPump.swift` — agent debug
  logging with hardcoded `/Users/dev/...` paths.
- `Packages/TermXNode/Sources/TermXNode/Resources/shim/bootstrap.js` —
  leftover debug ingest fetches and absolute host paths.
- `Packages/TermXNode/Sources/TermXNode/NodeStdioBridge.swift` — same class
  of logging.

Gate any remaining diagnostics behind `TETHER_PTY_LOG=1` (existing debug
flag), writing only to app-container paths.

---

## Step 1 — `TetherVTEngine` into the output path (component A)

**Replaces:** `TerminalProtocolAdapter`
(`Packages/TermXUI/Sources/TermXUI/TerminalProtocolAdapter.swift`).

1. Add `TetherVTEngine` as a dependency of `TermXUI`.
2. In `TerminalOutputPump`, replace the adapter with a `VTOutputPipeline`
   constructed from `TerminalIdentity.xterm256Color` with
   `colorSchemeIsDark` bound to the app theme, and
   `ResponsePolicy.conservativeDefault`. Wire:
   - `feed(bytes).forward` → SwiftTerm `feed`.
   - `feed(bytes).replies` and `onUnsolicitedReply` → `session.send(_:)`
     (write back to the PTY master), exactly where the old adapter's
     `sendReply` went.
   - Theme flips (`updateColorScheme` call sites in
     `TerminalSessionView.swift`) → set `pipeline.identity.colorSchemeIsDark`.
3. **Crash restore wiring** (the new capability): in
   `Packages/TermXUI/Sources/TermXUI/TermXUI.swift`, where `TerminalSession`
   observes engine exit (`onExit`) and in `LinuxShellEngine.hostExec`
   completion for host-proxied jobs
   (`App/IntegrationSource/TermXIntegration.swift`), on **abnormal** exit
   (nonzero code or signal) ask the pipeline for `restoreSequence()` and
   feed it to SwiftTerm as if the program had emitted it. Then reset the
   tracker.
4. Keep the old `TerminalProtocolAdapter` tests as expected-behavior oracle:
   port `TerminalProtocolAdapterTests` assertions to run against the
   pipeline (byte-identical 2031/996/`$p` behavior), then delete the old
   adapter.
5. Terminfo hardening (same PR):
   - Ensure `TERM=xterm-256color` is exported in the login environment in
     `LinuxShellEngine` (check `Packages/TermXLinux/Sources/TermXLinux/LinuxShellEngine.swift`
     profile setup).
   - Add `ncurses-terminfo-base` to the Alpine bootstrap package set in
     `AlpineBootstrap` so guest curses apps find the entry.

**Verify:** unit — ported adapter tests + pump tests green
(`swift test` in `Packages/TermXUI`). Simulator —
`apk add vim less htop`; open each, resize, quit → primary screen restored.
Then run `vim`, force-kill via the session (simulate crash) → prompt returns,
cursor visible, no alternate-screen wedge. Claude: `claude`, Ctrl-C mid-TUI →
clean shell.

---

## Step 2 — `TetherJobIPC` + `tether-shim-v2` (components B + C together)

**Replaces:** the ad-hoc JSON IPC between `NodeSocketServer`
(`Packages/TermXNode/Sources/TermXNode/`) and the legacy shim
(`Packages/TermXNode/Sources/TermXNode/Resources/shim/` and its mirror
`External/tether-shim/`).

1. **Interop gate first:** add a test in `TermXNode` that replays
   `TetherJobIPC`'s golden frame fixtures through `tether-shim-v2`'s
   `lib/ipc/framing.js` (run via `Process` + host `node` on macOS test host,
   as `HostNodeRuntime` tests already do). Both sides must agree on every
   fixture byte before any production wiring.
2. Implement the Swift adapters `TetherJobIPC` left abstract:
   - `JIPTransport` over the existing `TETHER_IPC_SOCK` Unix socket fd,
     serialized on the existing node-service queue.
   - `JIPHostDelegate` mapping onto existing services: `ttyGet`/
     `ttySetRawMode` → `PtyTermios` (TermXUI), `spawnStart` →
     `NodeSpawnBridge`/`RegistrySpawnExecutor`, `handshake()` built from the
     real job stdio bindings (which fds were `dup2`-ed to the PTY in
     `NodeStdioBridge.withRedirectedIO`) — **this is where
     `TETHER_INTERACTIVE` faking dies**: `ttyFds` reflects actual bindings.
   - `colorTerm`: `"truecolor"` (SwiftTerm supports 24-bit).
3. Resize/signal push wiring: `TerminalSession.resize` (TermXUI) currently
   ioctls + SIGWINCHes the engine; extend `LinuxShellEngine.hostExec`-run
   jobs so an active `JIPServerSession` gets `pushResize(cols:rows:)`;
   Ctrl-C on the PTY for a host-proxied foreground job → `pushSignal("SIGINT")`.
4. Swap the shim: replace the contents of
   `Packages/TermXNode/Sources/TermXNode/Resources/shim/lib/` with
   `tether-shim-v2` (`--require` entry becomes `lib/index.js` `install()`),
   and update the synchronized copy in `External/tether-shim/`. Update
   `bootstrap.js` to stop passing `TETHER_INTERACTIVE` and to hand the
   socket path through as before.
5. Feature-flag the cutover: `TETHER_IPC_V2=1` selects the new server +
   shim; default stays v1 until the verification matrix passes, then flip
   the default and delete v1 in a follow-up commit.
6. Update `TermXNode` tests: shim API surface tests point at v2 semantics
   (isTTY from handshake, not env). The `NodeSpawnBridge` `which`-faking
   special case is removed in Step 2 as well — `which` resolves through the
   real guest `/usr/local/bin` launchers, which already exist on PATH.

**Verify:** unit — `swift test` TermXNode + TermXUI, `node --test` in
`External/tether-shim-v2`. Simulator matrix:
- `node -e 'console.log([process.stdout.isTTY, process.stdout.columns])'`
  → `[true, <real cols>]` interactive; `node -e ... | cat` → stdout isTTY
  undefined/false while stdin still works (the fd-mix case).
- `node -p 'process.stdout.getColorDepth()'` → 24.
- Rotate device / resize split-view during an Ink app → live reflow
  (SIGWINCH received; this was impossible before).
- `claude` full TUI: correct width, colors, live resize, Ctrl-C exits to a
  clean prompt, `claude | tee /tmp/log` still behaves.
- 1 MB burst: `node -e 'for(i=0;i<4000;i++)console.log("x".repeat(250))'`
  → no memory balloon, ordered output (flow control working).

---

## Step 3 — `TetherJobControl` under the spawn/signal paths (component D)

**Replaces:** `VirtualChildPID` counter + no-op `signal()` in
`RegistrySpawnExecutor` (TermXNode/TermXCore).

1. Add `TetherJobControl` as a dependency of `TermXNode` (and `TermXCore` if
   the host-shell lane should benefit too).
2. Implement `JobBackend` per lane:
   - embedded-Node jobs → cancellation via the existing bootstrap cancel
     path (`SIGINT` emit, force-abort) mapped to
     `deliver(.int)/.forceTerminate`;
   - guest ELF children → Blink interrupt/terminate
     (`BlinkLinuxService.interrupt/terminate`);
   - wasm runs → wasm3 cancellation.
3. Route: `spawn.start` (Step 2's delegate) registers a `JobSpec`;
   `spawn.kill` → `JobTable.signal(_:to:.job(...))`; PTY Ctrl-C for
   host-proxied foreground work → `signal(.int, to: .foreground)`;
   `TerminalSession.resize` additionally →
   `signal(.winch, to: .foreground)`.
   `spawn.exit` events flow from `onStateChange`/`markExited`.
4. Replace ad-hoc job teardown in `EmbeddedNodeService` cancel paths with
   `terminate(_:graceMillis: 750)` (matches current bootstrap force-abort
   grace), and surface `onOrphanDetected` through the existing logging.

**Verify:** unit — component tests + new adapter tests. Simulator —
`node -e 'setInterval(()=>{},1e3)'` then Ctrl-C → exits 130 promptly;
`claude` kill from a second command; a wedged job hits TERM→KILL escalation
without leaving the engine unusable for the next command.

---

## Step 4 — `TetherSessionCore` as the lifecycle spine (component E)

**Replaces:** scattered lifecycle in `AppModel` / `WorkspaceView.onDisappear`
(`App/TetherApp.swift`) and notification-driven teardown.

1. Add to the App target. Instantiate one `SessionStateMachine` per
   `TerminalSession`.
2. Implement a `SessionCommandRunner` in `App/IntegrationSource/` executing
   each `SessionCommand` against real services, preserving command order:
   - `.startBootstrap` → `AlpineBootstrap`; `.startShell` →
     `CoreEngineAdapter.startShell`;
   - `.emitRestoreSequence` → Step 1's pipeline restore;
   - `.snapshotScrollback` → `ScrollbackSnapshot` from the pump's recent
     tail, persisted in the app container;
   - `.signalShell` → `engine.signal`; `.waitForEngineExit` →
     existing non-blocking wait; `.stopOutputPump` /
     `.closePTYAfterReaderStops` → the existing reader-stop-then-close
     sequence in `TerminalSession` (this encodes the repo invariant "never
     close a descriptor a thread is blocked on");
   - `.markNeedsBootstrap` → `BlinkLinuxService.markNeedsBootstrap`;
   - `.releaseWorkspaceScope` → `WorkspaceStore` release.
3. Map inputs to events: SwiftUI scene phase → `appBackgrounded/Foregrounded`;
   `tetherLinuxRootfsRemoved` notification → `rootfsRemovedExternally`;
   stale bookmark detection → `workspaceBecameUnavailable`; engine `onExit`
   → `shellExited(code:)`.
4. On next workspace open, if a scrollback snapshot exists and deserializes,
   feed `rawBytes` to SwiftTerm before the new prompt (banner "restored
   session view"), else discard silently.

**Verify:** unit — command-runner tests with a scripted machine. Simulator —
close workspace mid-`vim` (clean restore + teardown order in logs); delete
Linux packages from Storage while shell is running → defined failure screen
+ re-bootstrap on retry (no crash); background/foreground during `htop` →
session intact; force-quit app → relaunch shows restored scrollback.

---

## Step 5 — `TetherStorageCore` behind StorageView (component F)

**Replaces:** direct `FileManager` deletes in `App/StorageView.swift`;
hardens `LinuxPathMapper` (TermXLinux).

1. Implement `StorageFileSystem` over `FileManager` rooted at the app
   container. Define the five `ManagedArea`s matching today's layout
   (`linux`, `node`, `claude`, `python`, caches) with markers
   (`.tether-bootstrapped` for linux).
2. `TerminalSession` acquires `ActiveUseToken(owner:"terminal-session")` on
   `.linuxRootfs` at shell start; Step 4's runner releases it in teardown.
   StorageView delete buttons now: `plan(delete:)` → show size + blocked
   state → `execute` → run `PostDeleteAction`s (`markNeedsBootstrap` replaces
   the bare notification post).
3. Replace `LinuxPathMapper`'s escape checks with `ConfinedPathResolver`
   (keep `LinuxPathMapper`'s API; delegate internally). Port its existing
   tests — they must all still pass — then add the resolver's extra cases
   (component-prefix confusion, symlink cycles).

**Verify:** unit — both packages green, ported mapper tests green.
Simulator — try deleting Linux data while a shell is open → blocked with
explanation; close workspace → delete succeeds → reopening bootstraps fresh.

---

## Step 6 — `tether-bun-compat` inside the Claude launcher (component G)

**Replaces:** hand-rolled polyfills in `bun-shim.js`
(`Packages/TermXClaude`, installed to `Documents/claude/`).

1. Bundle `tether-bun-compat` with the launcher assets `ClaudeRuntime`
   installs; `bun-shim.js` becomes a thin call to
   `installBunGlobal({ spawnImpl: <the shim'd child_process from Step 2> })`
   plus only the genuinely Claude-specific glue (yaml module mapping to the
   installed `js-yaml`).
2. Delete the hardcoded opener-name list from `Bun.which` — with Step 2 the
   guest launchers are on PATH, so the real scan finds them. Keep
   `SystemOpen` interception at the spawn layer (generic, name-list lives
   only in `GuestDispatchManifest`, the repo's one policy file).
3. Keep `TermXClaude` tests green; add a launcher test asserting no
   command-name literals remain in the shim beyond the manifest.

**Verify:** simulator — fresh `claude` install flow, login, a real edit
session; `claude --version`; opener flow (OAuth browser) still works.

---

## Cross-cutting acceptance (after all steps)

Run the full matrix on simulator + one signed device
(`docs/DEVICE-PASS.md`):

1. vim / less / htop: full-screen, resize, suspend app, resume, quit clean.
2. Claude Code: install → login → TUI session → resize → Ctrl-C → rerun →
   force-kill mid-session → prompt and scrollback intact every time.
3. `yes | head -c 10M > /dev/null`, npm install of a large package, and the
   1 MB Node burst: no memory balloon, no output reordering.
4. Storage: every delete path while sessions open/closed.
5. Lifecycle: background during TUI, rootfs delete mid-session, stale
   bookmark, force-quit + relaunch restore.
6. `rg -n "TETHER_INTERACTIVE|VirtualChildPID" Packages External App` →
   only historical mentions in docs, none in code.
7. `./scripts/validate.sh --quick` green; update `STATUS-AND-REWORK.md` with
   the pass evidence.
