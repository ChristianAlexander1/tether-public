# TetherRiscv/spike — `tetherspike`

Minimal harness that boots **riscv64 Alpine Linux** programs with
[libriscv](../spike/libriscv) and times them. Part of Tether Track P8 — see
`../REPORT.md` for findings and `../HANDOFF.md` for integration notes.

```bash
make -j2                         # build/tetherspike (threaded dispatch = iOS engine)
./fetch_assets.sh                # download Alpine 3.24.1 minirootfs (riscv64 + x86_64)
./build/tetherspike --rootfs assets/rootfs-riscv64 /bin/uname -a
```

Usage: `tetherspike [--rootfs DIR] [--memory MiB] [--fuel N] [--quiet] GUEST_PROGRAM [ARGS...]`

Examples:

```bash
./build/tetherspike --rootfs assets/rootfs-riscv64 /bin/busybox sha256sum /bench/payload.bin
./build/tetherspike --rootfs assets/rootfs-riscv64 /bin/sh /bench/loop.sh 2000000
```

Engines: `make` (threaded, default), `make MODE=switch`, `make MODE=bintr`.
After each run stderr prints a `TETHERSPIKE_RESULT` line (guest-MIPS, wall_s,
instrs, exit status) for scripting; see `bench.sh` for the full matrix driver.

Notes:
- Entry point is `main.c` (spec requirement); the engine glue is `tetherspike.cpp`
  (libriscv's API is C++20, so the loader/sandbox/telemetry code is C++ — ~300 lines).
- Vendored libriscv carries `P8-upstream-fixes.patch` (required for musl ld.so + AT_FDCWD).
- `assets/` is gitignored/zip-excluded; recreate with `fetch_assets.sh`.
