# C10 — Remaining Work (agent handoff)

*Written after the 2026-08-22 integration pass. Give each agent: this file, their component
doc, `09-integration-contracts.md`, and `07-appstore-licensing.md`, plus the `TermX/` folder
as the starting codebase.*

> **Two-track split:** everything in *this* file needs a Mac with Xcode (linking
> frameworks, building for iOS, running the Simulator) **and the repo**. Work that needs
> neither — the JavaScript `child_process` shim, POSIX shell language features, and the
> command set — is in [`11-offline-agent-work.md`](11-offline-agent-work.md), written as a
> **fully self-contained brief**: it can be pasted to an agent that has no access to this
> codebase, and it tells them to create standalone folders (`termx-shim/`,
> `TermXShellLang/`, `TermXCommands/`) against interfaces quoted verbatim in that document.
> Those folders come back and get merged here; nothing they build overlaps this file's work.

## Update — external packages have landed (2026-08-22)

The offline agent's three packages are delivered, repaired, verified, and now live in
`TermX/External/` — `termx-shim` (48 tests), `TermXShellLang` (45 tests) and
`TermXCommands` (27 tests), all green. They are **standalone only; none are wired into the
app yet.** Wiring them is now part of this file's work — see tasks **T6–T8** below, and
read `TermX/External/INTEGRATION-NOTES.md` first (it lists the bugs found and exactly what
each package needs on our side).

## Update — embedding pass (2026-08-22, later)

**Done on Simulator:** T1, T2, T3, T6, T7, T8. Evidence in `STATUS-AND-REWORK.md`.

**Still open:**
- **T4** — `claude login` / interactive Claude Code session with a real Anthropic account
- **T5** — physical-device checklist in `TermX/docs/DEVICE-PASS.md` (Licenses screen shipped)

## Where the project stands

The shell is **done and working on-device**: real pty, pipes, redirects, globbing, loops,
command substitution, job control, `$?`, plus the real folder picker → security-scoped
bookmark → terminal-in-that-folder path. 91 host tests + 13 simulator/UI tests green.

What remains is **embedding the four runtimes into the app binary**. Each is a
self-contained task; T1 is the highest value because it unblocks Claude Code.

## Rules every agent must follow (learned the hard way this pass)

1. **You need a Mac with Xcode 16+.** Agents without it produced code that could not
   compile for iOS. Build and run before delivering:
   `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation -skipMacroValidation build`
2. **iOS has no `Process`, no `fork`/`exec`, no `system()`, no `tar` binary.** Anything
   host-only goes behind `#if os(macOS)`. (This broke the Node and Linux packages; the
   Alpine rootfs now uses the in-process `TarGzExtractor`.)
3. **Everything shares one process.** A signal or crash in a command takes down the whole
   app. `SignalPolicy.installOnce()` already ignores SIGPIPE — do not undo it, and never
   let a command call `exit()`.
4. **Never block the main thread**; never close a pty/pipe fd while another thread is
   blocked reading it (drain first — see `TerminalSession.shutdownPTY`).
5. **Do not change the frozen APIs** in `09-integration-contracts.md`. The only addition
   this pass was `TermXShellEngine.sessionConfigurator`.
6. **No stubs that silently do nothing.** If a runtime is unavailable, write a clear
   message to stderr and return a non-zero exit code — `TermXNode` and `TermXPython`
   already model this.
7. **Deliver with tests that actually ran**, and paste the output in `HANDOFF.md`.

> **Suggested order now that the external packages have landed:** do **T6 and T7 first** —
> they are pure Swift, need no binaries or downloads, and immediately make the shipping
> terminal far more capable — then T1 together with T8, then T2, T3, T4, T5.

## T1 — Node.js inside the app  *(owner: A5 · unblocks Claude Code · highest priority)*

**State:** `Frameworks/NodeMobile.xcframework` is built (163MB, device + simulator slices).
`EmbeddedNodeService`, the job queue, the stdio bridge and `@termx/shim` all exist and pass
9 unit tests on the host, where they drive real Node. On iOS, `NodeMobileRuntime.run()`
returns 127 with "embedded runtime not yet linked" — the framework is not linked into the
app target and there is no `node_start` bridge.

**Do:**
1. Link `NodeMobile.xcframework` into the app target (add it to `project.yml`, or expose it
   as a `binaryTarget` from `Packages/TermXNode/Package.swift` the way `TermXPython` does
   with its `Vendor/` symlink).
2. Write the C bridge that calls `node_start(argc, argv)` on a dedicated thread, with
   `process.stdout/stderr/stdin` mapped to the job's fds and `tty.isatty` reflecting
   `interactive`.
3. Preload `@termx/shim` (`--require`) and route its `child_process` calls into
   `termx_spawn`, so npm lifecycle scripts can run `sh`, `git`, `rg`.
4. Replace the iOS branch of `NodeMobileRuntime` with the real implementation.

**Acceptance (must be run inside the app, not only in host tests):**
`node -e 'console.log(2+2)'` prints 4 · `npm init -y && npm install express` completes,
including a package with a postinstall script · `node -e` reading piped stdin works ·
Ctrl-C interrupts a spin loop.

## T2 — Python standard library in the app bundle  *(owner: A4)*

**State:** `Frameworks/TermXPython.xcframework` (CPython 3.14 via BeeWare) links, and the
`PyConfig`-based bridge is real — on the host, `python3 -c`, the stdlib import sweep, and
`pip install requests rich` all pass. In the app it reports
"Python standard library not bundled in this build" because no stdlib ships inside the
bundle. (iOS deliberately refuses to fall back to a filesystem path — the Simulator can see
the Mac's disk, which was hiding this failure.)

**Do:**
1. Add a build phase copying the correct per-platform `python-stdlib` (device vs simulator
   slice) into the app bundle, and make `EmbeddedPythonService` find it (the
   `Bundle.module` "PythonLib" branch already exists — point it at the app bundle).
2. Package binary extension modules (`_ssl`, `_sqlite3`, …) as signed frameworks — the
   standard `Python-Apple-support` app-integration step; plain `.so` files inside the
   bundle will not load on device.
3. Keep `pip`'s no-fork bootstrap working (`bootstrapPipIfNeeded`).

**Acceptance in the app:** `python3 -c 'print(6*7)'` → 42 · `import ssl, sqlite3` works ·
`pip install rich` then a script using it runs · a script reads and writes files in the
picked workspace.

## T3 — Linux lane (Blink + Alpine)  *(owner: A6)*

**State:** Blink builds for the host (`Frameworks/.build/blink/host/blink.a`); the service,
path mapping, rootfs bootstrap and in-process `TarGzExtractor` exist; 8 tests pass (2
skipped). No iOS arm64 build, so `linux` currently falls through to "command not found".

**Do:** build Blink for iOS arm64 + simulator in interpreter mode (no JIT — `PROT_EXEC` is
unavailable), wire `termx_blink_run` to the fds, bootstrap the Alpine minirootfs on first
use, and map `/workspaces` into the guest.

**Acceptance in the app:** `linux busybox echo hi` · `apk add python3 figlet` · a guest
pipeline (`ls | wc -l`) · a file written by the guest is visible to native `cat`.

## T4 — Claude Code end-to-end  *(owner: A5, immediately after T1)*

**State:** `ClaudeCodeService` (install/login/run/interrupt) and the launcher exist and pass
6 unit tests; it is blocked only by Node.

**Acceptance:** in a picked folder, `claude` installs `@anthropic-ai/claude-code` from npm,
logs in with a real account, edits files, runs `git commit`, searches with `rg`, and Esc
interrupts a task — with the TUI rendering correctly in SwiftTerm.

## T6 — Wire `TermXCommands` into the engine  *(new; unlocks ~30 commands)*

`TermX/External/TermXCommands` holds `sed`, `awk`, `diff`, `chmod`, `stat`, `readlink`,
`mktemp`, `tac`, `rev`, `nl`, `paste`, `fold`, `expand`, `split`, `comm`, `join`, `shuf`,
`expr`, `md5sum`, `shasum`, `xxd`, `hexdump`, `file`, `truncate`, `tree`, `base64`,
`timeout`, `printenv`, `id` — each a pure `CommandIO → CommandResult` function, tested.

**Do:** add the package as a dependency of `TermXCore` (or vendor the sources), then in
`CoreCommands`/`ToolCommands` register every entry of `TermXCommandRegistry.all` with an
adapter that reads stdin from `ProcessContext.current?.stdinFD` when the command has no
file operands, and writes `stdout`/`stderr` to the corresponding fds with the right exit
code. Resolve name collisions with existing built-ins (at minimum `base64`) by keeping one
implementation. **Acceptance:** in the app, `ls | awk '{print NR, $1}'`,
`cat f | sed 's/a/b/g'`, `diff -u a b`, and `chmod +x f` all behave like the real tools.

## T7 — Wire `TermXShellLang` into `ShellSession`  *(new; replaces the `for`-only shell)*

**Do:** implement its `ShellHost` protocol over `PipelineExecutor` (`run(commandLine:)` →
the existing evaluation path, `write`/`writeError` → the session's output handler,
`value(for:)`/`setValue` → `ShellState.environ`). In `ShellSession.eval`, call
`ScriptParser.parse(source)` first and evaluate the returned node when it is non-nil,
falling back to today's path when it is nil. Retire `ShellControlFlow.evalForLoop` only
once `for` loops are covered by the new layer or kept alongside it.
**Acceptance:** in the app — `if [ -f a.txt ]; then echo yes; else echo no; fi`,
a `while` loop with `break`, a `case` statement, a shell function with `$1`/`$#`,
`${V:-default}`, `$((6*7))`, and a `<<EOF` here-doc all work, and the existing
`PtyShellTests` still pass.

## T8 — Swap in the delivered `termx-shim`  *(new; do it with T1)*

The shim in `TermX/External/termx-shim` is far more complete than the one currently inside
`Packages/TermXNode/Sources/TermXNode/Resources/shim/`. When the Node runtime is linked
(T1), replace the bundled copy with this one and keep the Swift reply keys in
`NodeSpawnBridge` matching `lib/ipc.js`. **Acceptance:** the shim's own `npm test` still
passes against the real Swift backend, and `npm install express` works in the app.

## T5 — Device pass & UX polish  *(owner: A3 / A1)*

- Run on a **physical iPhone/iPad**: bookmark persistence across relaunch, iCloud-evicted
  file download on open, security-scope leak check (100 open/close cycles).
- Terminal tabs and iPad multi-window; scrollback search; font-size pinch.
- Speed up `TerminalTypingTests` (~2 min because XCUITest snapshots the terminal canvas).
- Settings → Licenses screen generated from `NOTICES/` before any submission.

## Verification harness (use it, don't hand-test)

DEBUG builds accept two environment hooks, compiled out of release:

```bash
SIMCTL_CHILD_TERMX_AUTOWORKSPACE=1 \        # skip the picker, use the sandbox Documents dir
SIMCTL_CHILD_TERMX_AUTOCOMMANDS='echo hi > a.txt
ls | wc -l > count.txt' \                   # newline-separated commands typed into the shell
xcrun simctl launch "iPhone 17 Pro" com.tether.app
# verify: $(xcrun simctl get_app_container "iPhone 17 Pro" com.tether.app data)/Documents
```

Run the whole suite before delivering:

```bash
for p in TermXCore TermXFiles TermXNode TermXClaude TermXPython TermXLinux; do
  (cd Packages/$p && swift test); done
xcodebuild -scheme Tether -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipPackagePluginValidation -skipMacroValidation test
```
