# Tether rework plan — a concrete terminal, built by independent agents

This folder is the complete build plan for upgrading Tether from "works in the
happy path" to a hardened, real terminal platform. It is designed for a
specific workflow:

- **You** copy one `AGENT-*.md` file per online agent. Each brief is fully
  self-contained: the agent needs **no access to this Mac, this repo, or any
  other brief**. Everything it must know (context, API contract, wire
  protocol, edge cases, tests) is inside its own file.
- **Each agent** returns one folder (a Swift package or a Node package) that
  builds and passes its own tests standalone.
- **You** drop each returned folder into the root of this repo.
- **The local agent (Cursor, with repo access)** then follows
  `90-INTEGRATION-GLUE.md` to wire the folders into the app in a fixed order,
  behind flags, with a verification matrix at each step.

Nothing here depends on agents talking to each other. All coordination happens
through the interface contracts in `01-INTERFACE-CONTRACTS.md`, which are
copied verbatim into the briefs that need them.

## Why this plan exists — the honest diagnosis

Tether's core is real: a Darwin PTY, a SwiftTerm VT grid, an Alpine login
shell under Blink, embedded Node. But the seams between those pieces are where
it breaks today:

1. **The host-runtime TTY story is faked.** `tty.js` returns `isTTY = true`
   for *every* fd whenever `TETHER_INTERACTIVE=1`, color depth is hardcoded to
   8, window size is polled instead of pushed, and no SIGWINCH ever reaches a
   Node TUI. This is exactly why full-screen TUIs (Claude Code, Ink apps, vim
   inside npm scripts) render wrong, don't reflow on rotation, or leave the
   terminal wedged.
2. **No cleanup when a TUI dies.** A program that enters the alternate screen
   (`ESC[?1049h`), hides the cursor, or turns on mouse reporting and then
   crashes leaves the terminal stuck in that state. Real terminal multiplexers
   (tmux, ssh) track modes and synthesize the restore; Tether does not, yet.
3. **Signals are stubs on the host lane.** Virtual PIDs exist, but
   `signal()` on the registry executor is a no-op; Ctrl-C, kill, job control
   and SIGWINCH have no unified routing for host-run jobs.
4. **Lifecycle edges crash or leak.** Rootfs deleted mid-session, app
   backgrounded during a TUI, workspace bookmark gone stale, PTY closed while
   a reader is blocked — each is handled ad hoc (or not at all) instead of by
   one tested state machine.
5. **Special-case hardcoding.** Opener name lists in three places, `which`
   faking, a Bun shim that special-cases command names, only four Node CLI
   flags recognized. Each of these should be a generic mechanism.
6. **Storage/isolation is UI-driven, not model-driven.** StorageView deletes
   directories and posts a notification; guards against deleting a rootfs
   under a live session are implicit.

## The component map

Each component is one agent brief, one deliverable folder, one integration
step. Domains are chosen so that **no two agents share mutable state** — they
only share frozen contracts.

| ID | Brief | Deliverable folder | Language | Domain |
|----|-------|--------------------|----------|--------|
| A | `AGENT-A-vt-engine.md` | `TetherVTEngine/` | Swift (pure) | Byte-stream domain: VT/ANSI tokenizer, terminal-mode tracker (alt screen, cursor, mouse, bracketed paste), query responder, crash-restore synthesizer |
| B | `AGENT-B-job-ipc.md` | `TetherJobIPC/` | Swift (pure) | Wire domain: TJIP/2 framed protocol — codec, session state machine, flow control (server side) |
| C | `AGENT-C-node-shim.md` | `tether-shim-v2/` | Node.js | Guest-JS domain: TJIP/2 client, honest `tty` module, `child_process` bridge, SIGWINCH delivery, backpressure |
| D | `AGENT-D-job-control.md` | `TetherJobControl/` | Swift (pure) | Process domain: job table, process groups, signal routing, foreground job, orphan reaping |
| E | `AGENT-E-session-core.md` | `TetherSessionCore/` | Swift (pure) | Lifecycle domain: session state machine (open/background/rootfs-removed/crash/teardown), scrollback snapshot format |
| F | `AGENT-F-storage-core.md` | `TetherStorageCore/` | Swift (pure) | Storage domain: managed-area catalog, delete plans with live-session guards, integrity probes, path confinement |
| G | `AGENT-G-bun-compat.md` | `tether-bun-compat/` | Node.js | Bun-API domain: honest Bun polyfill library (`Bun.which` via real PATH scan, `Bun.spawn`, `Bun.file`, …) |

### How the components fix the TUI problem end to end

The terminal-capability model (primary/alternate screen buffers, cursor
addressing, PTY, raw mode, terminfo) maps onto the components like this:

- **Alternate screen + cleanup**: SwiftTerm already implements the alternate
  buffer. Component **A** adds what's missing around it — a tracker that
  watches the byte stream for `DECSET 1049/47/1047`, cursor hide, mouse modes,
  bracketed paste, application keypad, and synthesizes the exact restore
  sequence when a job exits abnormally. Claude Code vanishing cleanly, even
  when killed, becomes a guarantee instead of luck.
- **Honest TTY semantics**: components **B + C** replace the faked
  `isTTY`/polled-size shim with a handshake that tells the JS side exactly
  which fds are PTY-bound, pushes resize events (so Node receives real
  `SIGWINCH`), reports true color depth from the session's `TERM`/`COLORTERM`,
  and round-trips raw mode against the real termios.
- **Signals and job control**: component **D** gives every host job a real
  lifecycle: process groups, foreground job, Ctrl-C/SIGTERM/SIGWINCH routing,
  reaping — the same rules a Unix kernel applies, in one tested table.
- **Terminfo**: the glue step pins `TERM=xterm-256color`, installs
  `ncurses-terminfo-base` in the rootfs bootstrap, and component **A** answers
  `XTGETTCAP` so capability probes succeed even without the database.
- **Survivability**: components **E + F** make lifecycle and storage edges
  (backgrounding mid-TUI, deleting the rootfs, stale bookmarks) go through one
  state machine with explicit, tested transitions instead of scattered
  notification handlers.

## Rules that keep the glue trivial

These rules are embedded in every brief; they are what makes seven
independently built folders assemble without surprises:

1. **Contracts are frozen.** Public API signatures and the TJIP/2 wire spec in
   `01-INTERFACE-CONTRACTS.md` are copied verbatim into briefs. Agents may add
   API, never change or remove what the contract names.
2. **Pure core, adapter edge.** Swift packages must build and test with plain
   Foundation on macOS *and* Linux (online agents usually run Linux). Anything
   Darwin-only (ioctl, openpty, security scopes) lives behind a protocol the
   glue implements locally — the agent ships the protocol and a fake, never
   the syscall.
3. **Zero third-party dependencies.** `swift test` and `node --test` must pass
   offline with only the standard toolchain (Swift 5.9+, Node 18+).
4. **Determinism.** No sleeps, no wall clocks, no real sockets in unit tests.
   Clocks, transports and filesystems are injected.
5. **Every folder ships a `HANDOFF.md`** describing what it is, how to run its
   tests, its public entry points, and exactly what the integrator must
   provide (the adapter protocols it left abstract).
6. **No hardcoded program names.** Briefs forbid special-casing `claude`,
   `git`, opener names, etc. Mechanisms are generic; policy stays in the one
   dispatch manifest this repo already owns.

## Suggested build order (agents run in parallel; integration is ordered)

All seven agents can run **simultaneously** — nothing blocks on anything.
Integration order (see `90-INTEGRATION-GLUE.md` for the detailed steps):

1. **A** (VT engine) — pure output-path win, lowest risk, immediately fixes
   stuck-terminal-after-crash.
2. **B + C together** (IPC v2 + shim v2) — flipped behind `TETHER_IPC_V2=1`,
   then made default. This is the Claude-Code/TUI correctness milestone.
3. **D** (job control) — routes signals over the now-real IPC.
4. **E** (session core) — replaces ad-hoc lifecycle handling.
5. **F** (storage core) — replaces StorageView's direct deletes.
6. **G** (bun-compat) — swaps the hardcoded bun-shim internals.

Each step has its own verification matrix and can ship independently.

## What "done" looks like

- `apk add vim htop less` → all three run full-screen, resize live, and exit
  restoring the primary screen with scrollback intact.
- `claude` runs its TUI at true window size and color depth, survives device
  rotation, and whether it exits, is Ctrl-C'd, or is force-killed, the shell
  prompt and prior history come back clean.
- Killing the app, deleting the rootfs from Storage, or losing a workspace
  bookmark mid-session lands in a defined state with a defined message —
  never a crash.
- No command name appears in Swift source except the dispatch manifest.
