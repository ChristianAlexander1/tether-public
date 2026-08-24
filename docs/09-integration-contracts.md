# C9 — Integration Contracts & Agent Handoff Rules

> **GIVE THIS DOC TO EVERY AGENT along with their component doc.**
> It defines the repo layout, the frozen APIs between components, the deliverable
> format, and the acceptance tests each component must pass BEFORE handoff.
> Components that follow this doc will snap together; components that don't will be
> sent back. Nothing here is optional.

## 0. Non-negotiable quality bar

- **No demo stubs, no mocks in deliverables.** Every function in your component's public
  API must be fully implemented and pass the acceptance tests below on the iOS Simulator
  (and device where the test says so). "TODO", "placeholder", `fatalError("unimplemented")`
  in shipped code = rejected.
- Where your component *depends on another component that doesn't exist yet*, code against
  the frozen interface in this doc and include a **test double that implements the same
  interface** (clearly under `Tests/`, never in the product target). Your tests run
  against the double; integration will swap in the real thing.
- Everything must build with: **Xcode 16+, Swift 5.10+, iOS 16.0 deployment target,
  arm64 device + arm64 simulator.** C/C++ built as **xcframeworks** (device+simulator
  slices).
- License rule: only licenses on the green list in `07-appstore-licensing.md`. Include a
  `NOTICES/` folder with the license file of every third-party source you pulled in.

## 1. Repo layout (every agent delivers a folder matching this)

```
TermX/                          (workspace root — integrator owns)
├─ App/                         (iOS app target — integrator owns)
├─ Packages/
│  ├─ TermXUI/                  C1 deliverable   (Swift package)
│  ├─ TermXCore/                C2 deliverable   (Swift package, vends C API)
│  ├─ TermXFiles/               C3 deliverable   (Swift package)
│  ├─ TermXPython/              C4a deliverable  (xcframework + Swift wrapper pkg)
│  ├─ TermXNode/                C4b deliverable  (xcframework + Swift wrapper pkg + JS shim)
│  ├─ TermXClaude/              C5 deliverable   (Swift package + JS)
│  └─ TermXLinux/               C6 deliverable   (xcframework + Swift wrapper pkg)
├─ Frameworks/                  prebuilt .xcframework binaries (large; git-lfs)
├─ NOTICES/                     one license file per third-party component
└─ docs/                        these docs
```

Each package: standard SwiftPM layout (`Package.swift`, `Sources/`, `Tests/`), plus a
`HANDOFF.md` at package root stating: what's implemented, how to run the acceptance
tests, known limitations, exact upstream commit hashes of any forked code.

## 2. Frozen interface contracts

These signatures are the law. If you believe one must change, you don't change it — you
flag it in `HANDOFF.md` and the integrator (main agent) decides and re-broadcasts.

### 2.1 Command execution — C header `termx_core.h` (owned by C2, consumed by C1/C4/C5/C6)

```c
// Everything is fd-based. fds are real POSIX fds (pipe or pty slave).
typedef int32_t termx_pid;

typedef struct {
    const char  *cmdline;      // full command line, shell-parsed by TermXCore
    int          stdin_fd, stdout_fd, stderr_fd;
    const char  *cwd;          // absolute POSIX path (already workspace-resolved)
    const char **envp;         // NULL-terminated "KEY=VALUE" array
    bool         interactive;  // true when attached to a pty (isatty must report this)
} termx_spawn_req;

termx_pid termx_spawn(const termx_spawn_req *req);        // async; returns pid or -errno
int       termx_wait(termx_pid pid, int *exit_code);       // blocks calling thread
int       termx_signal(termx_pid pid, int sig);            // SIGINT/SIGTERM/SIGWINCH/SIGKILL
int       termx_run(const termx_spawn_req *req, int *exit_code); // spawn+wait convenience

// Registry (consumed by C4/C6 to add commands):
typedef int (*termx_cmd_main)(int argc, char **argv);
int termx_register_command(const char *name, termx_cmd_main entry);
int termx_register_fallback(  // called when a command isn't found (C6 uses this)
        bool (*can_run)(const char *name),
        int  (*run)(const termx_spawn_req *req));
```

### 2.2 Terminal session (C1 ↔ C2)

C1 owns the pty. C1 calls `termx_spawn` with `stdin/stdout/stderr = pty slave fd`,
`interactive = true`, cmdline `"login-shell"`. On view resize C1 calls
`ioctl(master, TIOCSWINSZ, …)` **and** `termx_signal(shellPid, SIGWINCH)`.
Swift-side protocol C1 must expose:

```swift
public protocol TerminalEngine {                 // implemented by C2's Swift wrapper
    func startShell(cwd: String, env: [String: String],
                    ptySlave: Int32, onExit: @escaping (Int32) -> Void) throws -> Int32
    func signal(pid: Int32, _ sig: Int32)
}
```
C1's test double: an echo engine implementing `TerminalEngine`.

### 2.3 Workspaces (C3 ↔ everyone)

```swift
public struct Workspace: Codable, Identifiable {
    public let id: UUID
    public let name: String          // user-visible
    public let mountPath: String     // "/workspaces/<name>" style virtual path
}
public protocol WorkspaceProviding {
    func addWorkspace() async throws -> Workspace        // shows system picker
    func restoreAll() -> [Workspace]
    func beginAccess(_ w: Workspace) throws -> String    // returns REAL posix path; keeps
    func endAccess(_ w: Workspace)                       //   security scope alive until end
    func resolve(virtualPath: String) -> String?         // /workspaces/x/y -> real path
}
```
Rule for all components: **before touching workspace files, paths must be resolved via
`resolve(virtualPath:)`** — C2 does this centrally in its path layer; C4/C5/C6 receive
already-real paths in `cwd` and never call C3 directly.

### 2.4 Node service (C4b, consumed by C5)

```swift
public protocol NodeService {
    /// Runs a Node program to completion. argv[0] is the script path ("npm", "claude"
    /// resolve via $HOME/node). Serialize or isolate concurrent jobs; queue when needed.
    func run(argv: [String], cwd: String, env: [String: String],
             stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32,
             interactive: Bool) async -> Int32            // exit code
    func interrupt()                                      // SIGINT equivalent to current job
}
```
The JS shim (`@termx/shim`) is part of C4b's deliverable and MUST cover the whole
`child_process` API (spawn/exec/execSync/fork/spawnSync) by routing into `termx_spawn`
via a native binding, plus `os.platform() -> "darwin"`, `tty.isatty -> interactive flag`.

### 2.5 Command registry manifest (C2 owns schema; C4/C6 add entries)

`registry.json` entries: `{ "name": "python3", "kind": "native|wasm|node|linux",
"entry": "symbol-or-path", "framework": "TermXPython" }`. C2 loads all manifests found
under each package's `Resources/registry.json`.

### 2.7 Guest exec dispatch manifest (C6 owns schema; C4b/C3 consume handlers)

`Resources/tether_dispatch_manifest.json` in app bundle:

```json
{
  "default": "guest_elf",
  "browser_openers": ["open", "xdg-open", "gnome-open", "kde-open", "sensible-browser"],
  "host_runtimes": [
    { "match": "basename", "name": "node", "handler": "node-mobile" },
    { "match": "basename", "name": "npm",  "handler": "node-mobile" },
    { "match": "basename", "name": "npx",  "handler": "node-mobile" },
    { "match": "basename", "name": "claude", "handler": "node-mobile" }
  ]
}
```

**Rules:** `default` is always guest ELF. Never add apk-installed tools (`git`, `python3`,
`gcc`, …) to `host_runtimes`. URL openers delegate to C3 `SystemOpen` for **any** https URL.
Full contract: `GUEST-PLATFORM.md`.

### 2.6 Environment defaults (C2 sets; others rely on)

```
HOME=<sandbox>/Documents      PATH=/bin:$HOME/wasm/bin:$HOME/node/bin:$HOME/python/bin
TERM=xterm-256color           LANG=en_US.UTF-8
DISPLAY=:0                    WAYLAND_DISPLAY=tether   BROWSER=open   # guest Linux session
PYTHONHOME/PYTHONPATH per C4a   NODE_PATH/npm_config_prefix per C4b
```

## 3. Acceptance tests per component (run before handoff; list results in HANDOFF.md)

**C1 TermXUI** — with echo double: typed chars round-trip; paste 10KB; resize reports
correct cols/rows; toolbar sends Esc/Ctrl-C bytes; vim-style escape sequences from a
recorded fixture render (snapshot test); 60fps under 1MB/s output stream.

**C2 TermXCore** — on simulator: 100-command smoke run; `ls | grep x > f && cat f`;
`for i in 1 2 3; do echo $i; done`; Ctrl-C kills a `sleep`-alike; `&` + `jobs` + `kill`;
`$?`, `$(cmd)`, globbing; concurrent commands in 2 sessions don't cross streams;
`rg`/`jq`/`fd` produce correct output on fixture tree.

**C3 TermXFiles** — picker grants recursive R/W (manual device test); bookmark survives
relaunch; `resolve()` correct for nested paths; access-scope counting balanced (no leak
after 100 open/close cycles); iCloud-evicted file downloads on open.

**C4a Python** — `python3 -c 'print(1+1)'`; stdlib import sweep (ssl, sqlite3, ctypes);
`pip install requests rich` then use both; `pip install` a wheel from our index; scripts
read/write files in a (double-provided) workspace path.

**C4b Node** — `node -e 'console.log(1+1)'`; `npm init -y && npm i chalk lodash express`
then require all three and run an http server on localhost; **shim proof: `npm i` of a
package with postinstall shell script succeeds with spawns routed through the test double
recording `termx_spawn` calls**; SIGINT interrupts a spin loop.

**C5 TermXClaude** — with real runtimes: fresh install flow of
`@anthropic-ai/claude-code` via npm; login completes; in a sample repo Claude Code lists
files, edits a file, runs `git commit` (lg2), `rg` search works, Esc interrupts a task;
TUI renders through recorded-pty snapshot correctly.

**C6 TermXLinux** — Blink runs BusyBox: full applet self-test; rootfs bootstrap from
Alpine CDN completes; `apk add python3 figlet gcc make` all run; guest pipeline
`ls | wc -l` inside guest sh; guest sees `/workspaces` mapping and edits a file the
native side can read; official Linux arm-agnostic static binary test (bun hello-world).

## 4. Integration phase (what the main agent does when folders come back)

1. Per-component: build + run its own acceptance tests untouched. Fail → back to its agent
   with a written defect list.
2. Wire real implementations in place of doubles, in this order:
   **C3→C2 → C1+C2 → C4a → C4b → C5 → C6** (mirrors runtime dependency order).
3. Cross-component integration suite (integrator-owned, lives in `App/IntegrationTests`):
   the M1–M5 "✔ Demo" lines from `08-roadmap.md` codified as scripted end-to-end runs.
4. Device soak: 30-min Claude Code session on a real repo; memory ceiling < 1.5GB
   (iPad) / < 900MB (iPhone) — Node+Blink lanes monitored; no fd leaks (`lsof` sweep).
5. Only after all green → TestFlight to you for final human testing (your M6 checklist).

## 5. Communication rules for component agents

- You get: your component doc + this doc + `07-appstore-licensing.md`. Read all three.
- Anything ambiguous → make the choice that keeps the frozen APIs intact, and record the
  decision in `HANDOFF.md`.
- Deliver even if a sub-feature slipped: a smaller fully-working surface beats a bigger
  half-working one. List slipped items explicitly.
