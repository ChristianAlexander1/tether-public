# C4 — Language Runtimes: Python & Node.js

**Goal:** `python`, `pip`, `node`, `npm` work in the terminal at native speed, installing
packages into the user's home, usable inside any workspace.

## Python — the easy one now

**CPython officially supports iOS since Python 3.13 (PEP 730, tier-3 platform; BeeWare
maintains it).** Apple even allows Python apps on the App Store (a-Shell, Pyto, Carnets
all ship CPython). PSF license = fully permissive.

Plan:
- Build CPython 3.13+ as an xcframework using the official `iOS/README` build scripts
  (BeeWare's `Python-Apple-support` repo, MIT scripts, gives prebuilt XCFrameworks —
  reuse it directly).
- Register `python3` in the C2 registry: entry point calls `Py_BytesMain` in-process
  (each run in a fresh subinterpreter or re-init; a-Shell ships this pattern).
- `PYTHONHOME` → bundled stdlib; `PYTHONPATH`/site-packages → `$HOME/python/`.
- **pip:** runs as pure Python — works out of the box for pure-Python wheels (most of
  PyPI: requests, flask, rich, numpy? no —) . For **binary wheels** (numpy, pandas,
  cryptography): iOS wheels now exist — PEP 730 defined the `ios_13_0_arm64_iphoneos`
  wheel tag and packages are appearing; also reuse a-Shell's approach (he hosts prebuilt
  iOS wheels; BSD repo — we can host our own wheel index `pip install --index-url`).
  Ship top-20 scientific wheels prebuilt with the app or our CDN index.
- App Store note: downloading interpreted code (Python) is allowed under 2.5.2;
  precedent: Pyto, a-Shell, Juno all allow pip on the store.

## Node.js — the strategic one (Claude Code depends on it)

**Use [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) — MIT, community-
maintained fork of Janea's project.** It builds full Node.js (V8 in JIT-less mode) as an
iOS framework. V8 without JIT is ~2–5x slower than desktop — still perfectly fine for
CLIs, npm, and Claude Code (whose work is I/O + API-bound, not CPU-bound).

Work items:
1. **Bring the fork current:** nodejs-mobile tracks Node LTS; verify its current Node
   version ≥ what Claude Code requires (18+). If behind, bump — the fork's build scripts
   make version bumps mechanical. (Fallback: Hermes/Bun are not options; V8-jitless is
   the proven path. JavaScriptCore lane: keep as research spike — `node-jsc` exists but
   is stale.)
2. **Multiple invocations:** nodejs-mobile is designed for one engine instance per app.
   We wrap it as a persistent "Node service" thread; `node script.js` from the shell =
   post a job to the engine (fresh V8 context/realm per job, own argv/cwd/env, stdio
   bridged to the calling VirtualProcess's fds). For stubborn cases, serialize: one Node
   job at a time is acceptable for v1 (npm and claude are each single jobs anyway).
3. **stdio/tty bridge:** map `process.stdout/stderr/stdin` to our pty fds; implement
   `tty.isatty` → true so colors/ink TUIs render.
4. **`child_process` shim (critical for npm & Claude Code):** patch/override Node's
   `child_process.spawn/exec` at the JS layer (require-hook injected via `--require`):
   spawned commands route into **C2's VirtualProcess API** (so `npm` calling `sh`, `git`,
   `rg` etc. works — they're our native in-process commands). This shim is the single
   most important piece of engineering in C4/C5 — spec it carefully, test it against
   npm's real call patterns (`npm install`, lifecycle scripts).
5. **npm:** ships inside Node release; prefix → `$HOME/node`; global bin dir on PATH.
   Registry access is plain HTTPS — works. Native addons (`node-gyp`) → out of scope v1
   (mark unsupported; pure-JS packages are the overwhelming majority, and Claude Code
   needs none beyond what it bundles).

## Also worth bundling (cheap wins)

- `deno`? No — V8 again, redundant. Skip.
- **QuickJS (MIT)** as `qjs` — instant tiny JS runner, nice for scripts when the big
  engine is busy.
- **Lua 5.4 (MIT)** — 200KB, users love it.

## Deliverable

- `TermXPython.xcframework` + registry entries + wheel index plan
- `TermXNode.xcframework` (nodejs-mobile build) + Node service wrapper + stdio/tty bridge
- `child_process`-shim JS package (`@termx/shim`) with npm-install e2e test
- Docs: how `pip install` / `npm install -g` map to $HOME dirs
