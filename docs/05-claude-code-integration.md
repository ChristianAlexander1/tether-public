# C5 — Claude Code, Running Locally

**Goal:** The user types `claude` in a workspace and gets real Claude Code — agentic
coding on the files in that folder, running on-device (the AI model is in Anthropic's
cloud as always; the *agent* runs locally in our app).

This is the flagship feature no shipped iOS terminal has. We have three routes; we build
Route 1 as primary and Route 3 as the guaranteed fallback, sharing all plumbing.

## Route 1 (primary): official `claude` CLI on embedded Node

Claude Code is an npm package (`@anthropic-ai/claude-code`) — JavaScript running on
Node ≥18. With C4's nodejs-mobile engine it can run in-process. What it needs from the
"OS", and how we supply each:

| Claude Code expects | Our answer |
|---|---|
| Node 18+ runtime | nodejs-mobile (V8 jitless) |
| A TTY for its rich TUI (Ink-based) | C1/C2 pty; `isatty=true`; SwiftTerm renders it |
| `child_process` → `bash`, `git`, `rg`, etc. | C4's shim → C2 VirtualProcess: `sh` = our mksh, `rg` = native ripgrep port, `git` = lg2 |
| Filesystem on the project | Workspace path from C3 — plain POSIX, just works |
| HTTPS to api.anthropic.com / OAuth login | Plain networking; OAuth: shim opens `ASWebAuthenticationSession`, callback → localhost listener works in-app, or paste-token flow |
| `~/.claude` config/state dir | `$HOME/.claude` in our sandbox |
| Keychain/credential store | Falls back to file storage on "unknown OS"; or shim `--credential-helper` to iOS Keychain (nicer) |

Engineering plan:
1. `npm i -g @anthropic-ai/claude-code` inside the app (interpreted JS = fine per 2.5.2,
   and it means we never redistribute Anthropic's package — users fetch it under their
   own agreement with Anthropic. Legally clean and auto-updating.)
2. Launch via Node service with `--require @termx/shim` preloaded.
3. Iterate on the shim until Claude Code's real call patterns all pass: expect to stub
   `os.platform()` (report `darwin`), `process.kill`, signal handling for Esc-interrupt,
   `execSync` for git status lines, spawned `bash -c` pipelines (our mksh handles POSIX
   sh; Claude Code's commands are POSIX-clean).
4. Perf target: TUI at 60fps (SwiftTerm is fine), tool-calls dominated by network anyway.
5. Test matrix: login, `/init`, file edits, `git commit`, `rg` search, long agentic run,
   Esc interrupt, resume, MCP servers (stdio MCP = another VirtualProcess — works;
   skip for v1 if hairy).

Risk & mitigation: Claude Code is minified and updates often — the shim must cover Node
APIs *generically* (whole `child_process`, `os`, `tty` surface), not Claude-specific
hacks. Then updates keep working.

## Route 2 (fallback A): `claude` under the Linux engine

Anthropic ships Claude Code as a **static Linux binary** (bun-based) too. C6's Blink
emulator runs x86-64 static Linux binaries. This route is zero-shim — real Linux
environment, real bash, real everything — at emulated speed. Perfectly usable for an
I/O-bound agent (network dominates), just less snappy TUI. If Route 1 hits a wall on
some release, users still have `linux claude`.

## Route 3 (fallback B / differentiator): native agent UI — "TermX Agent"

Build our own Swift agent client speaking the **Claude Agent SDK / Messages API**
directly: the agent loop (tool use: read/write/edit/bash/grep) implemented natively —
bash tool = C2 engine, file tools = C3 workspace, streaming into either the terminal or
a gorgeous native SwiftUI chat+diff panel. Users log in with their Anthropic API key or
OAuth. This is not "Claude Code" the product, but it is Claude coding in your pocket
with buttery native UX — and it doubles as our premium differentiator later (side-by-side
terminal + agent panel on iPad).

## Order of work

1. Shim spec + npm-under-shim e2e (shared with C4) — this unlocks everything.
2. Route 1 bring-up behind a `claude` launcher command (checks install, installs on
   first run with a friendly progress UI).
3. Route 3 skeleton (API-key mode) as a parallel agent task — low risk, high demo value.
4. Route 2 once C6 lands.

## Deliverable

- `@termx/shim` hardened against Claude Code's call patterns (test suite of recorded
  syscall/spawn traces)
- `claude` launcher + first-run installer UX + login flow
- `TermXAgent` Swift package (Route 3) with tool implementations bridged to C2/C3
- A demo video script: open folder → `claude` → "add dark mode to this site" → watch it
  edit files and commit. That's the App Store screenshot moment.
