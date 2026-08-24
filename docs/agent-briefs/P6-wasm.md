# Track P6 — WASM runner

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No app repo, no iOS.
2. **Do not ask** for the iOS app or other teams' code.
3. **Naming:** product is **Tether**. API `tether_wasm_*`. Never TermX/`termx`.
4. **Build only** WASM runner below.
5. **Tests pass** including sample `hello.wasm`.
6. **Zip:** `TetherWasm-P6.zip`

---

# Your job: wasm32-wasi command runner

## Context
Users install wasm32-wasi CLIs in `~/wasm/bin` — unlimited commands without app updates (a-Shell model).

## YOUR job ONLY
WASM interpreter + WASI subset. No iOS UI.

## Deliver
```
TetherWasm/
├── Package.swift or CMakeLists.txt
├── Sources/ (wasm3 embed OR WasmKit doc)
├── Tests/
├── sample/hello.wasm + build script
├── LICENSE
└── HANDOFF.md
```

## C API
```c
int tether_wasm_run(const char *wasm_path, char *const argv[], int argc,
                   const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd);
```

## WASI minimum
args, environ, fd_read, fd_write, path_open, path_filestat_get, proc_exit

## Tests
| Test | Pass |
|------|------|
| hello.wasm | prints hello, exit 0 |
| bad path | exit non-zero |
| read stdin | echo wasm works |

## Zip: **`TetherWasm-P6.zip`**

## Open source
- [wasm3](https://github.com/wasm3/wasm3) MIT
- [WebAssembly/wasi-sdk](https://github.com/WebAssembly/wasi-sdk) Apache-2

## License: MIT
