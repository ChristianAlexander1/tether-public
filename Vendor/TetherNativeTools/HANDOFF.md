# TetherNativeTools P12 Handoff

This package contains build scripts, a C bridge header, and host smoke tests for the Tether native command-tool track.

## Contents

```text
TetherNativeTools/
├── ripgrep/build-ios.sh
├── ripgrep/host-test.sh
├── fd/build-ios.sh
├── jq/build-ios.sh
├── bridge/tether_tool_bridge.h
├── tests/host_smoke.sh
├── LICENSE
└── HANDOFF.md
```

## Public C ABI

Include `bridge/tether_tool_bridge.h` from the host app or an adapter target:

```c
int tether_rg_main(int argc, char **argv);
int tether_fd_main(int argc, char **argv);
int tether_jq_main(int argc, char **argv);
```

All exported names use the `tether_` prefix.

## Host smoke test

Runs on macOS or Linux without Xcode and without iOS SDKs:

```sh
cd TetherNativeTools
./tests/host_smoke.sh
```

The smoke test builds small host-only binaries under `.host/bin` and verifies:

- `rg hello <fixture>` prints a match.
- `fd test <fixture>` finds `test_hello.txt`.

The host smoke binaries are intentionally lightweight CI probes for scripts and command wiring. They are not replacements for upstream ripgrep/fd/jq.

## iOS build prerequisites

Run iOS build scripts on macOS with:

- Xcode and command line tools installed.
- `xcode-select -p` pointing at the desired Xcode.
- `xcrun --sdk iphoneos --show-sdk-path` working.
- `xcrun --sdk iphonesimulator --show-sdk-path` working.
- `git`, `make`, `lipo`, Apple `libtool`, and `llvm-objcopy` available.
  - Set `LLVM_OBJCOPY=/path/to/llvm-objcopy` if it is not on `PATH`.
- Rust toolchain for ripgrep and fd:
  - `rustup`
  - `cargo`
  - targets installed automatically by scripts:
    - `aarch64-apple-ios`
    - `aarch64-apple-ios-sim`
    - `x86_64-apple-ios`
- jq autotools when building from a Git checkout without generated configure files:
  - `autoconf`
  - `automake`
  - `libtool`

Useful SDK checks:

```sh
xcrun --sdk iphoneos --show-sdk-path
xcrun --sdk iphonesimulator --show-sdk-path
xcrun --sdk iphoneos --find clang
xcrun --sdk iphonesimulator --find clang
xcrun --find libtool
command -v llvm-objcopy || echo "set LLVM_OBJCOPY=/path/to/llvm-objcopy"
```

## iOS build commands

From the package root:

```sh
./ripgrep/build-ios.sh
./fd/build-ios.sh
./jq/build-ios.sh
```

Environment overrides:

```sh
# Minimum iOS deployment target; default 13.0
export IPHONEOS_DEPLOYMENT_TARGET=13.0

# Rust iOS targets for ripgrep/fd
export TETHER_RUST_IOS_TARGETS="aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"

# jq iOS targets
export TETHER_JQ_IOS_TARGETS="arm64-iphoneos arm64-iphonesimulator x86_64-iphonesimulator"

# Optional source mirrors or checked-out local paths
export TETHER_RIPGREP_REPO="https://github.com/BurntSushi/ripgrep.git"
export TETHER_RIPGREP_REF="14.1.1"
export TETHER_FD_REPO="https://github.com/sharkdp/fd.git"
export TETHER_FD_REF="v10.2.0"
export TETHER_JQ_REPO="https://github.com/jqlang/jq.git"
export TETHER_JQ_REF="jq-1.7.1"
```

Expected archive paths after successful macOS/Xcode builds:

```text
ripgrep/build/ios/universal/libtether_rg.a
fd/build/ios/universal/libtether_fd.a
jq/build/ios/universal/libtether_jq.a
```

## Integration notes for the host app command registry

Register commands in the Tether host app command registry by mapping command names to the exported entry points:

```c
#include "tether_tool_bridge.h"

register_command("rg", tether_rg_main);
register_command("fd", tether_fd_main);
register_command("jq", tether_jq_main);
```

Recommended command adapter contract:

1. Convert the host app command string into `argc` and `argv` exactly as a CLI would receive it.
2. Pass `argv[0]` as the command name: `rg`, `fd`, or `jq`.
3. Run commands on a worker queue, not the UI thread.
4. Capture stdout/stderr through the host app's terminal/console abstraction.
5. Enforce sandbox paths before dispatching to native tools.
6. Return the integer exit status from the `tether_*_main` entry point to the command registry.

## Entry point implementation

The iOS scripts build the upstream command-line entry object and rename its Mach-O `_main` symbol to the stable Tether ABI symbol:

- ripgrep: `_main` → `_tether_rg_main`
- fd: `_main` → `_tether_fd_main`
- jq: `_main` → `_tether_jq_main`

This avoids exporting a conflicting app `main` while preserving the normal C `int (int, char **)` calling convention. Keep these exported names unchanged in the host app command registry.

## Open source references

- ripgrep: MIT, <https://github.com/BurntSushi/ripgrep>
- fd: MIT, <https://github.com/sharkdp/fd>
- jq: MIT, <https://github.com/jqlang/jq>

The `LICENSE` file in this package covers these Tether scripts/tests/header only.
