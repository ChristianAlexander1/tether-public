# Track P12 — rg/fd/jq iOS build scripts

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** Build scripts + host tests.
2. **Do not ask** for the iOS app.
3. **Naming:** product is **Tether**. Prefix `tether_`. Never TermX/`termx`.
4. **host_smoke.sh** must pass on Mac/Linux.
5. **Zip:** `TetherNativeTools-P12.zip`

---

# Your job: cross-compile ripgrep, fd, jq for iOS static libs

## Context
Claude Code uses `rg` heavily. Build scripts to compile ripgrep, fd, jq as static libs with C entry points for iOS (integrator links on Mac).

## YOUR job ONLY
Build scripts + host smoke tests. iOS slice built when Xcode SDK available.

## Deliver
```
TetherNativeTools/
├── ripgrep/build-ios.sh, host-test.sh
├── fd/build-ios.sh
├── jq/build-ios.sh
├── bridge/tether_tool_bridge.h   # rg_main, fd_main wrappers
├── tests/host_smoke.sh
├── LICENSE
└── HANDOFF.md
```

## bridge header
```c
int tether_rg_main(int argc, char **argv);
int tether_fd_main(int argc, char **argv);
int tether_jq_main(int argc, char **argv);
```

## host_smoke.sh (runs on Mac/Linux without iOS)
- Build host binary
- `rg hello` in test dir → match
- `fd test` → finds file

## HANDOFF.md
- Xcode SDK paths needed for iOS static lib
- Register commands in the host app command registry (notes for integrator)

## Zip: **`TetherNativeTools-P12.zip`**

## Open source
- [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) MIT
- [sharkdp/fd](https://github.com/sharkdp/fd) MIT
- [jqlang/jq](https://github.com/jqlang/jq) MIT

## License: MIT (scripts only)
