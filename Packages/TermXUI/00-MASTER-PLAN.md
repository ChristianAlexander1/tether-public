# Master Plan — "TermX": A Real Terminal for iPhone & iPad

> **The goal:** A native iOS/iPadOS app that gives you a real terminal — run thousands of
> Unix/Linux commands, install and use Python and Node, and run **Claude Code locally** —
> all scoped to a folder the user picks, working like a real terminal in that space.
> Publishable on the App Store under our own name, built from permissively-licensed parts.

This is 100% achievable. It has been proven piece by piece by shipped App Store apps
(a-Shell, iSH, Code App, LibTerm). What has *not* been shipped yet is all of it in one app
with Claude Code running locally — that's our edge and our product.

---

## 1. The one key insight

iOS forbids `fork()`/`exec()` — an app cannot spawn separate processes. Every terminal app
on iOS solves this one problem in one of two ways:

| Approach | How | Speed | Example | License of example |
|---|---|---|---|---|
| **A. Native in-process commands** | Compile each Unix command as a library; "spawning" a command = calling its `main()` on a thread inside the app | Native ARM64 speed (fast) | a-Shell / ios_system | **BSD 3-Clause (we can use it!)** |
| **B. CPU emulation** | Emulate an x86 Linux userspace inside the app; run a real Alpine Linux rootfs | 10–50x slower | iSH | GPL (we avoid the code, copy the idea) |

**Our architecture uses BOTH, with A as the primary lane:**

- **Lane A (primary, fast):** ios_system-style native commands + native CPython + embedded
  Node.js (nodejs-mobile) + a WASM runtime for extra tools. This is where the shell, the
  1000s of commands, Python, Node, and Claude Code live. Everything runs at full device speed.
- **Lane B (compatibility, optional):** an embedded x86-64 usermode emulator based on
  **Blink** (ISC license — permissive!) with an Alpine rootfs, for the rare tool that only
  exists as a Linux binary (`apk add anything`). This is iSH's capability without iSH's GPL.

## 2. Component map

Each component has its own doc and can be built by a separate agent in parallel.

```
┌─────────────────────────────────────────────────────────────┐
│                       TermX iOS App                         │
│                                                             │
│  ┌───────────────┐   ┌──────────────────────────────────┐   │
│  │ C1 Terminal UI │──▶│ C2 Shell & Command Engine        │   │
│  │ (SwiftTerm)    │   │ (ios_system + dispatcher + PTY)  │   │
│  └───────────────┘   └───────┬──────────┬────────┬──────┘   │
│                              │          │        │          │
│                   ┌──────────▼──┐ ┌─────▼─────┐ ┌▼────────┐ │
│                   │ C4 Runtimes │ │ C5 Claude │ │ C6 Linux │ │
│                   │ Python+Node │ │ Code      │ │ Engine   │ │
│                   └─────────────┘ └───────────┘ │ (Blink)  │ │
│                                                 └─────────┘ │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ C3 Filesystem & Folder Access (bookmarks, sandbox)   │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
        C7 App Store & Licensing        C8 Roadmap & Work Split
```

| # | Component | Doc | Core reused tech (license) |
|---|---|---|---|
| C1 | Terminal UI | `01-terminal-ui.md` | SwiftTerm (MIT) |
| C2 | Shell & command engine | `02-shell-core.md` | ios_system (BSD-3), wasm3/WASI (MIT) |
| C3 | Filesystem & folder access | `03-filesystem-folders.md` | Apple APIs (security-scoped bookmarks) |
| C4 | Python & Node runtimes | `04-runtimes-python-node.md` | CPython official iOS support (PSF), nodejs-mobile (MIT) |
| C5 | Claude Code integration | `05-claude-code-integration.md` | Claude Code npm pkg / Claude Agent SDK / API |
| C6 | Linux engine (fallback) | `06-linux-emulation.md` | Blink emulator (ISC), Alpine rootfs (mixed, unbundled) |
| C7 | App Store & licensing | `07-appstore-licensing.md` | — |
| C8 | Roadmap & agent work split | `08-roadmap.md` | — |
| C9 | **Integration contracts & handoff rules** | `09-integration-contracts.md` | — |

> **Handoff rule:** every component agent receives THREE docs: their component doc,
> `09-integration-contracts.md` (frozen APIs, deliverable format, acceptance tests —
> mandatory), and `07-appstore-licensing.md` (dependency rules). Components come back as
> folders matching the repo layout in doc 09; the integrator verifies, wires, and runs
> the end-to-end suite before the user's final device test.

## 3. What we reuse vs. build (the license answer)

Your worry about "licensed repos" is solved by picking the right licenses. Three tiers:

- **✅ Free to use, modify, rebrand, sell, publish closed-source:** MIT, BSD, ISC, Apache-2.0,
  Python-PSF. This covers SwiftTerm, ios_system, nodejs-mobile, wasm3, Blink, CPython,
  libgit2, curl, and most of what we need. Only obligation: keep a "Licenses" screen in the
  app listing their copyright notices. Every commercial app does this.
- **⚠️ Avoid bundling:** GPL/LGPL code (iSH's emulator, bash, GNU coreutils, git-the-GNU-build).
  We use BSD/MIT equivalents instead: `dash`/`mksh`-style shell (see C2), BSD utilities,
  libgit2. Lane B downloads Alpine packages *at user request onto user's device*, which is the
  iSH-proven pattern.
- **📄 Anthropic:** Claude Code npm package is under Anthropic's commercial terms — users log
  in with their own account, same as running it anywhere. Nothing to relicense.

Full table in `07-appstore-licensing.md`.

## 4. How the user experience works

1. User opens TermX → picks a folder with the iOS folder picker (Files app, iCloud Drive,
   local, even folders from other apps' File Providers).
2. TermX stores a **security-scoped bookmark** → permanent read/write access to that folder.
3. A terminal opens with `cwd` inside that folder. Prompt, tabs, arrow keys, ctrl keys — a
   real terminal (SwiftTerm renders full xterm/VT100, so vim, htop-style TUIs, colors all work).
4. `ls`, `grep`, `sed`, `awk`, `git`, `curl`, `python`, `pip`, `node`, `npm`… run natively.
5. `claude` launches Claude Code on the embedded Node runtime, operating on that folder.
6. Optional: `linux` drops into the Alpine environment (Lane B) for anything exotic.

## 5. Build order (summary — details in 08-roadmap.md)

- **M1 — Walking skeleton:** SwiftTerm view + ios_system + folder picker. You can `ls`, `cd`,
  `cat`, pipe, redirect inside a picked folder. (This alone is already a shippable mini-app.)
- **M2 — Real shell feel:** command history, tab-completion, multiple tabs, key toolbar
  (Esc/Ctrl/arrows), themes.
- **M3 — Runtimes:** CPython + pip; nodejs-mobile + npm.
- **M4 — Claude Code:** embedded Node runs the `claude` CLI with our process-shim layer; PTY
  wiring so its TUI renders perfectly.
- **M5 — Linux lane:** Blink + Alpine rootfs, `apk add` anything.
- **M6 — Polish & ship:** licenses screen, App Store review strategy (C7), TestFlight, launch.

Milestones M1–M4 are the product. M5 is the power-user cherry on top.

## 6. Ground rules for all agents working on components

- Swift + SwiftUI app shell; C/C++/ObjC where the reused libraries need it.
- Xcode project lives at repo root; each component is a Swift Package or xcframework where
  possible, so agents can work independently.
- Never bundle GPL code into the app binary. Check `07-appstore-licensing.md` before adding
  any dependency.
- Every command runs on a background thread/queue with its own stdin/stdout/stderr file
  descriptors — never block the main thread.
- All temp/scratch inside the app sandbox; user data only inside the picked folder.
- Target: iOS 16+, iPhone and iPad, Mac Catalyst free bonus later.
