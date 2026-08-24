# Robustness — Mac integrator only (NOT for sub-agents)

## The one rule (read this first)

**If you `apk add` it on Alpine, it runs as Linux inside Blink. Full stop.**

- `git`, `python3`, `gcc`, `vim`, `curl`, `jq`, … → **guest ELF**
- No Swift/C special case per tool
- No “tomorrow we hardcode fix for tool X”

When something from `apk add` fails, you fix **Blink / syscalls / guest** — you do **not**
add that tool name to a host list.

---

## Only two generic host bridges (not a growing tool list)

These are **mechanisms**, not “Claude hacks” or “git hacks”:

### 1. Browser / URL opener (any program, any https URL)

When the guest executes a **known URL-opener basename** (`xdg-open`, `open`,
`sensible-browser`, … — list lives in **config**, not scattered `if` statements):

→ Host receives URL → opens in-app Safari (or external if user chooses)

Works for:
- Claude OAuth login
- `xdg-open https://docs.example.com`
- Any future CLI that opens a browser

**Not Claude-specific.** OAuth is just one URL.

### 2. Host runtime manifest (P5) — only for “cannot run as guest ELF”

Some binaries are **not** x86 Linux ELFs you can emulate (embedded Node runtimes,
stubs shipped by the app). Those are listed in **`tether_offload_manifest.json`**
— data, not hardcoded C strings.

```json
{
  "browser_openers": ["open", "xdg-open", "gnome-open", "kde-open", "sensible-browser", "wslview"],
  "host_runtimes": [
    {"match": "basename", "name": "node"},
    {"match": "basename", "name": "npm"},
    {"match": "basename", "name": "npx"},
    {"match": "basename", "name": "claude"}
  ],
  "default": "guest_elf"
}
```

**Adding a new apk tool:** do nothing — it runs as guest.  
**Adding a new host runtime:** add one manifest row — not a code change in bridge.c.

Integrator **must remove** hardcoded `path_is_host_backed()` strcmp list in
`termx_blink_bridge.c` and use P5 registry + manifest.

---

## What runs where (default)

| User runs | Where it runs |
|-----------|---------------|
| `apk add git && git commit` | **Alpine guest** |
| `apk add python3 && python3 script.py` | **Alpine guest** |
| `apk add ripgrep && rg foo` | **Alpine guest** |
| `node` / `npm` (app stubs) | **Host** (manifest) |
| `claude` (app stub) | **Host** (manifest) |
| `xdg-open https://…` | **Host URL opener** (generic) |
| Anything else from apk | **Alpine guest** |

Claude **inside** its session may spawn `git` / `rg` — host resolves via **generic
command engine PATH** (native → wasm → guest one-shot), **not** a hardcoded “Claude
needs git” block.

---

## Linux env (generic, not Claude-only)

Guest login environment should look like a minimal Linux desktop shell:

- `DISPLAY=:0`
- `WAYLAND_DISPLAY=tether`
- `BROWSER=open` (optional)

Any program that checks `DISPLAY` before calling `xdg-open` works — not only Claude.

---

## Signals & Ctrl+C

| Context | Handler |
|---------|---------|
| Alpine `sleep` + ^C | **Blink / guest kernel** (P7 tests) |
| Node job + ^C | **P3 cancel JSON** → 130 |
| Do **not** call `linux.interrupt()` for Claude ^C | tears down whole guest |

---

## No cascade crashes

| Forbidden | Why |
|-----------|-----|
| Second `blink_run()` during login shell | kills machine |
| UI fetch / modal during busy Blink | race crash |
| Per-tool Swift hooks for apk binaries | wrong layer — use guest |

**Step 8b** (MERGE-AND-VERIFY): install many apk packages in one session, then run
host stubs + URL open — app must stay alive.

---

## Tests prove mechanisms, not tools

| Track | Tests |
|-------|-------|
| P7 | guest ELF, pipelines, signals, **apk chains** |
| P3 | **any** spawn/cancel via IPC |
| P5 | manifest resolve: guest default, opener class, runtime class |
| P10 | **generic spawn replay** (OAuth URL is one example in fixtures) |

Failing `apk add foo` → fix guest. Failing `xdg-open` → fix opener class. Failing
manifest runtime → fix manifest row. **Never** add `strcmp(..., "foo")` in bridge.c.

---

## Sign-off

Ship when Step 8 + 8b pass **and** bridge uses P5 manifest (no hardcoded tool list).
