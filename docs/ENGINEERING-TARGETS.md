# Engineering targets and release gates

This file records the concrete work that upgrades Tether toward a complete
Linux terminal. Every entry is a buildable target with a defined remedy, not a
permanent boundary. Per-program workarounds remain forbidden; every fix lands
at the shared platform layer. The component-by-component build plan for these
targets lives in [rework-plan/](rework-plan/).

| Target | Current evidence | Build plan |
|---|---|---|
| Nested guest execution: embedded Node spawns arbitrary child ELFs inside the running Blink machine | The bridge delegates every name to the generic executor; app-native commands work, guest-only commands currently return ENOENT | add a safe nested guest execution channel (second Blink machine or job-server socket into the login machine); never special-case Claude/Git |
| Guest Node parity: Alpine `/usr/bin/node` runs under Darwin Blink | real `apk add nodejs npm` succeeded; `/usr/bin/node` aborted in `uv_loop_init` awaiting portable epoll semantics | implement and test portable epoll semantics in the emulator layer, then promote guest Node |
| Full `/proc` and syscall coverage under Blink | P7's 42-fixture harness and network acceptance define reproducible coverage today | extend generic Blink/VFS behavior fixture-by-fixture; every gap closed with a regression fixture |
| Writable fakefs overlay | all six pack/read/symlink/CRC tests pass; `apk` needs a writable upper layer | design the writable upper layer and atomic metadata updates, then mount it |
| WASI toward full-process semantics | arbitrary modules, args, env, fds and cancellation work | implement additional WASI calls generically as real modules demonstrate need |
| Signed-device confirmation of signing, jetsam behavior and account OAuth | simulator build/launch and browser dispatch pass | complete `DEVICE-PASS.md` on signed hardware and record the result |
| **Guest shell pipelines segfault the forked child** | Reproduced on simulator 2026-08-25 on **both** IPC lanes, so it predates the TJIP/2 work: `echo hello \| cat` prints `hello` then `Segmentation fault`; `ls /work \| head -2` prints correct output then segfaults twice (once per pipeline stage). Output is always correct — the crash is on the child's exit path, not in the data path | fix in the Blink guest layer's fork/exit handling for pipeline stages, and add a `tether-linux-harness` fixture asserting a clean exit status for a two-stage pipeline. Do **not** paper over it in the shell |
| Flip `TETHER_IPC_V2` to the default and delete the v1 lane | v2 verified on simulator: per-fd `isTTY` from the handshake, real PTY geometry, colour depth 24, correct `[true,null]` for a piped stdout. Device matrix not yet run | complete `DEVICE-PASS.md` on the v2 lane, then make v2 the default and delete `NodeSocketServer`, `NodeSpawnBridge`, `VirtualChildPID` and the v1 shim |

The product claim is verified continuously: ordinary Alpine software runs under
the documented Blink platform, and every newly observed failure is turned into
a fixture and fixed at the shared platform boundary, expanding real coverage
release over release.
