# C6 — Linux Engine

**Goal:** A real Alpine Linux userspace on iOS — the **guest platform** for almost all
software. See **`GUEST-PLATFORM.md`** for the full contract (exec dispatch, env, openers,
signals — no per-tool hardcoding).

## Role in Tether

The default terminal session **is** Alpine at `/work`. Users run `apk add` and get the
same binaries as on desktop Linux (x86_64 under Blink). The app does **not** implement
special cases for git, python, gcc, etc.

Only two **generic** host bridges exist (manifest-driven):

1. **URL opener class** — `xdg-open` / `open` → host opens any URL  
2. **Host runtime manifest** — app-shipped stubs (node/npm/claude) that are not guest ELFs  

**Default for all other exec:** guest ELF.

## Architecture map (ios-linuxkit-style, permissive stack)

| Layer | Tether |
|-------|--------|
| Emulator | Blink (x86-64); libriscv / ARM64 research |
| Syscalls / signals | Blink + bridge patches (`termx_blink_bridge.c`) |
| Rootfs | Alpine minirootfs; optional fakefs (P4) |
| Bind mounts | `/work`, `/workspaces/<name>` |
| Exec dispatch | **`tether_dispatch_manifest.json`** (replace hardcoded lists) |
| Tests | P7 harness + TermXLinux acceptance |

Reference: [ios-linuxkit](https://github.com/rcarmo/ios-linuxkit) structure — **no GPL code**.

## Engine strategy

1. **Blink x86-64** — shipping; interpreter mode on iOS  
2. **libriscv riscv64** — optional bake-off  
3. **ARM64 guest** — research  

Syscall work is driven by **harness failures**, not by guessing which app we want next.

## Filesystem

- Rootfs at `$HOME/linux/`  
- Bind mounts for workspace(s)  
- Guest writes at `/work` round-trip to host bookmark paths  
- Networking: guest sockets → host (Blink)  

## Deliverable

- `TermXLinux`: Blink xcframework, bootstrapper, mounts, **manifest dispatch**  
- Tests: BusyBox, apk stress, pipelines, fork/signal, **apk install chains**  
- `docs/LIMITATIONS.md` — syscall gaps with harness IDs  

## UX

- Login shell at `/work`  
- `linux <cmd>` for one-shots without replacing session  
- First-run rootfs download (~3 MB)  
