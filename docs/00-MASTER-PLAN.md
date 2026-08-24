# Master Plan — Tether: A Real Terminal for iPhone & iPad

> **The goal:** A native iOS/iPadOS app that gives you a real terminal — thousands of
> Unix/Linux commands, Python, Node, **Claude Code locally**, and a full Alpine Linux
> userspace — scoped to folders you pick, App Store shippable, built from permissively-
> licensed parts.

This is achievable. a-Shell, iSH, Code App, and Pyto prove the pieces. **Tether ships all
of them together** with Claude Code as the headline.

---

## 1. The one key insight

iOS forbids `fork()`/`exec()` — an app cannot spawn separate OS processes. Every terminal
app solves this with **in-process virtualization**:

| Lane | How | Speed | Reference apps | License |
|---|---|---|---|---|
| **A. Native in-process** | Each command's `main()` on a thread with isolated fds/cwd | Full ARM64 | a-Shell / ios_system | BSD-3 |
| **B. WASM** | wasm32-wasi bytecode interpreter | Fast | a-Shell | MIT |
| **C. CPU emulation** | Usermode Linux kernel + emulator + Alpine rootfs | Emulated | iSH / ios-linuxkit | GPL code — **we use Blink/libriscv instead** |

**Tether uses all three lanes as peers:**

- **Lane A:** ios_system-style native commands + CPython + nodejs-mobile + libgit2, ripgrep,
  curl, vim ports. Shell, git, rg, and fast tooling live here.
- **Lane B:** wasm3/WasmKit + WASI — unlimited user-extensible commands (App Store safe).
- **Lane C:** Blink (+ libriscv bake-off) + Alpine — `apk add` anything, real Linux ELF
  binaries, gcc, exotic tools. **Primary interactive session today; growing toward ios-linuxkit
  depth** (fakefs, bind mounts, manifest dispatch, syscall completeness).

**Guest platform contract:** [`GUEST-PLATFORM.md`](GUEST-PLATFORM.md) — default exec is guest
ELF; only URL openers + manifest host runtimes cross to the host.

## 2. Component map

```
┌─────────────────────────────────────────────────────────────┐
│                       Tether iOS App                        │
│  ┌───────────────┐   ┌──────────────────────────────────┐   │
│  │ C1 Terminal UI │──▶│ C2 Shell & Command Engine        │   │
│  │ (SwiftTerm)    │   │ (ios_system + dispatcher + PTY)  │   │
│  └───────────────┘   └───────┬──────────┬────────┬──────┘   │
│                              │          │        │          │
│                   ┌──────────▼──┐ ┌─────▼─────┐ ┌▼────────┐ │
│                   │ C4 Runtimes │ │ C5 Claude │ │ C6 Linux │ │
│                   │ Python+Node │ │ Code      │ │ Engine   │ │
│                   └─────────────┘ └───────────┘ │ Blink+…  │ │
│                                                 └─────────┘ │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ C3 Filesystem & Folder Access (bookmarks, sandbox)   │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
        C7 App Store & Licensing        C8 Roadmap & Work Split
```

| # | Component | Doc | Core reused tech (license) |
|---|---|---|---|
| C1 | Terminal UI | `01-terminal-ui.md` | SwiftTerm (MIT); evaluate Ghostty Web (MIT) |
| C2 | Shell & command engine | `02-shell-core.md` | ios_system (BSD-3), wasm3 (MIT) |
| C3 | Filesystem & folder access | `03-filesystem-folders.md` | Apple security-scoped bookmarks |
| C4 | Python & Node runtimes | `04-runtimes-python-node.md` | CPython (PSF), nodejs-mobile (MIT) |
| C5 | Claude Code integration | `05-claude-code-integration.md` | User-installed npm pkg |
| C6 | Linux engine | `06-linux-emulation.md` | Blink (ISC), libriscv (BSD-3), Alpine |
| C7 | App Store & licensing | `07-appstore-licensing.md` | — |
| C8 | Roadmap & agent work split | `08-roadmap.md` | — |
| C9 | Integration contracts | `09-integration-contracts.md` | — |
| — | **Guest platform contract** | **`GUEST-PLATFORM.md`** | Default guest ELF; manifest dispatch |
| **C10** | **Parallel agent plan** | **`13-parallel-agent-plan.md`** | Offline/online agent briefs |

> **Handoff rule:** component agents receive their doc + `09-integration-contracts.md` +
> `07-appstore-licensing.md`. Offline agents use `13-parallel-agent-plan.md` (self-contained).

## 3. Licensing (legal guardrails — not a feature cap)

- **Green (bundle freely):** MIT, BSD, ISC, Apache-2, PSF, MirOS, SIL-OFL.
- **Red (never compile into app binary):** GPL/AGPL source. Use BSD/MIT equivalents or
  interpreted/emulated guest packages (Alpine apk at user request — iSH precedent).
- **Anthropic Claude Code:** user-installed via npm under their terms; we ship a launcher.

Full table: `07-appstore-licensing.md`.

## 4. User experience (complete product)

1. Pick a folder → security-scoped bookmark → permanent access.
2. Terminal opens in that folder — full pty, colors, vim, TUIs, Claude Code TUI.
3. Native speed: `ls`, `grep`, `git`, `rg`, `python`, `pip`, `node`, `npm`, `claude`.
4. Linux session: Alpine shell at `/work`; `apk add` anything; guest and native tools share
   the same workspace via bind mounts.
5. WASM: drop binaries in `~/wasm/bin` — instant new commands.
6. OAuth login, in-app browser, guest localhost info — all wired.

## 5. Build order

See `08-roadmap.md` and **`13-parallel-agent-plan.md`** for the full parallel work split.

Integration milestones (all required for ship):

- **M1** Walking skeleton: pty + folder picker + core shell
- **M2** Full shell + native command tier (ios_system + rg/jq/fd/git)
- **M3** Python + Node runtimes + `@tether/shim` (generic spawn)
- **M4** Claude Code end-to-end (login, TUI, edit, commit, interrupt)
- **M5** Linux engine at ios-linuxkit parity (fakefs, mounts, offload, tests)
- **M6** WASM tier + terminal polish (DEC modes, width, Ghostty eval)
- **M7** Device hardening + App Store submission

## 6. Ground rules for all agents

- Swift + SwiftUI shell; C/C++/Rust where libraries require it.
- Never bundle GPL **source compiled into the app binary**. Guest apk packages are fine.
- Every command on a background thread; never block main; never close fds while blocked reads run.
- All scratch in sandbox; user data only in picked folders.
- iOS 16+, iPhone and iPad; Mac Catalyst when ready.
