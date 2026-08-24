# Track P5 — Guest/host dispatch registry (C)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No app repo, no iOS.
2. **Do not ask** for the iOS app or other teams' code.
3. **Naming:** product is **Tether**. API prefix `tether_`. Never TermX/`termx`.
4. **This is a generic dispatch layer** — NOT a hardcoded list of tool names in C.
5. **Unit tests pass** on Linux/macOS host.
6. **Zip:** `TetherNativeOffload-P5.zip`

---

# Your job: manifest-driven guest vs host dispatch

## One-sentence spec

When Alpine `exec()` runs a program, ask the registry: **guest ELF** (default),
**host runtime** (manifest), or **URL opener** (manifest class). No per-tool `if
(strcmp(name,"git"))` in C.

## Design rules (mandatory)

1. **`default` = guest_elf** — everything from `apk add` runs emulated unless manifest says otherwise.
2. **`browser_openers`** — basename list in JSON only (open, xdg-open, …).
3. **`host_runtimes`** — only binaries that are NOT guest ELFs (embedded Node stubs).
4. **git, python, gcc, rg must NOT appear in host_runtimes** — they are apk guest tools.
5. Adding a new apk package requires **zero code changes**.

## Deliver
```
TetherNativeOffload/
├── include/tether_dispatch.h
├── src/dispatch.c
├── manifest.schema.json
├── manifest.example.json
├── tests/test_dispatch.c
├── SPEC.md
├── LICENSE
└── HANDOFF.md
```

## Dispatch result enum

```c
typedef enum {
  TETHER_DISPATCH_GUEST_ELF,      /* run under Blink — default */
  TETHER_DISPATCH_URL_OPENER,     /* host opens URL from argv */
  TETHER_DISPATCH_HOST_RUNTIME    /* host runs registered handler */
} tether_dispatch_kind;

typedef struct {
  tether_dispatch_kind kind;
  const char *matched_rule;       /* for logging */
} tether_dispatch_result;

int tether_dispatch_load_manifest(const char *json_path);
tether_dispatch_result tether_dispatch_resolve(const char *prog_path);
```

## manifest.example.json

```json
{
  "default": "guest_elf",
  "browser_openers": [
    "open", "xdg-open", "gnome-open", "kde-open", "sensible-browser", "wslview"
  ],
  "host_runtimes": [
    {"match": "basename", "name": "node", "handler": "node-mobile"},
    {"match": "basename", "name": "npm", "handler": "node-mobile"},
    {"match": "basename", "name": "npx", "handler": "node-mobile"},
    {"match": "basename", "name": "claude", "handler": "node-mobile"}
  ]
}
```

## Tests (required)

| Test | Expected |
|------|----------|
| `/usr/bin/git` | GUEST_ELF (not in manifest) |
| `/usr/bin/python3` | GUEST_ELF |
| `/usr/bin/xdg-open` | URL_OPENER |
| `node` basename | HOST_RUNTIME |
| unknown `/usr/bin/gcc` | GUEST_ELF |
| reload manifest → new rule | picks up without recompile |

## SPEC.md must document

- Integrator replaces hardcoded strcmp lists with this API
- How URL opener passes argv[1] to host
- How HOST_RUNTIME invokes registered handler

## License: MIT
