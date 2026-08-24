# C5 — Claude Code, Running Locally

**Goal:** Run Claude Code against the user's project folder. Claude is **one consumer** of
the Tether **guest platform** — not a special case wired with hardcoded git/python/browser
hacks.

**Read first:** `GUEST-PLATFORM.md` (exec dispatch, Linux env, URL openers, spawn path).

## How Claude fits the platform

Claude Code expects a normal Linux-ish + Node environment. Tether provides:

| Expectation | Platform service (generic) |
|-------------|----------------------------|
| Node 18+ | Host runtime manifest → node-mobile |
| TTY / Ink TUI | pty + SwiftTerm (+ terminal protocol fixes) |
| `child_process.spawn(…)` | `@tether/shim` → **SpawnExecuting** (PATH, any command) |
| `xdg-open` / `open` for login | **URL opener class** → `SystemOpen` (any https URL) |
| `DISPLAY` set before open | Guest/host login env (not Claude-only) |
| Project files | `/work` bind mount |
| `~/.claude` | Sandbox `$HOME/.claude` |
| Tools: git, rg, bash | **Guest apk** or spawn via PATH — **no** Claude-specific git hook |

If Claude spawns `git status`, the platform resolves `git` like any shell would — guest
ELF if installed via `apk`, or native tier when ios_system lands — **not** a hardcoded
“Claude needs git” block.

## Routes

### Route 1 — Claude Code on embedded Node (primary)

Extracted JS + nodejs-mobile + `@tether/shim`. Platform must stay **generic** so Claude
updates keep working (full `child_process`, not Claude-named APIs).

### Route 2 — Linux Bun binary under Blink

Optional; validates guest quality. Most tools should use apk guest ELFs, not host stubs.

### Route 3 — TermX Agent (native Swift UI)

Separate product surface; same workspace + spawn contracts.

## Engineering priorities (Mac)

1. Manifest dispatch (no `path_is_host_backed` strcmp list)  
2. Linux login env: `DISPLAY=:0`, `WAYLAND_DISPLAY=tether`, `BROWSER=open`  
3. URL opener primary path (spawn → Safari); PTY URL scrape as backup only  
4. SpawnExecuting guest one-shot for ELFs in guest PATH  
5. Terminal TUI protocol (DEC modes, width)  

## Test matrix (platform-level)

- `apk add git ripgrep` → Claude can use them without new app code  
- `xdg-open https://example.com` works before/after apk chain  
- `claude login` via opener spawn, not fallback-only  
- Double ^C → no crash; guest ^C stops `sleep`  
- Step 8b in `agent-briefs/MERGE-AND-VERIFY.md`  

## Deliverable

- Launcher + user npm install flow  
- Platform wiring per `GUEST-PLATFORM.md`  
- Demo: edit files, commit with guest git, search with guest rg  
