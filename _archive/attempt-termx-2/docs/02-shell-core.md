# C2 — Shell & Command Engine

**Goal:** The "operating system" of our terminal: a shell that parses command lines
(pipes, redirection, globbing, env vars, history) and an engine that executes 1000+
Unix commands **in-process at native speed** — since iOS forbids fork/exec.

## Reuse decision

**Foundation: [ios_system](https://github.com/holzschu/ios_system) — BSD 3-Clause.**
This is the engine behind a-Shell (also BSD) and LibTerm. It gives us, today:

- The in-process "process" model: each command's `main()` is compiled into a framework;
  "spawning" = calling it on a thread with its own stdin/stdout/stderr, cwd and environ
  handled per-"process". Thread-local storage isolates concurrent commands.
- ~150 commands ported already: `ls cp mv rm mkdir touch cat grep sed awk find tar gzip
  curl scp sftp ssh(via libssh2) diff sort head tail wc chmod ln du df env date uname …`
- Add-on frameworks from the same author (all BSD/permissive):
  - **lg2** → `git` (clone/pull/push/commit/log; libgit2-based, avoids GPL git)
  - **vim**, **texlive** ports, **llvm/clang** (a-Shell even compiles C locally!)
- Command registry: JSON manifest maps names → dylib+symbol; trivially extensible.

We fork ios_system into our repo (BSD allows it), keep attribution, and build on top.

## Our shell

ios_system ships only a minimal line executor — a real shell is our main *new* build here.

**Plan: port `mksh` (MirBSD Korn Shell — BSD-ish/MirOS license, permissive) or `dash`
(BSD-3) to the in-process model.** The port's core job: replace `fork/exec/wait` calls with
ios_system's `ios_system()`/thread model. a-Shell proved this pattern works (it embeds
dash for `sh -c`). Deliverables:

- Interactive line editing: use **linenoise (BSD-2)** or SwiftTerm-side editing; history
  file `~/.termx_history`; reverse-i-search (Ctrl-R).
- Tab completion: commands (from registry), files (from cwd), flags (static tables for top
  50 commands).
- Full POSIX-ish features via mksh: pipes `|`, redirects `> >> < 2>&1`, globbing, `$VAR`,
  `$(cmd)`, quoting, `&&`/`||`/`;`, functions, loops, aliases, `.profile` at startup.
- Job model: each pipeline stage = one thread-"process"; pipes = real `pipe()` fds
  (works fine on iOS). Ctrl-C → per-command cancellation hooks (ios_system supports
  `ios_kill()`); background `&` supported with a jobs table.

## Filling out "1000s of commands" — three tiers

1. **Native tier (fast path):** everything ios_system + lg2 + vim gives us, plus new ports
   we compile ourselves from **BSD/Apple's open-source coreutils** (file, stat, xargs, tee,
   cut, tr, uniq, paste, printf, seq, yes, base64, shasum, openssl(libressl), jq(MIT),
   ripgrep(MIT!), fd(MIT), tree, less-clone, htop-style `top` reading our own process
   table…). **ripgrep matters: Claude Code uses `rg` heavily — compile it as a static
   Rust lib for iOS, call its main() in-process.** Rust cross-compiles to iOS cleanly.
2. **WASM tier (extensible):** embed **wasm3 (MIT)** or **WasmKit (Apache-2)** with a WASI
   layer, a-Shell-style. Any CLI compiled to wasm32-wasi runs instantly, and users can add
   their own — this is how the command set becomes "unlimited" without app updates
   (interpreted code = allowed per App Store 2.5.2, a-Shell precedent).
3. **Linux tier:** anything else → transparently run the Alpine x86-64 binary under the
   Blink engine (C6). The shell's dispatcher checks: native registry → wasm bin dir →
   `$LINUX_PATH`. To the user it's all just `PATH`.

## Process model details (the heart of the engine)

```
ShellCore
 ├─ CommandRegistry     name → {kind: native|wasm|linux|script, entry}
 ├─ VirtualProcess      pid, tid, cwd, environ, fds[3], exit code, signal hooks
 ├─ Spawner             creates VirtualProcess, wires pipes/pty, runs entry on thread
 ├─ JobTable            fg/bg jobs, Ctrl-C/Z routing, `jobs`/`kill` builtins
 └─ TTY layer           slave fd from C1's pty; isatty()=true so tools colorize
```

- Per-"process" `cwd`: ios_system already virtualizes `chdir` with thread-local cwd.
- `environ`: copy-on-spawn dictionary; `export` mutates the shell's copy.
- Exit codes propagate to `$?`.
- **This VirtualProcess table is also the backend for C5's Node `child_process` shim** —
  design its API (spawn/wait/kill/pipe) as a clean C interface from day one.

## Deliverable

Swift/C package `TermXCore`:
- `ShellCore` (mksh port + dispatcher) with C API: `termx_run(cmdline, fds, cwd, env, cb)`
- Forked `ios_system` + command frameworks as xcframeworks
- `rg`, `jq`, `fd` native ports
- wasm3/WASI runner + `~/wasm/bin` convention
- Unit tests: pipelines, redirects, globbing, 100-command smoke test run on-device/simulator
