# TetherRiscv — Track P8 handoff

Spike: evaluate **riscv64 Alpine (libriscv)** vs **Blink x86 Alpine** for Tether.
Everything here is Linux/macOS-host only; **no iOS code** was written, per rules.
Primary read: **`REPORT.md`** (answers + data). This file = how to reproduce & what's next.

## Layout

```
TetherRiscv/
├── REPORT.md                      # the 5 required answers, with measurements
├── LICENSE                        # MIT (our glue); libriscv = BSD-3 (unmodified license kept)
├── HANDOFF.md                     # this file
└── spike/
    ├── main.c                     # minimal C entry point (spec-required) -> forwards argv
    ├── tetherspike.cpp            # ~300-line libriscv harness (rootfs sandbox, loader boot,
    │                              #   auxv fixes, wall-clock + MIPS telemetry)
    │                              #   C++20 because libriscv's API is C++20; main.c entry preserved.
    ├── Makefile                   # plain-make build (no cmake needed); MODE=threaded|switch|bintr
    ├── libriscv/                  # vendored lib sources @12055fb (tag v1.20, 2026-08-23)
    │   ├── REVISION               #   exact upstream commit + license pointer
    │   └── P8-upstream-fixes.patch#   the 2 required upstream fixes (SEE BELOW), applied to vendored tree
    ├── fetch_assets.sh            # re-download Alpine minirootfs + fix absolute symlinks
    ├── bench.sh                   # full benchmark matrix driver
    ├── assets/                    # (excluded from zip; run fetch_assets.sh) rootfs-riscv64/ rootfs-x86_64/
    └── results/
        ├── bench-2026-08-23.txt   # raw benchmark log incl. TETHERSPIKE_RESULT lines
        └── apk-counts.txt         # Alpine v3.24 package parity table
```

## Reproduce (3–5 min)

```bash
cd TetherRiscv/spike
make -j2                          # -> build/tetherspike (threaded; iOS-representative)
./fetch_assets.sh                 # minirootfs 3.24.1 for riscv64 + x86_64, bench payloads
./build/tetherspike --rootfs assets/rootfs-riscv64 /bin/uname -a
   # => RISC-V C++ Emulator libriscv 5.6.0 rv64imafdc Linux  (exit 0)
./bench.sh                        # full matrix -> results/ (takes ~15 min)
```

Other engines: `make MODE=switch` / `make MODE=bintr` → `build/tetherspike-switch|-bintr`.
Useful env: `TETHERSPIKE_DEBUG=1` (registers/auxdump on fault), `TETHERSPIKE_TRACE=N` (single-step ring trace).

## The two upstream libriscv fixes (carry these!)

Without them, upstream **cannot run any musl dynamic executable** (Alpine is 100 % musl-dynamic).
Both are in `spike/libriscv/P8-upstream-fixes.patch`, already applied to the vendored tree:

1. **`AT_PHDR` into the loaded image** (`lib/libriscv/machine.cpp`, `setup_linux`): Linux points
   AT_PHDR at the in-image phdr table when covered by a PT_LOAD; libriscv always pushed a stack
   copy. musl `__dls3` then misdetects "kernel-mapped app", computes base 0, and faults writing
   the fake app's RW gaps at raw vaddrs (observed via instruction trace: `sb a1,0(a0)` → 0x98ED8).
2. **`AT_FDCWD` passthrough in `syscall_openat`** (`lib/libriscv/linux/system_calls.cpp`):
   vfd translation turned AT_FDCWD(-100) into -1 → EBADF on the loader's first `open()`.
   Now matches the existing `faccessat` handler's special-case.

Plus, in our harness (`spike/tetherspike.cpp`): rewrite the guest auxv `AT_BASE` to
`loaded_entry − ELF.e_entry` (upstream's 16 MB mask yields 0 for small images).
**Recommend: file these upstream as a PR** (draft text is inside the patch; both are objectively kernel-faithful).

## Minirootfs packaging note

612 symlinks in the Alpine minirootfs are absolute (`/bin/uname → /bin/busybox`); a naive
rootfs-prefix lets the host kernel resolve them outside the jail. `fetch_assets.sh` rewrites
them to relative form (610 succeed; 2 live in a read-only `etc/ssl1.1/certs` dir and are
harmless — only relevant if you later install TLS cert bundles). On iOS, apply the same
rewrite at bundle-build time (or add `O_NOFOLLOW` + manual symlink walk in the open() shim).

## On-device A/B plan (decision gate for Q5)

1. Build `spike/tetherspike.cpp` + vendored `library` as a static lib for arm64-apple-ios (no build-system
   work: same source list as `spike/Makefile`; enable `RISCV_64I`, `RISCV_THREADED`).
2. Bundle `assets/rootfs-riscv64` (post-rewrite, ~16 MB) in the app; point the harness at it.
3. Run the same `/bench/loop.sh`, awk loop, sha256 of identical payload via libriscv.
4. Run the equivalent x86_64-busybox payload via Tether's existing Blink engine.
5. Compare effective guest-MIPS / wall seconds. **Replace-gate: libriscv ≥ 1.5× Blink.**
   (Optional second axis: staleness of x86 userland vs riscv64 apk parity list in REPORT §3.)

## Next steps (ordered)

- [ ] Upstream the 2 fixes (PR), then un-vendor back to a submodule pinned to the fixed tag.
- [ ] iOS static-lib build + Swift/ObjC++ session shim (days, see REPORT §4).
- [ ] Try a custom **RVC-disabled** riscv64 musl toolchain for +20–25 % interpreter speed
      (upstream-documented lever; needs a small buildroots pass).
- [ ] Optional: evaluate *embedded* binary translations for the shipped BusyBox userland
      (iOS-legal; pre-compiled into the binary; upstream feature).
- [ ] Guest network stack decision (sockets were off in the spike).
- [ ] Long-session persistence: `serialize.cpp` exists upstream but was not exercised.

## Known limitations / honesty notes

- Blink itself could not be executed here (iOS-only engine, no public benchmark) — REPORT §2 says
  exactly what was measured instead and why it transfers.
- The two libriscv fixes were found by tracing one real bug (deterministic at boot); other musl
  userland components were not exhaustively validated (rsync/clang-class stress = future work).
- Benchmarks ran on a 2-vCPU cloud host under `-O2`; absolute MIPS will be higher on Apple
  silicon — relative ratios are the signal, not the absolute numbers.
- `bintr` (runtime C-translation) was a net loss here and is *not* the path for iOS runtime anyway.

## Contact points in code

- Rootfs sandbox: `spike/tetherspike.cpp` `fds().filter_open` (escape-safe path rewrite).
- Loader boot: `Elf<8>::is_dynamic` → load `/lib/ld-musl-riscv64.so.1` as machine binary.
- Telemetry: `TETHERSPIKE_RESULT …` line on stderr after every run (parse-friendly).
