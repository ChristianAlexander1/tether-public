# Architectural boundaries and release gates

This file records concrete engineering boundaries. It is not permission to add
per-program workarounds.

| Boundary | Current evidence | Correct remedy |
|---|---|---|
| Embedded Node cannot synchronously enter the already-running Blink machine for an arbitrary child ELF | The bridge now delegates every name to the generic executor; app-native commands work, unknown guest-only commands return ENOENT | add a safe nested guest execution channel or broaden a real native command tier; never special-case Claude/Git |
| Alpine Node aborts under Darwin Blink because libuv expects Linux epoll behavior | real `apk add nodejs npm` succeeded; `/usr/bin/node` aborted in `uv_loop_init` | implement/test portable epoll semantics in the selected emulator before choosing guest Node |
| Blink exposes a subset of Linux `/proc` and syscalls | P7’s 42-fixture harness and network acceptance define reproducible coverage | add generic Blink/VFS behavior with a regression fixture |
| fakefs is immutable | all six pack/read/symlink/CRC tests pass; `apk` requires writes | design a writable upper layer and atomic metadata updates before mounting it |
| WASI is capability-scoped, not a full Linux process | arbitrary modules, args, env, fds and cancellation work | implement missing WASI calls generically when a real module demonstrates need |
| Physical-device signing, jetsam behavior and account OAuth are not simulator facts | simulator build/launch and browser dispatch pass | complete `DEVICE-PASS.md` on signed hardware and record the result |

The product should not claim universal Linux syscall compatibility. It should
claim—and continuously verify—that ordinary Alpine software runs under the
documented Blink platform, while failures are fixed at the shared platform
boundary.
