# Guest platform — how Linux apps run on Tether (real behavior, not per-app hacks)

**Audience:** integrators and Mac agents working in this repo.  
**Not** for offline sub-agents (see `agent-briefs/` for isolated component work).

This document is the **platform contract**: what any program installed via `apk add`, or
any CLI that expects a normal Linux userspace, is entitled to receive. We do **not** add
Swift/C code per tool (not “fix git”, then “fix python”, then “fix Claude”).

---

## 1. Design rule

> **`apk add <package>` → every binary from that package runs as a guest ELF under Blink.
> No exceptions unless it is explicitly listed in the host manifest.**

If `git`, `python3`, `gcc`, `vim`, or a package you install tomorrow fails, the fix is
**guest environment, syscalls, or filesystem** — never “add this tool name to a host list”.

---

## 2. What Linux programs expect (platform services)

These are the same things [ios-linuxkit](https://github.com/rcarmo/ios-linuxkit) / iSH /
desktop Alpine provide. Tether must supply them **generically**:

| Service | What apps use it for | Tether implementation |
|---------|----------------------|------------------------|
| **ELF exec + dynamic linker** | Run `/usr/bin/*` from apk | Blink loader + Alpine rootfs |
| **FHS layout** | `/bin`, `/usr/bin`, `/lib`, `/etc` | Bootstrapped minirootfs + `apk add` |
| **PATH / HOME / TERM** | Find commands, config, colors | Guest login env in login shell |
| **DISPLAY / WAYLAND_DISPLAY** | Gate URL open before `xdg-open` | Set on guest login (`DISPLAY=:0`, `WAYLAND_DISPLAY=tether`) |
| **BROWSER** | Override opener command | Optional; default `open` stub → host |
| **PTY + signals** | Shell, Ctrl+C, interactive CLIs | Blink + pty fd; SIGINT in guest (not app hacks) |
| **Sockets** | curl, git, npm registry, ssh | Guest socket → host BSD socket (Blink) |
| **Bind mounts** | Project files at `/work` | `termx_blink_mount(host, "/work")` (+ `/workspaces/*`) |
| **URL openers** | OAuth, docs, `xdg-open http://…` | **Opener class** → `SystemOpen` (any https URL) |
| **fork / exec / wait** | Pipelines, shell scripts | Inside Blink (single iOS process) |
| **/proc (subset)** | Some tools read `/proc/self/*` | Blink VFS; extend as harness finds gaps |
| **apk** | Install more software | Real Alpine `apk` against CDN |

Reference behavior (do not copy GPL code): ios-linuxkit `kernel/`, `fs/`, `native_offload.c` —
study **structure**, implement with Blink + manifest dispatch.

---

## 3. Exec dispatch (manifest — not hardcoded strcmp)

Every guest `execve()` goes through one resolver:

```
exec(prog):
  if prog matches browser_opener basenames → host URL opener (any https/file URL)
  else if prog matches host_runtime manifest → host handler (see §4)
  else → guest ELF under Blink (DEFAULT)
```

### Manifest file (`tether_dispatch_manifest.json` in app bundle)

```json
{
  "default": "guest_elf",
  "browser_openers": [
    "open", "xdg-open", "gnome-open", "kde-open",
    "sensible-browser", "wslview"
  ],
  "host_runtimes": [
    { "match": "basename", "name": "node", "handler": "node-mobile" },
    { "match": "basename", "name": "npm",  "handler": "node-mobile" },
    { "match": "basename", "name": "npx",  "handler": "node-mobile" },
    { "match": "basename", "name": "claude", "handler": "node-mobile" }
  ]
}
```

**Rules:**

- **`browser_openers`** — Freedesktop-style openers ([xdg-utils](https://www.freedesktop.org/wiki/Software/xdg-utils/) behavior). One implementation opens **any** URL for **any** app (Claude OAuth, Python `webbrowser`, `xdg-open https://example.com`).
- **`host_runtimes`** — Only **stubs shipped by the app** that are not guest ELFs (embedded Node launchers). **Never** list `git`, `python3`, `gcc`, `rg`, etc.
- **`default: guest_elf`** — Everything from `apk add` stays here.

### Wired in-repo (Mac)

Manifest dispatch lives in `Packages/TermXLinux/Resources/tether_dispatch_manifest.json`,
`GuestDispatchManifest.swift`, and `termx_blink_dispatch_*` in `termx_blink_bridge.c`.
P5 agent zip is optional (extra C tests); do not re-run P5 agents to match docs.

---

## 4. Host runtime layer (Node / JS CLIs)

Some programs are **not** Alpine packages — they are JavaScript run on embedded Node
(Claude Code, npm scripts). They need a **POSIX-like host** via `@tether/shim`:

| Linux desktop | Tether |
|---------------|--------|
| `child_process.spawn("git", ["status"])` | Shim → **SpawnExecuting** → resolves PATH |
| `spawn("xdg-open", [url])` | Shim → **SystemOpen.resolve** → Safari |
| `process.platform` / `tty.isatty` | Shim overrides for embedded host |

**SpawnExecuting** (`RegistrySpawnExecutor`) must resolve commands **generically**:

1. Registered native commands (future ios_system tier)
2. WASM binaries in `~/wasm/bin`
3. **Guest one-shot** — run `argv` inside Blink without replacing login shell (when not in manifest host_runtime)

No Claude-specific branches in spawn path except what **any** Linux Node app would need
(`which open`, opener in PATH, https in args — already in `NodeSpawnBridge` + `SystemOpen`).

### Linux environment for JS CLIs

Before loading Claude (or any Node CLI), set the same env a minimal Linux desktop would:

```
DISPLAY=:0
WAYLAND_DISPLAY=tether
BROWSER=open
TERM=xterm-256color
```

So any tool that checks `DISPLAY` before spawning `xdg-open` works — not only one vendor.

---

## 5. URL opening (platform service, not OAuth hack)

`SystemOpen` (`TermXFiles`) is already **generic**:

- `openerCommands` set matches common desktop openers
- `resolve(command:arguments:)` handles `open`, `xdg-open`, `gio open`, `sh -c '…'`
- Opens **any** `https://` URL via in-app Safari (OAuth is one URL shape)
- Guest `127.0.0.1` is **not** Mac localhost — guest fetch or info sheet (documented in integration)

**Primary path:** guest or shim spawns opener → host opens URL.  
**Backup:** PTY scrapes OAuth URL if spawn path failed (dedupe by `state=`). Backup must
not be the only path.

---

## 6. Signals & Ctrl+C

| Context | Correct handler |
|---------|-----------------|
| Alpine shell, `sleep 30`, user ^C | **Guest** SIGINT (Blink) |
| Node interactive job, ^C | PTY `0x03` + shim `cancel` → exit 130 |
| Must **not** call `linux.interrupt()` for Node ^C | Tears down entire guest session → crashes |

Validate with Linux harness (P7) + Simulator Step 8b in `agent-briefs/MERGE-AND-VERIFY.md`.

---

## 7. Installing more packages must not break the app

**Root cause of past crashes:** starting a **second** Blink session (`blink_run`) while the
login shell holds the machine, or UI work during `termx_blink_is_busy()`.

**Rules:**

- One login shell owns Blink until exit
- `apk add` and all guest commands run **inside** that session
- UI must not start parallel guest runs or fetch guest localhost while busy
- Installing package A then B is normal Alpine — no app code changes

**Acceptance:** Step 8b chain in merge doc (`apk update` → git → python3 → ripgrep →
build-base → `xdg-open https://example.com` → node/claude stubs) in **one session**, app alive.

---

## 8. When something fails — diagnostic tree

| Symptom | Layer to fix | Do **not** |
|---------|--------------|------------|
| `apk add foo` fails | apk/network/rootfs | Hardcode foo |
| `foo` not found in guest shell | PATH/rootfs/`apk add` | Host proxy foo |
| Guest `git commit` fails | Syscall/Blink/git as ELF | Add git to host list |
| JS app: spawn git fails | SpawnExecuting → guest one-shot or PATH | Claude-only hack |
| Browser doesn't open | DISPLAY env + opener class + SystemOpen | Claude-only URL handler |
| Crash after second `apk add` | Blink single-session rules | Disable apk |
| Crash on ^C in Claude | Node cancel path | `linux.interrupt()` |

---

## 9. Implementation roadmap (this repo)

| Priority | Work | Owner |
|----------|------|-------|
| P0 | ~~Manifest dispatch replaces `path_is_host_backed`~~ | **Done in-repo** |
| P0 | Guest login env (DISPLAY, TERM, …) | Mac / TermXLinux |
| P0 | SpawnExecuting → guest one-shot for unknown ELFs in PATH | Mac / TermXNode |
| P1 | Syscall gaps from P7 harness | Mac / TermXLinux |
| P1 | `/workspaces/*` bind for all bookmarks | Mac / I2 |
| P2 | ios_system native tier (optional fast PATH) | I1 |
| P2 | fakefs rootfs (P4) | Mac |

---

## 10. Related docs

| Doc | Topic |
|-----|--------|
| `06-linux-emulation.md` | Blink, rootfs, mounts |
| `05-claude-code-integration.md` | Claude as consumer of this platform |
| `09-integration-contracts.md` | Frozen spawn APIs |
| `agent-briefs/MERGE-AND-VERIFY.md` | Post-merge smoke + 8b chain |
| `07-appstore-licensing.md` | Permissive deps only |

---

## 11. Open-source references (behavior only)

| Project | Use |
|---------|-----|
| [ios-linuxkit](https://github.com/rcarmo/ios-linuxkit) | Layout: kernel, fs, native_offload **pattern** |
| [jart/blink](https://github.com/jart/blink) ISC | x86-64 Linux userland emulator |
| [Freedesktop xdg-utils](https://www.freedesktop.org/wiki/Software/xdg-utils/) | URL opener semantics |
| iSH (App Store) | apk-on-device precedent |

Do **not** copy GPL emulator source into Tether.
