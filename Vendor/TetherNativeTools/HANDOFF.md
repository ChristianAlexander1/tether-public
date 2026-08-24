# Tether native-tool build scripts

This directory contains reproducible scripts that build the real upstream
ripgrep, fd and jq command entry points for iOS. It intentionally contains no
miniature “compatible” substitutes or canned smoke binaries.

## Outputs

```text
ripgrep/build/ios/universal/libtether_rg.a
fd/build/ios/universal/libtether_fd.a
jq/build/ios/universal/libtether_jq.a
```

The stable C ABI is declared in `bridge/tether_tool_bridge.h`:

```c
int tether_rg_main(int argc, char **argv);
int tether_fd_main(int argc, char **argv);
int tether_jq_main(int argc, char **argv);
```

## Build

The scripts require Xcode, Git, `llvm-objcopy`, Apple `libtool`, and `lipo`.
ripgrep/fd additionally require Rust and the iOS Rust targets; jq requires its
autotools dependencies.

```sh
./ripgrep/build-ios.sh
./fd/build-ios.sh
./jq/build-ios.sh
```

Source repositories, pinned refs, iOS targets and deployment version are
configurable through the `TETHER_*` variables documented at the top of each
script. The scripts clone and compile upstream source; they do not generate
replacement command implementations.

Tether’s default Linux terminal already runs the real Alpine packages. These
archives are an optional native acceleration tier and must not replace guest
commands until their standard descriptors, cancellation and workspace
confinement are wired into the shared command registry.

Upstream licensing: ripgrep MIT, fd MIT, jq MIT. `LICENSE` covers Tether’s
scripts and bridge header.
