# Tether — Linux test harness (Blink)

A shell-based test suite that runs **real Alpine Linux userland** commands
through the [Blink](https://github.com/jart/blink) x86-64 emulator on
Linux/macOS. It proves that guest behavior — pipelines, `fork()`/`exec()`,
file I/O, and **signals** (Ctrl+C / SIGINT, SIGTERM, SIGHUP, SIGQUIT,
SIGKILL) — works correctly *before* any phone integration.

This is an isolated component: fixtures + runner + gap log only. No iOS, no
Swift app, no other teams' code.

## What it tests

42 fixtures across six categories:

| Category | Fixtures | What it proves |
|----------|----------|----------------|
| basics | 01–10 | uname, busybox, pipes, subshells, env, fork, stderr |
| signals (critical) | 11–18, 26–30, 42 | trap + host-delivered SIGINT/TERM/HUP/QUIT/KILL, interrupted pipelines, `wait`, `$?`, `kill -0`, double-fork, heredoc, apk version |
| stress | 19–23 | 10-stage pipeline, 20 concurrent forks, 10k-line stdout, `/dev/null`, live socket |
| ipc / text / fs | 31–36 | named pipes (FIFO), grep/sed/awk, sort/uniq, gzip, tar, file ops |
| process / shell | 37–41 | `set -e`, exit 127, `/proc/self`, env inheritance, append redirect |
| network | 23–25 | HTTP wget, `apk update`, `apk add git` (gated behind `NETWORK=1`) |

The signal fixtures are the heart of the harness: they start Blink in the
background, sleep long enough for the guest to reach a blocking syscall, send
a real host signal to the Blink process, and assert the guest's response
(trap fired, process terminated with the right `128+signo` status, etc.).

## Layout

```
tether-linux-harness/
├── README.md              # this file
├── SYSCALL-GAP-LOG.md     # auto-updated failures + persistent known gaps
├── fixtures/              # 42 standalone /bin/sh test scripts
├── run-all.sh             # runner: discovery, execution, PASS/FAIL, gap log
├── LICENSE                # MIT (Blink ISC / Alpine are separate)
└── HANDOFF.md             # sample output + status for the next team
```

## Prerequisites

### 1. Blink, built with VFS support

```sh
git clone --depth 1 https://github.com/jart/blink.git
cd blink
./configure --enable-vfs        # IMPORTANT: --enable-vfs gives real /dev + /proc
make -j"$(nproc)"
# binary at o//blink/blink
```

`--enable-vfs` is required. Without it, `/dev/null` is a plain regular file
from the minirootfs and background-job fixtures fail (see SYSCALL-GAP-LOG.md,
gap #1).

### 2. Alpine minirootfs (x86_64)

```sh
mkdir alpine-rootfs && cd alpine-rootfs
wget https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-3.24.1-x86_64.tar.gz
tar xzf alpine-minirootfs-3.24.1-x86_64.tar.gz
```

The harness is pinned to 3.24.1 (fixture 03 counts 82 entries in `/bin`,
which is version-specific). Any 3.24.x should work; update fixture 03's
expected count if you change versions.

For network fixtures you also need `/etc/resolv.conf` inside the rootfs; the
minirootfs ships without one. `run-all.sh` copies your host's in
automatically when `NETWORK=1`.

### macOS notes

The runner is written in portable bash (tested against bash 3.2, the version
that ships with macOS) and uses only POSIX utilities plus `find`, `grep`,
`sed`, `awk`, and `timeout`:

- If `timeout` is missing (stock macOS has no `timeout`), install it with
  `brew install coreutils` (provides `gtimeout`; symlink it as `timeout` on
  your `PATH`) or use `brew install timeout`. Without it, fixtures still run
  but a hung guest will not be hard-killed.
- Blink itself builds and runs on macOS (both Intel and Apple Silicon); the
  guest is always x86_64 Linux under Blink's JIT, so the same Alpine
  minirootfs works regardless of host architecture.

## Running

```sh
export ROOTFS=/path/to/alpine-rootfs
export BLINK_BIN=/path/to/blink/o/blink/blink   # or put `blink` on PATH

# Offline gate (39 PASS, 3 network fixtures skipped):
./run-all.sh

# Include network fixtures:
NETWORK=1 ./run-all.sh

# Show each fixture's output:
./run-all.sh --verbose

# List discovered fixtures without running:
./run-all.sh --list
```

Exit status is `0` if all run fixtures passed, `1` if any failed, `2` for
configuration errors.

### Environment variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `ROOTFS` | Path to unpacked Alpine minirootfs | _(required)_ |
| `BLINK_BIN` | Path to the blink binary | `blink` on `$PATH` |
| `NETWORK` | `1` to run network-tagged fixtures | `0` (offline) |
| `TIMEOUT_SECS` | Hard per-fixture timeout | `30` |

## Fixture format

Each fixture is a self-contained `/bin/sh` script with metadata in header
comments:

```sh
#!/bin/sh
# FIXTURE: 01_uname
# CATEGORY: basics
# EXPECT_CONTAINS: Linux        # substring that must appear in stdout+stderr
# EXPECT_EXIT: 0                # expected exit code (default 0)
# TAGS: offline                 # space-separated; "network" is gated
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/uname -a
```

The runner:

1. Parses the metadata comments.
2. Runs each fixture under a host `timeout` (hard kill on hang).
3. Captures combined stdout+stderr and the exit code.
4. Asserts `EXPECT_EXIT` and `EXPECT_CONTAINS`.
5. Skips `network`-tagged fixtures unless `NETWORK=1`.
6. Appends every failure (with an output snippet) to `SYSCALL-GAP-LOG.md`.
7. Prints `PASS: N  FAIL: M  SKIP: K`.

### Signal fixtures and the host wrapper

A guest cannot send itself a signal from "outside" — the point of the signal
tests is to prove the **host → guest** signal path. Signal fixtures therefore
run blink in the background from the host shell, sleep briefly to let the
guest block in a syscall, and `kill` the blink process:

```sh
"${BLINK_BIN:-blink}" -C "$ROOTFS" /bin/sh -c \
  'trap "echo caught" INT; sleep 2; echo slept' &
BPID=$!
sleep 0.5
kill -INT "$BPID"
wait "$BPID"
```

`run-all.sh` runs each fixture as a child process, so the host `kill` goes to
the blink process; Blink's `OnSignal` handler enqueues the signal for the
guest, which delivers it (runs the trap or terminates with the default
action). This mirrors exactly how a terminal/UI layer on a phone would send
Ctrl+C to the guest.

A 0.5 s startup delay is used; on a slow CI machine, bump it in the fixture
if you see flaky signal tests.

## Current results

- **Offline: 39 PASS, 0 FAIL, 3 SKIP.**
- **With network: 42 PASS, 0 FAIL.**

See `HANDOFF.md` for the verbatim sample output and `SYSCALL-GAP-LOG.md` for
known Blink behaviors (VFS requirement, non-interactive SIGQUIT, apk EXDEV,
missing resolv.conf, limited procfs).

## License

MIT for the harness itself. Blink is ISC; Alpine is its own set of free-software
licenses. Neither is bundled here. See `LICENSE`.
