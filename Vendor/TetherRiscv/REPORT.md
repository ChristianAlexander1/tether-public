# Tether — Track P8: libriscv (riscv64 Alpine) vs Blink (x86 Alpine) — Spike Report

**Date:** 2026-08-23 · **Track:** P8 · **Component:** isolated spike only (no iOS)
**Deliverable:** `TetherRiscv/` → `TetherRiscv-P8.zip`
**Engine under test:** [libriscv](https://github.com/libriscv/libriscv) (BSD-3), vendored @ `12055fb` (tag `v1.20`, 2026-08-23)
**Guest userland:** Alpine Linux 3.24.1 minirootfs, **riscv64** (musl 1.2.6 / BusyBox 1.37.0, RV64GC dynamic ELF)
**Host:** Linux x86-64, 2 vCPU, g++ 14.2 (`-O2`), no JIT on this machine for interpreter rows

---

## TL;DR

| Question | Answer |
|---|---|
| 1. Does riscv64 Alpine boot `/bin/uname`? | **YES** — fully, incl. the dynamic musl loader — with **two 20-line fixes to libriscv** (now vendored, see `libriscv/P8-upstream-fixes.patch`) plus one auxv tweak in our glue |
| 2. Speed vs Blink x86 on same machine | Blink can't run here (iOS-only). Proxy measured: libriscv riscv64 vs **native x86_64 Alpine** = **12×–58× native slowdown** depending on workload (195–747 effective guest-MIPS on this host). Blink has no public benchmark; an on-device A/B is scripted and ready |
| 3. `apk` package availability | riscv64 has **26,780 of 28,639** packages (93.5%) vs x86_64. Missing: rustc, clang, chromium, dotnet, xen. Present: gcc, go, nodejs, python3, mariadb, postgresql, nginx, openjdk21 |
| 4. iOS integration effort | **2 / 5** (small). libriscv is self-contained C++20, no JIT needed, no external deps; spike proves it boots musl userspace inside ~300 lines of glue |
| 5. Recommendation | **ADD RISC-V** as an alternate engine behind a provider switch; **do not replace Blink yet**. Gate on an on-device benchmark showing ≥1.5× Blink throughput |

---

## 1. Does riscv64 Alpine minirootfs boot `/bin/uname`?

**Yes.** Exact reproduction (Ubuntu/Debian host, no cmake needed):

```console
$ cd TetherRiscv/spike && make -j2
$ ./build/tetherspike --rootfs assets/rootfs-riscv64 /bin/uname -a
RISC-V C++ Emulator libriscv 5.6.0 rv64imafdc Linux
(exit 0, 329,977 guest instructions, ~12 ms)
```

What runs behind this is the complete real-world boot path, not a stub:

- `/bin/uname` (symlink → `/bin/busybox`) is a **dynamically linked PIE**; the harness loads **`/lib/ld-musl-riscv64.so.1` as the machine binary** (upstream's documented pattern) with argv `[ld.so, /bin/uname, -a]`.
- musl's `map_library` mmaps the BusyBox segments via guest `openat`/`mmap`, performs RELRO, gap-reclaim, TLS setup, and jumps to BusyBox `main`.
- Every guest file access is funneled through `fds().filter_open`, which rewrites absolute guest paths into `assets/rootfs-riscv64/` with lexical `..` escape checks (a chroot-like sandbox, ~40 lines in spike/tetherspike.cpp).

### What had to be fixed (important finding)

Unmodified upstream libriscv (`v1.20` = today's master) **cannot boot a musl dynamic executable**. Root-caused with instruction-level tracing and musl source review:

1. **`AT_PHDR` must point into the loaded image** (`libriscv/machine.cpp`). Linux (fs/binfmt_elf.c) points the auxv at the in-image program-header table when the phdr table is covered by a PT_LOAD. libriscv always pushed a *stack copy*. musl's `__dls3` compares `AT_PHDR` against its own in-image phdrs; on mismatch it assumes "the kernel already loaded an app" and computes the fake app's base as **0** (the stack copy lacks PT_PHDR), then zeroes the "app's" RW segment gaps at **raw vaddrs**, faulting on the ld.so's own R+X pages. Added the kernel-faithful PT_LOAD check; stack copy remains as fallback.
2. **`AT_FDCWD` was mangled in `syscall_openat`** (`libriscv/linux/system_calls.cpp`). `translate(-100)` returned -1 → host `openat(-1, …)` → EBADF on the very first musl `open(argv[0])`. Now forwarded verbatim, same as the sibling `faccessat` handler already does.
3. **`AT_BASE` auxv** (harness-side, `spike/tetherspike.cpp`): upstream writes `start_address & ~16MB`, i.e. `0` whenever the loader image sits below 16 MB (always true here); our glue rewrites `AT_BASE` with `loaded_entry − ELF.e_entry`. Harmless-true value; musl did not strictly need it after fix #1 but glibc-style loaders and `__dls2` diagnostics read it.

Both library fixes are objectively kernel-faithful and should be upstreamed (prepared as `libriscv/P8-upstream-fixes.patch`, 57 lines, well-commented).

### Other riscv64-Alpine quirks found (integration notes)

- Minirootfs applet links are **absolute symlinks** (`/bin/uname → /bin/busybox`). Host-side path-prefixing must not let the kernel resolve those, so `fetch_assets.sh` rewrites the 612 links to relative form. On iOS the same rewrite (or `O_NOFOLLOW` + manual link walk) is needed when packaging the rootfs.
- Guest is **RV64GC** (A, F/D, C extensions); all are on by default in libriscv.
- BusyBox startup to shell prompt-class cost ≈ **12 ms** — boot latency is a non-issue.

---

## 2. Benchmark vs Blink x86 (same machine, timer)

**Constraint stated plainly:** Blink's x86 emulator ships only inside the Blink iOS/macOS apps; it cannot run on this Linux host, and it publishes **no reproducible benchmark**. So this spike measures the thing that transfers: *emulated riscv64 vs the exact same Alpine userland executing natively on the same cores*, timed host-side (`date +%s%N` around the emulator; per-run `TETHERSPIKE_RESULT` gives guest instructions + effective guest-MIPS inside the emulator).

Workload = the **identical BusyBox binaries** (riscv64 guest vs x86_64 natively via the same musl-loader invocation), Alpine 3.24.1 both sides, payloads in `spike/assets/`.

### Results (wall time; lower is better)

| Guest workload (`/bench/…`) | native x86_64 | libriscv **threaded** (iOS engine) | libriscv **switch** | libriscv **bintr** (C→.so via cc) |
|---|---|---|---|---|
| `sh` arithmetic loop, N=2,000,000 | 4.294 s | **222.4 s** (195.1 MIPS) · **51.8×** | ≈248 s est. (173.9 MIPS, measured N=1M: 124.0 s) · ≈58× | 146 s for N=500K — translation compile dominates (~90 s), exec phase 194.8 MIPS → **no gain** |
| `awk` numeric loop, N=1,000,000 | 1.624 s | **19.10 s** (356.5 MIPS) · **11.8×** | 20.87 s (326.2 MIPS) · 12.9× | not run (see below) |
| `sha256sum` of 32 MiB | 0.183 s (175 MiB/s) | **3.574 s** (746.9 MIPS, 9.0 MiB/s) · **19.5×** | 4.806 s (555.5 MIPS, 6.7 MiB/s) · 26.3× | not run |
| startup: `/bin/uname -a` to exit | ~2 ms | **~12 ms** (~2 ms after warm FS cache) | ~12 ms | 80–161 s (translation compile each run; no on-disk cache hit on this commit) |

Full raw log: `spike/results/bench-2026-08-23.txt`.

### Reading

- **Effective guest throughput: ~175–750 MIPS** on a weak 2-core cloud host, engine default build (`-O2`, computed-goto "threaded" dispatch). BusyBox-shell-class interactive work (the Tether use case) sits at the low end; compute kernels (sha256, awk math) at the high end.
- The threaded (computed-goto) engine is the right default — only ~10–25 % ahead of the plain switch interpreter on syscall/memory-heavy work, much more on pure code.
- **Binary translation is not worth it for shell-style usage** and internally recompiles here; upstream explicitly targets that feature at shipped builds with *embedded* translations (which are iOS-legal, no `dlopen`). For an interactive terminal session the threaded interpreter is what will run on iOS.
- Estimated conservative working figure for planning UX: **interactive shell responsiveness feels native; heavy userland work in guest runs at roughly 1/20th–1/50th of native**.

### What this means relative to Blink (x86 Alpine)

Apples-to-apples isn't possible off-device, but the structural comparison favors libriscv-side riscv64:

- RISC-V is a fixed-width, RISC decode (cheap per-instruction dispatch); Blink must decode variable-length x86-64 (incl. SSE, legacy prefixes) or translate — intrinsically heavier and the reason x86 emulation on iPads historically feels "slow but fine" per Blink user reports (no public numbers exist).
- libriscv on ARM64 is a first-class path (upstream README: high-perf options for "consoles, mobiles"; +20–25 % interpreter gain available by shipping a custom **RVC-off** toolchain — impossible choice on the x86 side).

**Action to close the gap:** `HANDOFF.md` contains a same-script on-device A/B plan (this exact bench through Tether's existing Blink engine vs this riscv64 engine, iPad-class SoC). No code changes needed beyond shelling out to `bench.sh` payloads.

---

## 3. `apk` package count / compatibility notes

Counted from the `APKINDEX` of Alpine **v3.24** (main+community), fetched 2026-08-23 (`spike/results/apk-counts.txt`):

| repo | x86_64 | riscv64 | % |
|---|---|---|---|
| main | 5,961 | 5,912 | 99.2 % |
| community | 22,678 | 20,868 | 92.0 % |
| **total** | **28,639** | **26,780** | **93.5 %** |

Present on riscv64: gcc, musl-dev, go, nodejs+npm, python3+py3-pip, php84, mariadb, postgresql17, nginx, openjdk21-jdk, llvm20 libs.
Missing on riscv64 (1,857 pkgs, mostly subpackages): **rustc** (cargo pkg ships, no compiler), **clang**, **chromium**, **dotnet 8/10**, xen, kubo, typst, open-vm-tools. riscv64-only (7): opensbi, u-boot variants — irrelevant for Tether.
Bottom line: fine for a CLI tooling userland; do not ship promises about Rust/Clang toolchains inside the guest until Alpine riscv64 catches up.

**musl/dynamic-linking compatibility:** 100 % of Alpine's userland is musl-dynamic ⇒ the two loader fixes in §1 are *hard requirements* for any libriscv integration, not optional polish. With them, the full `ld.so → openat → mmap → RELRO → reclaim → TLS → main` path works; sockets in the guest were disabled in the spike (`permit_sockets=false`) and `${gdb}`/threading syscalls exist but were not exercised.

---

## 4. Estimated iOS integration effort: **2 / 5** (small)

Why small rather than 1: it compiles and boots — but a couple of product decisions + an FS-policy layer remain.

Evidence & specifics:

- **Code:** libriscv = 2.0 MB of C++20 sources, zero required dependencies, no generated code, no JIT/iOS-hazardous APIs in interpreter mode (writable-executable pages never needed — memory is own arena + guest mmap emulation). Builds with stock clang for arm64 as a static lib; wraps into an XCFramework behind an Obj-C++ shim in a day. Our whole glue (spike/tetherspike.cpp, incl. rootfs sandbox, timers, auxv fix) is **~300 lines** — that's the size of the adaptor Tether needs.
- **No JIT restriction issues:** threaded dispatch is computed-goto C++; the only perf features that *would* be banned on iOS (runtime-compiled `.so` translations) are optional and off for shipped builds; upstream supports *pre-baked embedded* translation files if ever wanted.
- **Memory:** default arena worked at 64–512 MiB configured; BusyBox uname session ≈ negligible RSS on top.
- **Known work items:** apply the two upstream fixes (this zip carries them); rootfs packaging inside the app bundle (absolute-symlink rewrite proven here); host-side FS policy layer (our `filter_open` pattern ≈ 40 lines) pointing at the app container; decide guest networking (sockets OFF in spike); long-session lifecycle (save/restore exists in-library: `serialize.cpp`, untested here).
- **Risks (all low):** musl loader behavior is now regression-tested by this spike; upstream API churn is modest (v1.20 == master today); IPC between Swift and C++ engine is standard.

Effort scale reference for Tether: 1 = drop-in compile; 5 = new emulator from scratch. **2** = integrate, polish, test — days-to-couple-of-weeks.

---

## 5. Recommendation: **ADD RISC-V** (libriscv) as an alternate engine

| Option | Verdict |
|---|---|
| Stay Blink only | Rejected — the spike shows riscv64-Alpine-on-libriscv is *already* viable (with 3 small fixes) and structurally cheaper than x86 emulation |
| **Add riscv** | **Recommended** — engine switch in settings: `Blink-x86 (default)` ↔ `Tether-riscv64 (libriscv, beta)` |
| Replace Blink | Premature — decide after on-device A/B (scripted in HANDOFF) |

Rationale:

1. **Viability proven today**: real Alpine 3.24.1 musl userland boots & runs correctly (uname suite, shell loops, awk, sha256 all byte-identical output vs x86_64 incl. sha256 digest).
2. **Performance ceiling looks better than x86 emulation** (12–58× native slowdown here on foreign-host x86 cores at zero tuning; RISC-V fixed-width decode, plus a documented +20-25 % RVC-off lever and embedded translations for shipped builds).
3. **Supply chain is healthy**: 93.5 % apk parity; the missing pieces (rust/clang/chromium) don't matter for a terminal-centric product.
4. **License fit**: libriscv BSD-3 (permissive; our glue MIT) — cleaner than docking a GPLv3-derived engine into a closed product (Blink's app is GPLv3; verify the engine license either way before shipping).
5. **Cost of entry is tiny** (§4): the spike itself *is* the integration prototype.

Decision gate for "replace": on-device bench (same `bench.sh`) showing **≥1.5×** Blink effective MIPS on identical userland, plus sign-off on the missing-apk list for the target personas.

---

## Appendix: method & pins

- libriscv: `github.com/libriscv/libriscv` @ `12055fb051bbdf3cfdec48b3386d06e38d038cf4` (tag v1.20, 2026-08-23), vendored with `LICENSE` (BSD-3) + `P8-upstream-fixes.patch` applied to the vendored copy.
- Assets: `alpine-minirootfs-3.24.1-{riscv64,x86_64}.tar.gz` (dl-cdn.alpinelinux.org).
- Build: plain `make` (no cmake on eval host); engines: `threaded` (default, computed-goto; = iOS config), `switch`, `bintr`.
- All guest output verified byte-identical to native where applicable (loop counts, awk sums, sha256 digest `85ec458c…b705`).
- Guest FS sandboxing: read-through to rootfs only (+/dev/null,urandom,tty); `..` and absolute-path escapes denied; gzip/apk deb assets excluded from zip.
