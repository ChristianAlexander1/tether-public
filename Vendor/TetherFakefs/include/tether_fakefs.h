/*
 * tether_fakefs.h — Tether fakefs public C API.
 *
 * fakefs packs a tar.gz rootfs (e.g. Alpine) into an on-disk store that a
 * sandboxed host (such as an iOS app) can use without needing real device
 * nodes, root-owned files, or special permissions on the host filesystem.
 * All POSIX metadata (mode, uid/gid, symlink targets, device numbers) lives
 * in a single binary index file; regular-file content lives in plain data
 * files keyed by inode number so hardlinks share storage.
 *
 * Clean-room implementation. MIT licensed. See HANDOFF.md for the byte-level
 * on-disk format specification.
 */
#ifndef TETHER_FAKEFS_H
#define TETHER_FAKEFS_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TETHER_FAKEFS_VERSION_MAJOR 1
#define TETHER_FAKEFS_VERSION_MINOR 0

/* Maximum path length fakefs will handle (bytes, incl. NUL). */
#define TETHER_FAKEFS_PATH_MAX 4096

/* Maximum symlink hops during resolution before -ELOOP. */
#define TETHER_FAKEFS_MAX_SYMLINKS 40

/*
 * All functions return 0 (or a non-negative count) on success and a
 * negative errno value on failure (e.g. -ENOENT, -EINVAL, -ELOOP, -EIO).
 */

/* ------------------------------------------------------------------ */
/* Creation                                                            */
/* ------------------------------------------------------------------ */

/*
 * Unpack `tarball_path` (a .tar.gz; any libarchive-readable tar works)
 * into a fakefs store at `out_dir`. `out_dir` is created if missing.
 * The index is written atomically (temp file + rename), so a crash
 * mid-create never leaves a store that opens successfully.
 *
 * On error, if `errbuf` is non-NULL a human-readable message is written
 * into it (truncated to errlen).
 */
int tether_fakefs_create(const char *tarball_path,
                         const char *out_dir,
                         char *errbuf, size_t errlen);

/* ------------------------------------------------------------------ */
/* Opening / closing                                                   */
/* ------------------------------------------------------------------ */

typedef struct tether_fakefs tether_fakefs;

/*
 * Open an existing fakefs store. Returns NULL on failure; if `errbuf`
 * is non-NULL a message is written into it. The handle is immutable
 * and safe for concurrent readers on distinct threads.
 */
tether_fakefs *tether_fakefs_open(const char *dir,
                                  char *errbuf, size_t errlen);

void tether_fakefs_close(tether_fakefs *fs);

/* ------------------------------------------------------------------ */
/* Metadata                                                            */
/* ------------------------------------------------------------------ */

typedef struct tether_fakefs_stat {
    uint32_t mode;   /* full st_mode: type bits | permission bits       */
    uint32_t uid;
    uint32_t gid;
    uint64_t size;   /* content size for regular files, else 0          */
    int64_t  mtime;  /* seconds since epoch                             */
    uint64_t rdev;   /* device number for char/block nodes, else 0      */
    uint32_t inode;  /* data-file id; UINT32_MAX when no content stored */
    uint32_t nlink;  /* number of index entries sharing this inode      */
} tether_fakefs_stat;

/*
 * lstat semantics: does NOT follow a trailing symlink.
 * `path` is interpreted relative to the fakefs root; a leading '/' is
 * accepted and ignored ("/bin/sh" == "bin/sh").
 */
int tether_fakefs_stat_path(const tether_fakefs *fs, const char *path,
                            tether_fakefs_stat *st);

/* stat semantics: follows symlinks (up to TETHER_FAKEFS_MAX_SYMLINKS). */
int tether_fakefs_stat_follow(const tether_fakefs *fs, const char *path,
                              tether_fakefs_stat *st);

/*
 * Read a symlink's target into buf (NUL-terminated).
 * Returns the target length in bytes on success, -EINVAL if `path`
 * is not a symlink.
 */
int tether_fakefs_readlink(const tether_fakefs *fs, const char *path,
                           char *buf, size_t buflen);

/*
 * Resolve `path` following all intermediate and trailing symlinks to a
 * canonical store-relative path (no leading '/'). `resolved` receives
 * the result. Returns 0 on success, -ELOOP on symlink cycles, -ENOENT
 * if the final target does not exist.
 */
int tether_fakefs_resolve(const tether_fakefs *fs, const char *path,
                          char *resolved, size_t resolvedlen);

/* ------------------------------------------------------------------ */
/* Content                                                             */
/* ------------------------------------------------------------------ */

/*
 * Read up to `len` bytes of a regular file at byte `offset`.
 * Follows symlinks. Returns the number of bytes read (0 at EOF),
 * or a negative errno (-EISDIR for directories, -EINVAL for special
 * files, -ENOENT, ...).
 */
ssize_t tether_fakefs_read(const tether_fakefs *fs, const char *path,
                           void *buf, size_t len, uint64_t offset);

/*
 * Open the underlying host data file for a regular file, O_RDONLY.
 * Follows symlinks. Returns a real host fd (caller closes) so a VFS
 * layer can mmap or stream content with zero copies. Negative errno
 * on failure.
 */
int tether_fakefs_open_fd(const tether_fakefs *fs, const char *path);

/* ------------------------------------------------------------------ */
/* Enumeration (for VFS readdir hooks)                                 */
/* ------------------------------------------------------------------ */

/* Total number of entries in the index. */
uint32_t tether_fakefs_count(const tether_fakefs *fs);

/*
 * Fetch entry `idx` (0-based, sorted by path). `*path_out` points at
 * memory owned by the handle (valid until close). `st` may be NULL.
 */
int tether_fakefs_entry_at(const tether_fakefs *fs, uint32_t idx,
                           const char **path_out, tether_fakefs_stat *st);

/*
 * Enumerate the immediate children of directory `dirpath` ("" or "/"
 * for the root). `name` passed to the callback is the child's basename;
 * `full` is its full store-relative path. Return non-zero from the
 * callback to stop early. Returns number of children visited, or
 * negative errno.
 */
typedef int (*tether_fakefs_dirent_cb)(const char *name, const char *full,
                                       const tether_fakefs_stat *st,
                                       void *user);
int tether_fakefs_readdir(const tether_fakefs *fs, const char *dirpath,
                          tether_fakefs_dirent_cb cb, void *user);

/* ------------------------------------------------------------------ */
/* Integrity                                                           */
/* ------------------------------------------------------------------ */

/*
 * Verify the whole store: every regular file's data file must exist and
 * match the recorded size and CRC-32. Returns 0 if fully valid, a
 * positive count of corrupt/missing entries otherwise, or a negative
 * errno on I/O failure. If `report` is non-NULL it is invoked once per
 * problem with a description.
 */
typedef void (*tether_fakefs_report_cb)(const char *path, const char *problem,
                                        void *user);
int tether_fakefs_verify(const tether_fakefs *fs,
                         tether_fakefs_report_cb report, void *user);

/* ------------------------------------------------------------------ */
/* Writable overlay (copy-up + whiteouts)                              */
/* ------------------------------------------------------------------ */

/*
 * A read-write view of a fakefs store. The lower store stays immutable;
 * every mutation lands in `upper_dir` as a regular host tree. Overlayfs
 * whiteouts (`.wh.<basename>`) hide lower entries. Reads prefer upper,
 * then lower, and fail with -ENOENT when a whiteout is present.
 *
 * This is the writable layer `apk` and guest installs need when the
 * production extracted rootfs is not in use.
 */
typedef struct tether_fakefs_rw tether_fakefs_rw;

tether_fakefs_rw *tether_fakefs_overlay_open(const char *lower_dir,
                                             const char *upper_dir,
                                             char *errbuf, size_t errlen);
void tether_fakefs_overlay_close(tether_fakefs_rw *rw);

int tether_fakefs_overlay_stat(const tether_fakefs_rw *rw, const char *path,
                               tether_fakefs_stat *st);
ssize_t tether_fakefs_overlay_read(const tether_fakefs_rw *rw, const char *path,
                                   void *buf, size_t len, uint64_t offset);
ssize_t tether_fakefs_overlay_write(tether_fakefs_rw *rw, const char *path,
                                    const void *buf, size_t len, uint64_t offset);
int tether_fakefs_overlay_mkdir(tether_fakefs_rw *rw, const char *path, uint32_t mode);
int tether_fakefs_overlay_unlink(tether_fakefs_rw *rw, const char *path);
int tether_fakefs_overlay_create(tether_fakefs_rw *rw, const char *path,
                                 uint32_t mode);
int tether_fakefs_overlay_rename(tether_fakefs_rw *rw, const char *from,
                                 const char *to);
int tether_fakefs_overlay_readdir(const tether_fakefs_rw *rw, const char *dirpath,
                                  tether_fakefs_dirent_cb cb, void *user);
int tether_fakefs_overlay_open_fd(tether_fakefs_rw *rw, const char *path,
                                  int flags);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* TETHER_FAKEFS_H */
