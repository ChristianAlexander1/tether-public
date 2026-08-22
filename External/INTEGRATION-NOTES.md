# External packages — integration notes

*Delivered by the offline (no-repo-access) agent against `docs/11-offline-agent-work.md`.
Verified and repaired by the integrator on 2026-08-22.*

## Status

| Package | Language | Tests | State |
|---|---|---|---|
| `termx-shim/` | JavaScript | **48 pass** | Arrived working. Ran as delivered, no changes needed. |
| `TermXShellLang/` | Swift | **45 pass** | Arrived not compiling; repaired (see below). |
| `TermXCommands/` | Swift | **27 pass** | Arrived not compiling; repaired (see below). |

Both Swift packages were written without a Swift toolchain — the agent said so plainly in
its `HANDOFF.md` rather than claiming success, which is the right behaviour, but it means
neither had ever been compiled or run. The JavaScript package was fully tested by the agent
and needed nothing.

## Integration status (2026-08-22)

**T6 and T7 are wired into `TermXCore`:**

- `TermXCommands` → `ExternalCommands.registerAll(into:)` (skips `base64`; existing
  `CoreCommands` copy kept). Adapter reads stdin via `ProcessContext` and writes stdout/stderr
  to the active virtual process fds.
- `TermXShellLang` → `ShellLangIntegration` + `ShellSessionHost` implement `ShellHost` over
  `PipelineExecutor`. `ShellSession.eval` tries `ScriptParser.parse` / multiline
  `evalScript` before the legacy single-line path; `for` loops remain in `ShellControlFlow`.
- Parser fix: single-quoted argv words are marked `literalArgv` so `$1` inside `awk '{...}'`
  is not shell-expanded.
- Registry fix: pipeline stages call `registry.run(argv:request:write:)` so re-lexing a
  joined cmdline does not split `{print NR, $1}` on spaces.
- `test`/`[` file tests resolve paths against `ProcessContext.current.cwd`.

**T8 shim swap (2026-08-22):** ✅ Done — see above.

**T2 Python stdlib (2026-08-22):** BeeWare `install_python` post-compile script in `project.yml`
copies `$APP/python/lib` + extension frameworks. `EmbeddedPythonService` resolves
`Bundle.main/.../python/lib/python3.14`. Bridge supports app-bundle `PYTHONHOME`.

**T3 Blink iOS (2026-08-22):** `Frameworks/Blink.xcframework` built; `TermXLinux` links it on
iOS; first `linux` command auto-bootstraps Alpine. Simulator: `busybox echo hi` → `hi`.

**T8 shim swap (2026-08-22):** `Packages/TermXNode/Sources/TermXNode/Resources/shim/` now tracks
`External/termx-shim` (48 JS tests). Bundled additions on top of the delivered shim:
- `bootstrap.js` — persistent nodejs-mobile job loop (`TERMX_JOB_FD` / `TERMX_JOB_REPLY_FD`)
- `ensure-ipc.mjs` — `--import` preload that `await ipc.connect()` before host `-e` scripts run
- `lib/ipc.js` — `socket.unref()` after connect so short-lived host Node processes exit cleanly

**T1 Node linking (2026-08-22):** `NodeMobile.xcframework` is exposed from `TermXNode` via
`Vendor/NodeMobile.xcframework` + `NodeMobileBridge` (`termx_node_launch` / `termx_node_request_interrupt`).
`NodeMobileRuntime` on iOS starts `node_start()` once with `bootstrap.js` + shim preload; macOS tests still
use `HostNodeRuntime` + system Node.

## Repairs made by the integrator

### TermXShellLang (was: ~10 compile errors, then 13 failing tests)
- Compile: single-quoted character literal; `Substring`/`String` mismatches; `ArithParser`
  constructed on a temporary; three `ArithLexer` methods mutating `i` without `mutating`;
  `parseInt` called as an instance member; hand-written `Equatable` for `ShellNode`
  (tuple payloads block synthesis); a duplicated test method; an `Int` vs `Int32` literal.
- Logic bugs found by running the tests:
  - **Parenthesised arithmetic always failed** — the lexer emits `.rparen`/`.lparen`
    tokens but `expect(")")` only matched `.op(")")`.
  - **Here-docs swallowed their terminator** — the body slice used `terminator + 1`, so
    `EOF` appeared in the body and the remainder was short by one line.
  - **Comments were not stripped** — a leading `#` reached the parser as a word.
  - **`if` never closed correctly** — `break` inside a Swift `switch` exits the switch, not
    the enclosing loop, so after consuming `fi` the parser kept looping and threw; a
    missing `fi` at EOF also failed to throw. Rewritten with an explicit `closed` flag.
  - **`${V:$start}`** — offsets are an arithmetic context, where `$start` and `start` are
    the same reference; `parseArith` now strips the sigil.

### TermXCommands (was: 61 compile errors, then 2 runtime bugs)
- Compile: `AwkExpr`/`AwkStmt`/`AwkPattern` needed `indirect`; `[AwkValue]` literals built
  from bare strings; `try` to the right of `+`; `Int` where `Double` was required;
  `.count` on `Range<String.Index>`; `NSRange` passed to `String.substring(with:)` instead
  of `NSString`; `SimpleCommand()` missing its `op` argument; `quit = 0` on a `Bool`;
  `.typeSymlink` → `.typeSymbolicLink`; `join` iterating a tuple array as if grouped;
  `FileHandle.truncate/close` availability (fixed by declaring platforms in `Package.swift`).
- **`CommandIO.swift` errors were the spec's fault, not the agent's**: doc 11 quoted the
  interfaces as bodyless declarations and the agent pasted them verbatim. Doc 11 has since
  been corrected to say the sketches need real bodies.
- Logic bugs found by integrator smoke tests (`Tests/TermXCommandsTests/SmokeTests.swift`,
  added during integration):
  - **Every named awk variable was broken** — the identifier parser began scanning one
    character late, so `NR` parsed as `R` and resolved to empty.
  - **Numbers printed as `1.0`** — awk prints integral values without a decimal part.

## What still needs doing before these ship

These packages are verified **standalone**; they are not yet wired into the app.

1. **`TermXCommands` → `TermXCore` registry.** Each command is a pure
   `CommandIO → CommandResult` function. Wrap them with the fd plumbing
   (`ProcessContext.current` stdin/stdout/stderr) and register each name, taking care that
   they read stdin when given no file operands. Watch for names that already exist in
   `CoreCommands`/`ToolCommands` (e.g. `base64`) and pick one implementation.
2. **`TermXShellLang` → `ShellSession`.** Implement `ShellHost` on top of
   `PipelineExecutor` (its `run(commandLine:)` maps to `eval`), then call
   `ScriptParser.parse` in `ShellSession.eval` before the existing single-line path, and
   fall through when it returns `nil`. This replaces the current `for`-only
   `ShellControlFlow`.
3. **`termx-shim` → `TermXNode`.** ✅ Done (2026-08-22). Delivered shim copied to
   `Packages/TermXNode/Sources/TermXNode/Resources/shim/` with TermX-specific
   `bootstrap.js` / `ensure-ipc.mjs`. Swift `NodeSpawnBridge` reply keys match `lib/ipc.js`.
4. Re-run the full app test suite and an on-Simulator pass after each of the above.
