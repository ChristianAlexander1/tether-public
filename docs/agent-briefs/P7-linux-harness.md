# Track P7 — Linux test harness

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No app repo, no iOS, no other teams' code.
2. **Do not ask** for the iOS app or other teams' code.
3. **Naming:** product is **Tether**. Folder `tether-linux-harness`. Never TermX/`termx`.
4. **Build only** the folder below.
5. **Prove everything** with `run-all.sh` — report PASS/FAIL counts in HANDOFF.md.
6. **Zip:** `tether-linux-harness-P7.zip`

---

# Your job: Linux/Alpine test harness (Blink)

## One-sentence spec
Shell-based test suite that runs **real Alpine Linux userland** commands through the [Blink](https://github.com/jart/blink) emulator on Linux/macOS — proves guest behavior (pipelines, fork, **signals**) works **before** any phone integration.

## YOUR job ONLY
Fixtures + runner + gap log. Optional thin C wrapper. **No iOS. No Swift app.**

## Why this matters
Ctrl+C, job control, and shell signals must work **inside Linux** (Blink/Alpine) — not as custom app hacks. Your tests prove the guest OS behaves correctly.

## Deliver
```
tether-linux-harness/
├── README.md              # how to get Blink + Alpine minirootfs
├── SYSCALL-GAP-LOG.md     # auto-updated failures
├── fixtures/              # 35+ scripts
├── run-all.sh
├── LICENSE
└── HANDOFF.md
```

## Fixture format
```bash
#!/bin/sh
# FIXTURE: 01_uname
# EXPECT_CONTAINS: Linux
# EXPECT_EXIT: 0
blink -r "$ROOTFS" /bin/uname -a
```

For signal tests, document how Blink is invoked (may need `timeout` wrapper on host).

## Required fixtures (minimum **35**)

### Basics (10)
| ID | Tests |
|----|-------|
| 01 | uname -a contains Linux |
| 02 | busybox echo hello |
| 03 | pipeline ls \| wc -l |
| 04 | subshell $(echo hi) |
| 05 | /etc/apk/repositories exists |
| 06 | cat /etc/alpine-release |
| 07 | sh -c 'cd /tmp && pwd' |
| 08 | export VAR=1; printenv |
| 09 | fork: sh -c 'echo child' |
| 10 | stderr redirect |

### Signals & shell (8) — **critical**
| ID | Tests |
|----|-------|
| 11 | `sh -c 'trap "echo caught" INT; sleep 2'` + send SIGINT from host wrapper |
| 12 | pipeline interrupted (document expected behavior) |
| 13 | `sleep 5 & wait` background job |
| 14 | subshell exit code `$?` |
| 15 | `kill -0 $$` self-check |
| 16 | double fork `sh -c 'sh -c echo nested'` |
| 17 | heredoc `cat <<EOF` |
| 18 | `apk --version` (no network) |

### Stress (5)
| ID | Tests |
|----|-------|
| 19 | 10-stage pipeline |
| 20 | fork 20x echo |
| 21 | large stdout 10k lines |
| 22 | open /dev/null read write |
| 23 | socket connect optional (curl if in rootfs) |

### Optional network (mark NETWORK)
| 24 | apk update |
| 25 | apk add git |
| 26 | **apk chain:** add git, then python3, then build-base in one session (script) |
| 27 | after chain: `/bin/sh -c 'git --version && python3 --version'` |

## run-all.sh
- Sets `ROOTFS` env (user path to unpacked Alpine)
- Runs each fixture
- Prints `PASS: N  FAIL: M`
- Appends failures to SYSCALL-GAP-LOG.md with stderr snippet

## HANDOFF.md
- Sample `run-all.sh` output (≥30 PASS offline)
- List fixtures requiring network separately
- SYSCALL-GAP-LOG summary

## Open source
- [jart/blink](https://github.com/jart/blink) ISC
- Alpine minirootfs x86_64 from dl-cdn.alpinelinux.org

## License: MIT
