# C4 — Language Runtimes: Python & Node.js

**Goal:** `python`, `pip`, `node`, `npm` at native speed — full package ecosystems, any
Node-based CLI (including Claude Code) via the **generic** spawn/shim layer.

**Platform context:** [`GUEST-PLATFORM.md`](GUEST-PLATFORM.md) — node/npm/claude are
**host runtime manifest** entries only because they are app-shipped stubs, not guest ELFs.
Everything else (`git`, `python3` from apk, …) resolves through guest PATH or native tier.

## Python

**CPython 3.13+ on iOS** (PEP 730; BeeWare `Python-Apple-support`, MIT scripts).

- `python3` → `Py_BytesMain` in-process per job
- `PYTHONHOME` → bundled stdlib; site-packages → `$HOME/python/`
- **pip:** pure-Python wheels work; binary wheels via iOS wheel tags + hosted index (a-Shell
  model — [PyPi-index-aarch64-apple-ios](https://github.com/hololeap/PyPi-index-aarch64-apple-ios))
- Ship top scientific wheels on CDN or prebuilt in app

## Node.js

**[nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile)** MIT — V8 jitless on iOS.

Current pin: digidem **v24.19.0-1 full** (ICU for Claude Code Unicode regex).

Work items:
1. Stay current with Node LTS Claude requires.
2. **Node service:** persistent engine thread; each `node script.js` = fresh V8 context,
   serialized or parallel jobs with isolated contexts (target: npm + claude concurrent with
   shell).
3. **stdio/tty bridge:** pty fds; `tty.isatty` → true.
4. **`child_process` shim (P3):** full API → **SpawnExecuting** (generic PATH: native → wasm → guest one-shot). URL openers → **SystemOpen.resolve** (any https URL).
5. **npm:** prefix `$HOME/node`; global bin on PATH.
6. **node-gyp / native addons:** document supported path via prebuilt wheels or Linux guest
   `apk add nodejs-dev` + gcc; shim reports clear errors when unsupported on host Node.

**Not Claude-specific:** the shim implements Linux `child_process` semantics for **any** npm
package that spawns shell tools or openers.

## Also bundle

- **QuickJS (MIT)** as `qjs` — lightweight JS when Node busy
- **Lua 5.4 (MIT)** — scripting

## Deliverable

- `TermXPython.xcframework` + wheel index
- `TermXNode.xcframework` + Node service + `@tether/shim` (P3)
- Docs: pip/npm home dirs, addon policy
