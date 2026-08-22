# Tether — project context

**Read this first in any new session.** It carries the decisions, gotchas and current state
that would otherwise be lost when a conversation ends.

## What this is

Tether is a native iOS/iPadOS terminal. You pick a folder, get a real pty shell inside it,
and run Unix commands, Python, Node, and a Linux guest — with the long-term goal of running
Claude Code locally against your project. It is built to be published on the App Store, so
**no GPL code is bundled**.

- App name / bundle id: **Tether** / `com.tether.app` (renamed from TermX on 2026-08-22).
- Internal Swift modules are still named `TermX*` (TermXCore, TermXUI, …). That is
  deliberate: renaming ~1,100 files is a large mechanical sweep with real breakage risk and
  no user-visible benefit. Do it as its own task if ever wanted.

## Architecture in one paragraph

iOS forbids `fork`/`exec`, so **every command runs in-process** inside the app. `TermXCore`
is the shell + command engine (each command is a function called on a thread with its own
fds); `TermXUI` is SwiftTerm plus the pty; `TermXFiles` handles the security-scoped folder
bookmarks. Python is embedded CPython 3.14 (BeeWare), Node is nodejs-mobile, and the Linux
lane is the Blink x86-64 interpreter over an Alpine rootfs. Anything not found natively
falls through to the Linux guest.

## Hard-won rules (breaking these has broken the app before)

1. **No `Process`, `fork`, `exec`, `system`, or `tar` binary** — none exist on iOS. Host-only
   code goes behind `#if os(macOS)`.
2. **Everything shares one process.** A stray signal or `exit()` kills the whole app.
   `SignalPolicy.installOnce()` ignores SIGPIPE — never remove it.
3. **Never block the main thread**, and never close a pty/pipe fd while another thread is
   blocked reading it. Drain first (see `TerminalSession.shutdownPTY`).
4. **A terminal never sends EOF.** Never read stdin to EOF unless `isatty()` is false —
   this froze the shell twice.
5. **`DispatchWorkItem.cancel()` cannot interrupt a blocked `read()`.** Use a poll loop with
   a stop flag (see `NodeMobileRuntime.StdinPump`).
6. **Each `ShellSession` owns its own `CommandRegistry`.** Registering a command or fallback
   on the engine's registry does *not* affect interactive sessions — wire it in
   `sessionConfigurator` too.
7. **Guard index arithmetic.** `0..<(count - 2)` crashed the app on any one-word command.
8. Do not change the frozen APIs in `09-integration-contracts.md`.

## Bugs already found and fixed — do not reintroduce

Documented in `../STATUS-AND-REWORK.md`. In short: SIGWINCH treated as an interrupt (any
resize killed the shell); unhandled SIGPIPE; pty close hanging the main thread; filters
ignoring piped stdin; `ScriptParser` underflow on short lines; Node's stdin pump swallowing
all input after a job; the external-command adapter slurping a tty to EOF; `printf` never
writing its output; backslashes stripped inside double quotes; script variables invisible
to later expansions.

## Current state (2026-08-22)

Working and verified on the Simulator: the shell (pipes, redirects, globs, conditionals,
loops, functions, here-docs, job control), `python3`/`pip`, `node`/`npm`, the Linux lane
(`apk add git` → `git version 2.45.4`, runnable by bare name), the folder picker, and the
Licenses screen. 220 tests green across nine packages.

Not done: writing into the picked workspace from guest programs; `linux /bin/sh -c` is
unreliable; `claude` login end-to-end; the physical-device checklist.

## Where to look

| Question | File |
|---|---|
| How do I run and test it? | `../HOW-TO-RUN.md` |
| What can users type, and how do they install/remove things? | `USER-GUIDE.md` |
| What is verified working, and what bugs were fixed? | `../STATUS-AND-REWORK.md` |
| What work is left, for a Mac agent? | `10-remaining-work.md` |
| What work can an agent without the repo do? | `11-offline-agent-work.md` |
| The frozen APIs between components | `09-integration-contracts.md` |
| Licensing rules for new dependencies | `07-appstore-licensing.md` |
| Physical-device checklist | `DEVICE-PASS.md` |

## Repo conventions

- Build with `xcodegen generate` then `xcodebuild -project Tether.xcodeproj -scheme Tether …`.
  `Tether.xcodeproj` is generated — edit `project.yml`, not the project file.
- The three xcframeworks (~708 MB) are **not** committed; rebuild them with the scripts in
  `Frameworks/README.md`.
- Every change should keep all test suites green; see `../HOW-TO-RUN.md` for the commands.

## Claude Code sessions (why they live where they do)

Claude Code binds a session to the directory it was started in, and stores that project's
transcripts and memory under `~/.claude/projects/<path-with-dashes>/`. When the repo moved
from `~/Projects/terminal` to `~/Projects/tether`, the session data was copied across:

```
~/.claude/projects/-Users-dev-Projects-terminal/   # old
~/.claude/projects/-Users-dev-Projects-tether/     # new (copy of the above)
```

So a session started in the new folder sees the same memory and can `--resume` the old
conversations. If you ever move the repo again, copy the matching project folder the same
way, and re-sync after quitting Claude so the final part of the transcript is included:

```bash
rsync -a ~/.claude/projects/-Users-dev-Projects-OLD/ \
         ~/.claude/projects/-Users-dev-Projects-NEW/
```

The old empty `~/Projects/terminal` folder can be deleted once no session is running in it.
