# C6 — Linux Engine (the iSH capability, without the GPL)

**Goal:** `linux` (or transparent PATH fallthrough) gives users a real Alpine Linux
userspace — `apk add` any of ~10,000 packages, run real Linux ELF binaries — inside our
app. This is the "1000s of commands, no ceiling" guarantee.

## Why not iSH's code

iSH's emulator is GPLv2/3 — bundling it forces our whole app open-source + App Store/GPL
conflict. We don't need it: better-licensed engines exist. We copy iSH's *product idea*
(usermode emulation + Alpine + apk), not its code.

## Reuse decision

**Engine: [Blink](https://github.com/jart/blink) by Justine Tunney — ISC license
(fully permissive).** The tiniest x86-64-linux userspace emulator: ~600 x86 instructions,
~180 Linux syscalls translated to POSIX, designed to be embedded, runs static Linux
binaries on any POSIX host. Runs on ARM64. No JIT required (it has a JIT but also a pure
interpreter mode — iOS needs interpreter mode, same constraint iSH lives with).

Port work (this is a real but bounded systems task — the fun one):
1. Build Blink as a static lib for iOS ARM64 (it's dependency-free C; expect small
   patches: no `PROT_EXEC` mappings → force interpreter path; `mmap` fixed-address uses →
   Blink already has a linear-memory mode for such hosts).
2. In-process integration: one Blink instance per VirtualProcess (C2), stdio = our pty
   fds. Blink emulates fork/exec *inside* its guest — so guest shells/pipelines work
   natively within one iOS thread group. (iSH proves whole-userspace-in-one-process.)
3. Syscall surface gaps → implement as needed (Blink's syscall layer is one readable C
   file; iSH's list of what Alpine needs is public knowledge to guide priorities —
   consult behavior, not code).
4. Perf pass later: threaded interpreter dispatch; acceptable target = iSH-class speed.

**Rootfs: Alpine Linux x86_64 "minirootfs" (~3MB).** Not bundled in the app — downloaded
on first `linux` run from Alpine's CDN (user-initiated; interpreted/emulated content;
iSH ships on the App Store this way and a decade of precedent stands). Alpine packages
keep their own licenses on the user's device — we distribute none of them.

## Filesystem & integration

- Rootfs lives at `$HOME/linux/` as a plain directory tree (no disk image → files
  visible to native commands too; iSH-style).
- Emulated processes see `/` = rootfs, plus bind-style mapping: `/workspaces` and
  `$HOME` mapped through — so Linux tools operate on the same picked folder (path
  translation table in our syscall layer).
- uid 0 inside the guest (single-user, no real privileges — it's all our sandbox).
- `apk add python3 nodejs gcc make …` all work — this is the escape hatch for anything
  the native tier lacks (`node-gyp` builds, exotic tools, someone's favorite shell).
- Networking: translate guest sockets to BSD sockets 1:1 (Blink already does).

## UX

- `linux` → interactive Alpine sh in cwd-mapped directory.
- `linux <cmd…>` → one-shot.
- Shell dispatcher fallthrough (opt-in setting): command not found natively → try
  `$HOME/linux/usr/bin/<cmd>` under Blink, seamlessly.
- First-run: friendly downloader ("Setting up Linux… 3MB").

## Stretch (v2+)

- RISC-V lane: `libriscv` (BSD-3) emulating riscv64 Alpine — RISC-V is far simpler to
  emulate fast than x86; could overtake Blink as primary engine after a bake-off.
- Background completion notifications for long builds.

## Deliverable

- `TermXLinux` package: Blink xcframework + syscall/path-translation patches (upstreamable
  where possible), rootfs bootstrapper, `linux` command, dispatcher hook
- Test suite: BusyBox full applet run, `apk add` top-50 packages, pipeline stress,
  guest-fork stress
