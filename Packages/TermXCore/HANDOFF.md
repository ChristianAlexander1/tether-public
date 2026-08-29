# TermXCore Handoff

## Implemented Surface

TermXCore provides the host shell and command execution engine described in `docs/ARCHITECTURE.md`.

### Frozen APIs (Preserved Exactly)

- `TermXPID` (`Int32`)
- `SpawnRequest` (Sendable struct with `cmdline`, `stdinFD`, `stdoutFD`, `stderrFD`, `cwd`, `environment`, `interactive`)
- `CommandMain` (`([String]) -> Int32`)
- `FallbackRunner` (`(SpawnRequest) -> Int32`)
- `CommandRegistry` (`register`, `registerFallback`, `entry`, `run`)
- `JobTable` (`add`, `finish`, `all`)
- `ShellLexer` (`lex`)
- `TermXCommandEngine` (`registry`, `jobs`, `run`)
- `TerminalEngine` protocol (`startShell`, `signal`)

### Architectural Components

1. **`VirtualProcess` & `ProcessContext` (`VirtualProcess.swift`)**:
   - In-process process abstraction with PID, thread, per-process CWD, environ, standard FDs, exit code.
   - Cooperative signal delivery (`SIGINT`, `SIGTERM`, `SIGWINCH`, `SIGKILL`).
   - Thread-local context (`ProcessContext.current`) providing cwd and fd virtualization.
   - `stdoutWriter`/`stderrWriter` hooks for shell-session output capture.

2. **Shell AST & Recursive Descent Parser (`ShellParser.swift`)**:
   - Parses pipelines, `&&`, `||`, `;`, `&`, subshells, redirections, `$(cmd)` tokens.
   - `VariableExpander` resolves `$VAR`, `${VAR}`, `${VAR:-default}`, `$?`, `$$`, `$!`, `~`, and **`$(cmd)` command substitution**.

3. **POSIX Glob Expander (`GlobExpander.swift`)**: `*`, `?`, `[abc]`, `[!abc]`, `**`.

4. **Pipeline & Redirection Executor (`PipelineExecutor.swift`)**:
   - Multi-stage pipelines with POSIX `pipe()` across worker threads.
   - File redirection on pipeline final stage (`cmd | cmd > file`).
   - Background jobs with SIGINT routing.

5. **Shell Control Flow (`ShellControlFlow.swift`)**:
   - `for VAR in ITEMS; do BODY; done` loops (pure-Swift, no mksh port required for acceptance).

6. **Shell Builtins (`Builtins.swift`)**: cd, export, unset, env, alias, history, source, test, printf, kill, fg, bg, jobs, etc.

7. **Pure-Swift Unix Core Commands (`CoreCommands.swift`)**: 30+ commands including cooperative `sleep` (SIGINT → exit 130).

8. **Tool Commands — Pure-Swift Fallbacks (`ToolCommands.swift`)**:
   - `rg`: recursive regex search with `path:line:match` output.
   - `jq`: minimal JSON filter (`.field`, `.[]`, `-r`).
   - `fd`: name/extension search walker.
   - Registered in `Resources/registry.json`.

9. **Terminal Engine & C Bridge (`TermXShellEngine.swift`, `TermXCoreBridge.swift`)**:
   - `TerminalEngine` protocol for C1 PTY integration.
   - C API via `@_cdecl`: `termx_spawn`, `termx_wait`, `termx_signal`, `termx_run`, `termx_register_command`, `termx_register_fallback`.
   - Canonical header: `Sources/TermXCore/include/termx_core.h` (matches frozen contract in §2.1).

10. **Registry Manifest Loader (`RegistryManifest.swift`)**: JSON schema from §2.5.

## Build and Tests

```sh
cd Packages/TermXCore && swift test
```

### Acceptance Test Results (2026-08-22, macOS arm64 — `swift test`)

```
Test Suite 'All tests' passed.
Executed 28 tests, with 0 failures (0 unexpected) in 0.339s
```

| Shell/core acceptance | Test | Status |
|---|---|---|
| 100-command smoke run | `test100CommandSmokeRun` | PASSED |
| `ls \| grep x > f && cat f` | `testAcceptancePipelineRedirectAnd` | PASSED |
| `for i in 1 2 3; do echo $i; done` | `testAcceptanceForLoop` | PASSED |
| Ctrl-C kills `sleep` | `testAcceptanceCtrlCInterruptsSleep` | PASSED |
| `&` + `jobs` + `kill` | `testAcceptanceBackgroundJobsAndKill` | PASSED |
| `$?`, `$(cmd)` | `testAcceptanceExitCodeAndCommandSubstitution` | PASSED |
| Globbing | `testAcceptanceGlobbing` | PASSED |
| Concurrent sessions (no stream cross) | `testAcceptanceConcurrentSessions` | PASSED |
| `rg` / `jq` / `fd` on fixture tree | `testAcceptanceRgJqFd` | PASSED |
| `termx_core.h` C bridge | `testAcceptanceCAPIBridge` | PASSED |

Additional unit tests (parser, lexer, builtins, VirtualProcess, file ops): 19 tests — all PASSED.

## Runtime boundaries

| Item | Status | Notes |
|---|---|---|
| **Native command lane** | The shipped Swift command set is used by the host shell. Native Rust tools under `Vendor/TetherNativeTools` are source/build inputs, not substituted mini implementations. |
| **Shell language lane** | `External/TermXShellLang` backs the production host shell; `External/TetherShellLang` is an independently tested conformance evaluator. |
| **Linux/WASM lanes** | The app routes Linux execution through Blink and WASM execution through `External/TetherWasm`; neither is emulated by shell fixtures. |
| **iOS validation** | Use the repository-level `scripts/validate.sh --ios` gate; canonical evidence and remaining device-only checks live in `docs/VALIDATION.md`. |

## External package integration (T6 / T7 — 2026-08-22)

Dependencies (via `Package.swift`):
- `../../External/TermXCommands` → specialized host-shell tools (`sed`, `awk`, …) in `ExternalCommands.swift`
- `../../External/TetherCommands` → POSIX utilities TermXCommands does not ship; not a second copy of the same set
- `../../External/TermXShellLang` → production host-shell evaluator (`ShellLangBridge.swift`)
- `../../External/TetherShellLang` → test-only conformance oracle (`TetherShellConformanceTests`); not linked into the TermXCore library target

**T6:** 30 commands registered from `TermXCommandRegistry.all` (`sed`, `awk`, `diff`, `chmod`, …). `base64` stays on the existing `CoreCommands` implementation.

**T7:** `ShellSession.eval` routes multiline / compound scripts through `ScriptParser` + `ScriptEvaluator` before the pipeline parser. `ShellHost.run(commandLine:)` delegates to `evalCommandLine`.

Integration tests (passing):
```
testExternalCommandsSedAwkDiffChmod
testShellLangIfWhileCaseFunction
testShellLangParameterExpansionAndArithmetic
testShellLangHereDoc
PtyShellTests.testShellRunsMultipleCommandsOverPty
```

## License Compliance

All shipped third-party logic is original pure-Swift or follows green-list licenses documented in `docs/07-appstore-licensing.md`. No GPL/LGPL code in the product target.

## Upstream References (not vendored)

- [ios_system](https://github.com/holzschu/ios_system) — BSD 3-Clause (target for future native command tier)
- [mksh](https://www.mirbsd.org/mksh.htm) — permissive (target for full POSIX shell)
- [ripgrep](https://github.com/BurntSushi/ripgrep) — MIT (target for native Rust port)
- [jq](https://github.com/jqlang/jq) — MIT
- [fd](https://github.com/sharkdp/fd) — MIT
