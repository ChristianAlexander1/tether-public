# Tether Native Offload — Handoff

## Contents

- `include/tether_offload.h` — public C API
- `src/offload.c` — process-global, thread-safe registry
- `manifest.example.json` — integration manifest example
- `SPEC.md` — matching, ownership, API, and manifest contract
- `tests/test_offload.c` — host unit tests
- `LICENSE` — MIT license

## Build and test

From this directory on Linux or macOS:

```sh
cc -std=c11 -Wall -Wextra -Wpedantic -Werror \
  -Iinclude src/offload.c tests/test_offload.c -o test_offload
./test_offload
```

Optional Clang/GCC sanitizer run:

```sh
cc -std=c11 -Wall -Wextra -Wpedantic -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Iinclude src/offload.c tests/test_offload.c -o test_offload_san
./test_offload_san
```

## Integration notes

1. Parse and validate the JSON manifest in the embedding layer.
2. Map each manifest `host` identifier to a host callback and opaque context.
3. Register exact paths with `tether_offload_register_guest_path()` and
   basename selectors with `tether_offload_register_basename()`.
4. Prefer `tether_offload_execute()` for dispatch. If dispatch needs custom
   work between lookup and invocation, use `tether_offload_resolve_entry()` so
   both the callback and its context are available.
5. Coordinate unregister/clear with destruction of borrowed callback contexts.

The core library deliberately does not parse JSON or launch a process. The
callback is the host boundary and decides how execution, environment, and file
descriptors are handled.
