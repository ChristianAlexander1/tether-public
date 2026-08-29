# Engineering targets and release gates

This file records the concrete work that upgrades Tether toward a complete
Linux terminal. Every entry is a buildable target with a defined remedy, not a
permanent boundary. Per-program workarounds remain forbidden; every fix lands
at the shared platform layer. The component-by-component build plan for these
targets lives in [rework-plan/](rework-plan/).

| Target | Current evidence | Build plan |
|---|---|---|
| Nested guest execution | `termx_blink_run_nested` saves the login machine, jmp_buf and stdio; `RegistrySpawnExecutor.registerGuestFallback` runs `git` / `/bin/sh -c` as guest ELFs instead of ENOENT | keep the nested channel as the only spawn path while the login shell is busy; never call `termx_blink_run` against a live `g_machine` |
| Guest Node parity: Alpine `/usr/bin/node` runs under Darwin Blink | real `apk add nodejs npm` succeeded; `/usr/bin/node` aborted in `uv_loop_init` awaiting portable epoll semantics | implement and test portable epoll semantics in the emulator layer, then promote guest Node |
| Full `/proc` and syscall coverage under Blink | P7 harness now has 43 fixtures (offline pipeline clean-exit added); network acceptance still defines coverage | extend generic Blink/VFS behavior fixture-by-fixture; every gap closed with a regression fixture |
| Writable fakefs overlay | copy-up + whiteout + merged `readdir` + `rename` (`tether_fakefs_overlay_*`) with T5 tests; production `apk` still uses the extracted writable rootfs. `LinuxRootfsLayout` refuses to hostfs-mount a `tetherfs.idx` store | implement Blink `VfsOps` for fakefs and VfsMount it when layout is `.fakefsStore` |
| WASI toward full-process semantics | arbitrary modules, args, env, fds and cancellation work | implement additional WASI calls generically as real modules demonstrate need |
| Signed-device confirmation of signing, jetsam behavior and account OAuth | simulator build/launch and browser dispatch pass; TJIP/2 with live stdin is now the only Node lane | complete `DEVICE-PASS.md` on signed hardware (login, double-Ctrl-C Claude, jetsam) and record the result |
| Guest shell pipelines | fork-child `exit()` no longer longjmps into the parent's jmp_buf; C6 `echo hello \| cat` passed on host Blink CLI **and** on macOS embed (`TETHER_LINK_BLINK=1`, 19s) | keep both C6 lanes green |
| Interactive guest job control | done. `blink-ios-embedded-tty.patch` owns guest `/dev/tty` and the foreground process group at the Blink VFS/embed layer, shared across the fork tree; a forked guest process is given an empty signal mask, since the libdispatch worker mask it used to inherit blocked every deliverable terminal signal. Simulator acceptance: no `can't access tty` warning, Ctrl-C on `sleep 30` reports `130`, and Ctrl-Z / `jobs` / `bg` / `jobs` / `fg` / Ctrl-C reports `130` again on the same usable shell | keep the acceptance sequence in `docs/VALIDATION.md` green; any new terminal signal goes through `termx_blink_terminal_signal`, never a per-program branch |
| Bind mounts `/work` and `/workspaces` | C6 `testC6WorkspacesAndWorkBindMounts` passed on macOS embed (`TETHER_LINK_BLINK=1`, 19s): guest writes to `/workspaces/demo/native.txt` and `/work/native.txt` appeared on the host. `termx_blink_run` restores stdio so the test can drain pipes. | skip only when `bindMountsAvailable` is false |
| Guest process lifetime | done. Every guest process records itself in the fork-shared page as it starts, and teardown terminates and reaps that set by pid. An outright `SIGKILL` of the app still orphans jobs and cannot be intercepted | if a future lane spawns guest processes outside Blink's `fork()`, register them the same way rather than adding a second cleanup path |
| TJIP/2 default | v2 is the only IPC lane. Live stdin is a `tty.stdin` push; v1 (`NodeSocketServer`, `NodeSpawnBridge`, v1 shim) is deleted because it could not carry a live stdin | none — v1 must not return |

The product claim is verified continuously: ordinary Alpine software runs under
the documented Blink platform, and every newly observed failure is turned into
a fixture and fixed at the shared platform boundary, expanding real coverage
release over release.
