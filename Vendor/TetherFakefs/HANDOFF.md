# HANDOFF — Tether fakefs (Track P4)

**Component:** `tether_fakefs` — C library + CLI that packs an Alpine (or any)
rootfs `tar.gz` into an efficient on-disk store and reads files back by path.

**License:** MIT (this code). Depends on **libarchive** (BSD-2-Clause),
linked as a system library — no libarchive source is vendored.

**Clean-room statement:** this is an original implementation. No GPL
`ios-linuxkit` code was consulted or copied; only the *behavioral* idea
("store POSIX metadata out-of-band so a sandboxed host filesystem can hold a
Linux rootfs") was used as a requirement.

---

## 1. Why fakefs

iOS app containers cannot hold a faithful Linux rootfs directly: no device
nodes, no root-owned files, no arbitrary uid/gid/mode bits, case-insensitive
by default, and symlinks are awkward to manage. fakefs sidesteps all of that:

* **All POSIX metadata** (type, mode, uid, gid, mtime, symlink target, device
  numbers) lives in a single binary index file, `tetherfs.idx`.
* **Regular-file content** lives in flat, plain `0644` data files named by an
  inode number — nothing special is required of the host filesystem.
* **Hardlinks** are free: multiple index entries reference the same inode, so
  content is stored once (Alpine minirootfs: 517 entries → 87 data files).
* The index is **sorted and immutable**, so lookup is a binary search, the
  whole index can be mapped/loaded once, and concurrent readers need no locks.

## 2. Store layout

```
output_dir/
├── tetherfs.idx        # binary index (spec below)
└── data/
    ├── 00000000        # content of inode 0 (lowercase hex, 8 digits)
    ├── 00000001
    └── ...
```

## 3. On-disk format — byte spec (`tetherfs.idx`)

All integers **little-endian**. All structures naturally aligned; the file is
exactly `header + entry_count*56 + strtab_size` bytes.

### 3.1 Header — 40 bytes at offset 0

| Offset | Size | Field         | Meaning                                        |
|-------:|-----:|---------------|------------------------------------------------|
| 0      | 8    | `magic`       | ASCII `TFAKEFS1` (no NUL)                       |
| 8      | 4    | `version`     | `1`                                             |
| 12     | 4    | `entry_count` | number of entry records                         |
| 16     | 8    | `strtab_off`  | byte offset of string table (== 40 + 56·count)  |
| 24     | 8    | `strtab_size` | string table size in bytes (≥ 1)                |
| 32     | 8    | `inode_count` | number of data files ever allocated             |

### 3.2 Entry records — 56 bytes each, `entry_count` of them at offset 40

Sorted **ascending by path** (bytewise `strcmp`), paths unique.

| Offset | Size | Field      | Meaning                                                        |
|-------:|-----:|------------|----------------------------------------------------------------|
| 0      | 4    | `path_off` | strtab offset of NUL-terminated store-relative path (no leading `/`, e.g. `bin/busybox`) |
| 4      | 4    | `link_off` | strtab offset of symlink target (raw, may be absolute), or `0xFFFFFFFF` if not a symlink |
| 8      | 4    | `mode`     | full `st_mode`: `S_IFREG/S_IFDIR/S_IFLNK/S_IFCHR/S_IFBLK/S_IFIFO/S_IFSOCK` \| permission bits (incl. setuid/setgid/sticky) |
| 12     | 4    | `uid`      | owner uid                                                       |
| 16     | 4    | `gid`      | owner gid                                                       |
| 20     | 4    | `inode`    | data file id → `data/%08x`; `0xFFFFFFFF` when no content is stored (dirs, links, devices) |
| 24     | 8    | `size`     | content size in bytes (regular files), else 0                   |
| 32     | 8    | `rdev`     | device number for char/block nodes, else 0                      |
| 40     | 8    | `mtime`    | signed seconds since Unix epoch                                 |
| 48     | 4    | `crc32`    | CRC-32 (IEEE 802.3, poly `0xEDB88320`, init/xor `0xFFFFFFFF`) of content; 0 otherwise |
| 52     | 4    | `reserved` | must be 0                                                       |

### 3.3 String table

At `strtab_off`, `strtab_size` bytes of concatenated NUL-terminated strings.
Byte 0 is always `\0` (so offset 0 is the empty string). Last byte is `\0`.

### 3.4 Semantics & invariants

* **Paths** are normalized at pack time: leading `/` and `./` stripped,
  `//` collapsed, `.`/`..` resolved lexically (with `..` clamped at the
  root — a hostile `../../x` member packs as `x`, never escaping the store).
* **Hardlinks** in the tar become independent entries sharing the target's
  `inode`, `size`, `crc32` and `mode`. `nlink` is derived, not stored.
* **Duplicate tar members** (same path twice): the later one wins, matching
  tar extraction semantics.
* **Implicit directories** (paths that only exist as prefixes of other
  entries) are synthesized at read time as `S_IFDIR | 0755`.
* The index is written to `tetherfs.idx.tmp`, `fsync`ed, then `rename`d —
  a crash mid-pack never yields a store that opens successfully.
* Readers validate magic, version, layout arithmetic, string-table
  termination, offset bounds, and sort order before trusting anything.

## 4. CLI

```
fakefsify input.tar.gz output_dir    # pack; exit 0 on success
fakefs_verify output_dir             # full size+CRC audit; exit 0 if valid
```

Any libarchive-readable tar compression works (gz, plain, xz, zstd …).

## 5. Build & test

```
cmake -S . -B build
cmake --build build -j
ctest --test-dir build --output-on-failure
```

Requires: CMake ≥ 3.16, a C11 compiler, libarchive dev package
(`libarchive-dev` / `libarchive` in Homebrew / `LibArchive` in the iOS
toolchain later — creation-side only; the *reader* has **zero** dependencies
beyond libc, which is what Blink will link).

Tests are fully offline; the bundled fixture
`tests/data/mini_rootfs.tar.gz` is **9,969 bytes** (< 500 KB) and contains
directories, known-byte files (incl. NUL/0xFF/UTF-8 bytes), a hardlink,
relative + absolute symlinks, a symlink cycle, char/block device nodes, and
1000 payload files. `tests/gen_tarball.py` regenerates it deterministically.

### Test matrix → requirement mapping

| ID | Requirement                         | Test binary                       |
|----|-------------------------------------|-----------------------------------|
| T1 | Create from bundled mini tarball, exit 0 | `t1_create` + `t1_cli_fakefsify` |
| T2 | Read known file bytes == source     | `t2_read`                         |
| T3 | Symlink resolution, correct target  | `t3_symlink`                      |
| T4 | Verify 1000 paths, all match        | `t4_verify` + `t4_cli_verify`     |

### `ctest` output (this checkout)

```
Test project /home/user/TetherFakefs/build
    Start 1: t1_create
1/6 Test #1: t1_create ........................   Passed    0.04 sec
    Start 2: t2_read
2/6 Test #2: t2_read ..........................   Passed    0.04 sec
    Start 3: t3_symlink
3/6 Test #3: t3_symlink .......................   Passed    0.04 sec
    Start 4: t4_verify
4/6 Test #4: t4_verify ........................   Passed    0.05 sec
    Start 5: t1_cli_fakefsify
5/6 Test #5: t1_cli_fakefsify .................   Passed    0.04 sec
    Start 6: t4_cli_verify
6/6 Test #6: t4_cli_verify ....................   Passed    0.01 sec

100% tests passed, 0 tests failed out of 6

Total Test time (real) =   0.20 sec
```

### Real-world sanity check (not part of the suite; needs network)

Against `alpine-minirootfs-3.20.3-x86_64.tar.gz` (3.4 MB):
`fakefsify` → `OK — 517 entries`, `fakefs_verify` → `OK — 517 entries
verified`; `etc/os-release` reads back byte-exact and `bin/sh` resolves
through the busybox symlink to a valid ELF.

## 6. C API for the Blink VFS hook (spec only — no Swift/iOS here)

Everything Blink's VFS layer needs is in `include/tether_fakefs.h`. The
handle is immutable after `open`, so it is safe to share across reader
threads with no locking. All calls return `0`/count on success, negative
`errno` on failure — map them 1:1 to VFS error returns.

```c
tether_fakefs *fs = tether_fakefs_open(store_dir, err, sizeof err);

/* VFS op            → fakefs call                                     */
/* lstat(path)       */ tether_fakefs_stat_path(fs, path, &st);
/* stat(path)        */ tether_fakefs_stat_follow(fs, path, &st);
/* readlink(path)    */ tether_fakefs_readlink(fs, path, buf, len);
/* realpath(path)    */ tether_fakefs_resolve(fs, path, out, len);
/* pread(path)       */ tether_fakefs_read(fs, path, buf, len, offset);
/* open(path,O_RDONLY): get a REAL host fd onto the backing data file — 
   mmap it, dup it, hand it to a spawned process, zero-copy:           */
                        int fd = tether_fakefs_open_fd(fs, path);
/* readdir(dir)      */ tether_fakefs_readdir(fs, dir, cb, user);
/* fsck              */ tether_fakefs_verify(fs, report_cb, user);

tether_fakefs_close(fs);
```

Notes for the integrator:

* Paths may be given with or without a leading `/`; both address the fakefs
  root. `""` and `"/"` are the root directory.
* `tether_fakefs_stat` carries `mode/uid/gid/size/mtime/rdev/inode/nlink` —
  enough to fabricate a full `struct stat` (use `inode` as `st_ino`; entries
  without content have `inode == UINT32_MAX`, substitute the entry index).
* Symlink resolution is fully contained inside the store: absolute targets
  restart at the fakefs root, `..` cannot escape it, cycles return `-ELOOP`
  after 40 hops. The host filesystem is never consulted for path logic.
* The reader never writes; store mutation (apk installs etc.) is a later
  track — the format's `reserved` field and `version` header leave room.
* Creation (`tether_fakefs_create`) is the only part that needs libarchive.
  If Blink only ever *opens* stores shipped from elsewhere, link just
  `tether_fakefs.c`, `tether_path.c`, `tether_crc32.c` — libc-only.

## 7. File inventory

```
TetherFakefs/
├── include/tether_fakefs.h        public API (creation + reader)
├── src/tether_fakefs.c            reader: open/stat/resolve/read/readdir/verify
├── src/tether_fakefs_create.c     packer: tar.gz → store (libarchive)
├── src/tether_path.c              lexical path normalization
├── src/tether_crc32.c             CRC-32 (IEEE)
├── src/tether_internal.h          on-disk structs (matches §3 spec)
├── tools/fakefsify.c              CLI packer
├── tools/fakefs_verify.c          CLI verifier
├── tests/test_create.c            T1
├── tests/test_read.c              T2
├── tests/test_symlink.c           T3
├── tests/test_verify.c            T4 (+ corruption-detection proof)
├── tests/test_common.h            shared fixture helpers
├── tests/gen_tarball.py           regenerates the fixture deterministically
├── tests/data/mini_rootfs.tar.gz  offline fixture, 9,969 bytes
├── CMakeLists.txt
├── LICENSE                        MIT + libarchive BSD-2 notice
└── HANDOFF.md                     this file
```
