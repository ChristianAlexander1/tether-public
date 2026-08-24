# Track P4 — Fakefs (C)

**FOR YOU:** Copy this entire file into **one** online agent chat. Nothing else.

---

# RULES — read before coding

1. **Isolated component only.** No app repo, no iOS.
2. **Do not ask** for the iOS app or other teams' code.
3. **Naming:** product is **Tether**. Headers `tether_*.h`, prefix `tether_`. Never TermX/`termx`.
4. **Build only** the C library + CLI below.
5. **All tests pass** (`ctest` or `make test`). Paste in HANDOFF.md.
6. **Zip:** `TetherFakefs-P4.zip`
7. **Clean-room** — do not copy GPL ios-linuxkit code.

---

# Your job: fakefs — pack Alpine rootfs efficiently (C)

## Context
Efficient Alpine rootfs storage for iOS. Clean-room fakefs — **do not copy GPL code** from ios-linuxkit; study behavior only.

## YOUR job ONLY
C library + CLI: tar.gz → fakefs directory; read files by path.

## DO NOT build
iOS, Blink, Swift integration (spec API only in HANDOFF).

## Deliver
```
TetherFakefs/
├── include/tether_fakefs.h
├── src/*.c
├── tools/fakefsify.c
├── tests/ + minimal test tarball (<500KB, offline)
├── CMakeLists.txt
├── LICENSE
└── HANDOFF.md
```

## CLI
`fakefsify input.tar.gz output_dir`
`fakefs_verify output_dir`

## Use libarchive (BSD-2) for tar.gz

## Tests — all pass

| ID | Test | Pass |
|----|------|------|
| T1 | Create from bundled mini tarball | exit 0 |
| T2 | Read known file bytes | match source |
| T3 | Symlink resolution | correct target |
| T4 | Verify 1000 paths | all match |

## HANDOFF.md
- On-disk format byte spec
- `ctest` or make test output
- C API for Blink VFS hook

## Zip: **`TetherFakefs-P4.zip`**

## Open source
- [libarchive](https://github.com/libarchive/libarchive) BSD-2

## License: MIT (your code)
