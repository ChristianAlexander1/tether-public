# Track P3 — Node child_process shim (JavaScript)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** You have NO app repo, NO iOS/Xcode project, NO other teams' code.
2. **Do not ask** for the iOS app or other teams' code.
3. **Naming:** product is **Tether**. npm name `@tether/shim`. Env vars `TETHER_*`. Never use TermX, `@termx`, or `TERMX_*` in new code.
4. **Build only** the folder tree below. Nothing else.
5. **Prove everything** with automated tests — **`npm test`**, all green.
6. **HANDOFF.md** must paste full test output. If blocked, write BLOCKED + reason.
7. **Zip:** `tether-shim-P3.zip` — do not integrate anywhere.

---

# Your job: `@tether/shim` — Node `child_process` replacement

## One-sentence spec
On hosts that forbid real OS processes, this npm package replaces Node's `child_process`, `os`, and `tty` modules. Spawns become JSON messages on a pipe; a host app runs the command and replies.

## YOUR job ONLY
Standalone Node.js package. **No Swift. No iOS. No browser UI. No Linux emulator.**

## Deliver
```
tether-shim/
├── package.json          # name "@tether/shim"
├── index.js              # --require entry: patch Module._load
├── lib/
│   ├── child_process.js
│   ├── os.js
│   ├── tty.js
│   └── ipc.js
├── test/
│   ├── mock-backend.js
│   └── *.test.js
├── LICENSE               # MIT
└── HANDOFF.md
```

## IPC protocol (host must match this exactly)

**Env:** `TETHER_IPC_FD` (write requests), `TETHER_IPC_REPLY_FD` (read replies).  
Fallback: `TETHER_IPC_SOCK` unix socket path.

**Spawn request** (one JSON line + `\n`):
```json
{"kind":"spawn","file":"git","args":["status"],"cwd":"/work","env":{"KEY":"val"},"interactive":false}
```

**Reply:**
```json
{"ok":true,"exitCode":0,"stdout":"...\n","stderr":"","pid":12345}
```

**Cancel request** (for Ctrl+C / SIGINT on running job):
```json
{"kind":"cancel"}
```
**Cancel reply:** `{"ok":true,"exitCode":130,"stdout":"","stderr":"","pid":...}`

## child_process — implement completely
`spawn`, `spawnSync`, `exec`, `execSync`, `execFile`, `execFileSync`, `fork` (document IPC limits)

Options: `cwd`, `env`, `shell`, `stdio`, `encoding`, `maxBuffer`, `timeout`, `killSignal`, `argv0`  
Errors: `ENOENT` with Node-accurate `code`, `errno`, `syscall`, `path`  
Events: `spawn` → `exit` → `close` (async order like Node)

## os / tty
- `os.platform()` → `'darwin'`
- `os.homedir()`, `os.tmpdir()` — sensible defaults
- `tty.isatty(fd)` → `true` when env `TETHER_INTERACTIVE=1`

## Browser / OAuth spawns (generic URL opener class)

Any program that spawns a **URL opener** with `https://…` must work — not only one vendor.

| Opener basename | When |
|---------------|------|
| `open`, `xdg-open`, … | From manifest `browser_openers` list |

Pass **parent `env`** through unchanged (`DISPLAY`, `BROWSER`, `WAYLAND_DISPLAY`).

Tests must use **at least two different https hosts** (e.g. `example.com` and one OAuth-style URL) — same code path.

## Tests — minimum **50** (`npm test`)

| # | Test |
|---|------|
| 1–5 | spawn exit 0/1, spawnSync, exec callback, execSync throw |
| 6 | ENOENT |
| 7 | shell: true → `sh -c` |
| 8 | maxBuffer exceeded |
| 9 | **cancel → exit 130** |
| 10 | ipc unix socket round-trip |
| 11 | **spawn open + https URL** |
| 12 | **spawn xdg-open + DISPLAY=:0** |
| 13 | env DISPLAY/BROWSER preserved in JSON |
| 14 | git status spawn |
| 15 | rg spawn |
| 16 | bash -c pipeline via shell:true |
| 17 | tty.isatty interactive |
| 18 | os.platform darwin |

## HANDOFF.md
- Paste full `npm test` output
- Document protocol + browser spawn table
- List any Node API not implemented

## Open source reference (behavior only, MIT)
Node.js `lib/child_process.js`, `lib/os.js`, `lib/tty.js`

## License: MIT
