/*
 * tether_wasi.c — reentrant wasi_snapshot_preview1 subset for the Tether runner
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Every host function reaches its state through _ctx->userdata, so no globals
 * are involved and independent runs may execute concurrently. Guest
 * descriptors are indices into a per-run table rather than raw host
 * descriptors, which keeps the guest from naming a host fd the caller never
 * handed it, and path lookups are confined to the directories the caller
 * preopened.
 */

#define _GNU_SOURCE

#include "tether_wasi.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

/* The ABI layouts this file writes into guest memory must match the spec
 * exactly; catch any drift at compile time. */
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(TW_FILESTAT_SIZE == 64, "wasi filestat_t is 64 bytes");
_Static_assert(TW_FDSTAT_SIZE == 24,   "wasi fdstat_t is 24 bytes");
_Static_assert(TW_PRESTAT_SIZE == 8,   "wasi prestat_t is 8 bytes");
_Static_assert(TW_IOVEC_SIZE == 8,     "wasi iovec_t is 8 bytes");
_Static_assert(TW_DIRENT_SIZE == 24,   "wasi dirent_t is 24 bytes");
#endif

/*
 * Accessors for guest linear memory.
 *
 * A guest may hand us any offset it likes, so a pointer into linear memory can
 * be arbitrarily aligned — dereferencing it as a uint32_t* is undefined
 * behaviour and faults outright on strict-alignment targets. wasm3's own
 * m3ApiWriteMem* macros do exactly that, so the runner uses these byte-wise
 * helpers instead. They also fix the byte order: wasm memory is little-endian
 * regardless of the host.
 */

static inline void tw_store_u8(void *p, uint8_t v)
{
    ((uint8_t *)p)[0] = v;
}

static inline void tw_store_u16(void *p, uint16_t v)
{
    uint8_t *b = (uint8_t *)p;
    b[0] = (uint8_t)(v);
    b[1] = (uint8_t)(v >> 8);
}

static inline void tw_store_u32(void *p, uint32_t v)
{
    uint8_t *b = (uint8_t *)p;
    b[0] = (uint8_t)(v);
    b[1] = (uint8_t)(v >> 8);
    b[2] = (uint8_t)(v >> 16);
    b[3] = (uint8_t)(v >> 24);
}

static inline void tw_store_u64(void *p, uint64_t v)
{
    uint8_t *b = (uint8_t *)p;
    for (int i = 0; i < 8; ++i) b[i] = (uint8_t)(v >> (8 * i));
}

static inline uint16_t tw_load_u16(const void *p)
{
    const uint8_t *b = (const uint8_t *)p;
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

static inline uint32_t tw_load_u32(const void *p)
{
    const uint8_t *b = (const uint8_t *)p;
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
           ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static inline uint64_t tw_load_u64(const void *p)
{
    const uint8_t *b = (const uint8_t *)p;
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= (uint64_t)b[i] << (8 * i);
    return v;
}

#define TW_INITIAL_FDS      64
#define TW_MAX_FDS          4096
#define TW_PATH_MAX         4096
#define TW_MAX_IOVS         1024

/* Rights granted to a preopened directory and everything reached through it.
 * The runner does not enforce rights beyond what the host filesystem already
 * enforces; they are advertised so wasi-libc takes its normal code paths. */
#define TW_DIR_RIGHTS       (UINT64_C(0x00000000001fffff))
#define TW_FILE_RIGHTS      (UINT64_C(0x00000000001fffff))

/* ------------------------------------------------------------------ */
/* errno translation                                                    */
/* ------------------------------------------------------------------ */

static tw_errno_t tw_errno_from_host(int e)
{
    switch (e) {
    case 0:              return TW_ERRNO_SUCCESS;
    case EPERM:          return TW_ERRNO_PERM;
    case ENOENT:         return TW_ERRNO_NOENT;
    case EINTR:          return TW_ERRNO_INTR;
    case EIO:            return TW_ERRNO_IO;
    case ENXIO:          return TW_ERRNO_NXIO;
    case E2BIG:          return TW_ERRNO_2BIG;
    case ENOEXEC:        return TW_ERRNO_NOEXEC;
    case EBADF:          return TW_ERRNO_BADF;
    case EAGAIN:         return TW_ERRNO_AGAIN;
    case ENOMEM:         return TW_ERRNO_NOMEM;
    case EACCES:         return TW_ERRNO_ACCES;
    case EFAULT:         return TW_ERRNO_FAULT;
    case EBUSY:          return TW_ERRNO_BUSY;
    case EEXIST:         return TW_ERRNO_EXIST;
    case EXDEV:          return TW_ERRNO_XDEV;
    case ENODEV:         return TW_ERRNO_NODEV;
    case ENOTDIR:        return TW_ERRNO_NOTDIR;
    case EISDIR:         return TW_ERRNO_ISDIR;
    case EINVAL:         return TW_ERRNO_INVAL;
    case ENFILE:         return TW_ERRNO_NFILE;
    case EMFILE:         return TW_ERRNO_MFILE;
    case ENOTTY:         return TW_ERRNO_NOTTY;
    case ETXTBSY:        return TW_ERRNO_TXTBSY;
    case EFBIG:          return TW_ERRNO_FBIG;
    case ENOSPC:         return TW_ERRNO_NOSPC;
    case ESPIPE:         return TW_ERRNO_SPIPE;
    case EROFS:          return TW_ERRNO_ROFS;
    case EMLINK:         return TW_ERRNO_MLINK;
    case EPIPE:          return TW_ERRNO_PIPE;
    case ERANGE:         return TW_ERRNO_RANGE;
    case ENAMETOOLONG:   return TW_ERRNO_NAMETOOLONG;
    case ENOTEMPTY:      return TW_ERRNO_NOTEMPTY;
    case ELOOP:          return TW_ERRNO_LOOP;
    case EOVERFLOW:      return TW_ERRNO_OVERFLOW;
    case ENOSYS:         return TW_ERRNO_NOSYS;
#if defined(EOPNOTSUPP)
    case EOPNOTSUPP:     return TW_ERRNO_NOTSUP;
#endif
#if defined(ENOTSUP) && (!defined(EOPNOTSUPP) || ENOTSUP != EOPNOTSUPP)
    case ENOTSUP:        return TW_ERRNO_NOTSUP;
#endif
    case EDEADLK:        return TW_ERRNO_DEADLK;
    default:             return TW_ERRNO_IO;
    }
}

static tw_filetype_t tw_filetype_from_mode(mode_t mode)
{
    if (S_ISREG(mode))  return TW_FILETYPE_REGULAR_FILE;
    if (S_ISDIR(mode))  return TW_FILETYPE_DIRECTORY;
    if (S_ISCHR(mode))  return TW_FILETYPE_CHARACTER_DEVICE;
    if (S_ISBLK(mode))  return TW_FILETYPE_BLOCK_DEVICE;
    if (S_ISLNK(mode))  return TW_FILETYPE_SYMBOLIC_LINK;
#ifdef S_ISFIFO
    if (S_ISFIFO(mode)) return TW_FILETYPE_CHARACTER_DEVICE;
#endif
#ifdef S_ISSOCK
    if (S_ISSOCK(mode)) return TW_FILETYPE_SOCKET_STREAM;
#endif
    return TW_FILETYPE_UNKNOWN;
}

/* ------------------------------------------------------------------ */
/* descriptor table                                                     */
/* ------------------------------------------------------------------ */

static tw_fd_entry *tw_fd_get(tether_wasi *w, uint32_t fd)
{
    if (fd >= w->fd_count) return NULL;
    if (!w->fds[fd].in_use) return NULL;
    return &w->fds[fd];
}

static bool tw_fds_grow(tether_wasi *w, uint32_t needed)
{
    if (needed <= w->fd_count) return true;
    if (needed > TW_MAX_FDS) return false;

    uint32_t next = w->fd_count ? w->fd_count : TW_INITIAL_FDS;
    while (next < needed) next *= 2;
    if (next > TW_MAX_FDS) next = TW_MAX_FDS;

    tw_fd_entry *grown = (tw_fd_entry *)realloc(w->fds, next * sizeof(*grown));
    if (!grown) return false;

    memset(grown + w->fd_count, 0, (next - w->fd_count) * sizeof(*grown));
    for (uint32_t i = w->fd_count; i < next; ++i) grown[i].host_fd = -1;

    w->fds = grown;
    w->fd_count = next;
    return true;
}

/* Installs `host_fd` at the lowest free guest descriptor, as POSIX open would. */
static int tw_fd_alloc(tether_wasi *w, int host_fd, bool owned,
                       tw_filetype_t type, tw_rights_t base, tw_rights_t inheriting)
{
    uint32_t slot = 0;
    while (slot < w->fd_count && w->fds[slot].in_use) slot++;
    if (slot >= w->fd_count && !tw_fds_grow(w, slot + 1)) return -1;

    tw_fd_entry *e = &w->fds[slot];
    memset(e, 0, sizeof(*e));
    e->host_fd = host_fd;
    e->in_use = true;
    e->owned = owned;
    e->filetype = type;
    e->rights_base = base;
    e->rights_inheriting = inheriting;
    return (int)slot;
}

static void tw_fd_release(tw_fd_entry *e)
{
    if (!e->in_use) return;
    if (e->dir) {
        /* closedir also closes the descriptor it was built from. */
        closedir(e->dir);
        e->dir = NULL;
        e->host_fd = -1;
    } else if (e->owned && e->host_fd >= 0) {
        close(e->host_fd);
    }
    free(e->guest_path);
    memset(e, 0, sizeof(*e));
    e->host_fd = -1;
}

/* ------------------------------------------------------------------ */
/* construction                                                         */
/* ------------------------------------------------------------------ */

static bool tw_install_std(tether_wasi *w, uint32_t slot, int host_fd)
{
    tw_fd_entry *e = &w->fds[slot];
    memset(e, 0, sizeof(*e));
    e->in_use = true;
    e->owned = false;

    if (host_fd < 0) {
        /* No descriptor supplied: reads hit EOF, writes are discarded. This
         * keeps a guest that writes to a closed stdout from dying on EPIPE. */
        e->host_fd = -1;
        e->is_null = true;
        e->filetype = TW_FILETYPE_CHARACTER_DEVICE;
    } else {
        struct stat st;
        e->host_fd = host_fd;
        e->filetype = (fstat(host_fd, &st) == 0)
                        ? tw_filetype_from_mode(st.st_mode)
                        : TW_FILETYPE_CHARACTER_DEVICE;
    }
    e->rights_base = TW_FILE_RIGHTS;
    e->rights_inheriting = TW_FILE_RIGHTS;
    return true;
}

static bool tw_add_preopen(tether_wasi *w, const char *guest_path, const char *host_path,
                           const char **error)
{
    int dfd = open(host_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) {
        if (error) *error = "cannot open directory to preopen";
        return false;
    }

    int slot = tw_fd_alloc(w, dfd, true, TW_FILETYPE_DIRECTORY,
                           TW_DIR_RIGHTS, TW_DIR_RIGHTS);
    if (slot < 0) {
        close(dfd);
        if (error) *error = "descriptor table full";
        return false;
    }

    char *name = strdup(guest_path);
    if (!name) {
        tw_fd_release(&w->fds[slot]);
        if (error) *error = "out of memory";
        return false;
    }
    w->fds[slot].guest_path = name;
    w->fds[slot].is_preopen = true;
    return true;
}

tether_wasi *tether_wasi_new(const char *cwd,
                             int stdin_fd, int stdout_fd, int stderr_fd,
                             char *const argv[], int argc,
                             char *const envp[],
                             const char *const *guest_dirs,
                             const char *const *host_dirs,
                             const char **error)
{
    tether_wasi *w = (tether_wasi *)calloc(1, sizeof(*w));
    if (!w) {
        if (error) *error = "out of memory";
        return NULL;
    }

    if (!tw_fds_grow(w, TW_INITIAL_FDS)) {
        free(w);
        if (error) *error = "out of memory";
        return NULL;
    }

    tw_install_std(w, 0, stdin_fd);
    tw_install_std(w, 1, stdout_fd);
    tw_install_std(w, 2, stderr_fd);

    const char *dir = (cwd && *cwd) ? cwd : ".";

    /* wasi-libc resolves a relative path against the preopen whose name is the
     * longest prefix of it, so "." covers relative paths and "/" lets an
     * absolute path land in the same directory. */
    if (!tw_add_preopen(w, ".", dir, error)) { tether_wasi_free(w); return NULL; }
    if (!tw_add_preopen(w, "/", dir, error)) { tether_wasi_free(w); return NULL; }

    if (guest_dirs && host_dirs) {
        for (size_t i = 0; guest_dirs[i] && host_dirs[i]; ++i) {
            if (!tw_add_preopen(w, guest_dirs[i], host_dirs[i], error)) {
                tether_wasi_free(w);
                return NULL;
            }
        }
    }

    w->argv = argv;
    w->argc = (argc > 0) ? (uint32_t)argc : 0;
    w->envp = envp;
    w->envc = 0;
    if (envp) while (envp[w->envc]) w->envc++;

    return w;
}

void tether_wasi_free(tether_wasi *w)
{
    if (!w) return;
    for (uint32_t i = 0; i < w->fd_count; ++i) tw_fd_release(&w->fds[i]);
    free(w->fds);
    free(w);
}

/* ------------------------------------------------------------------ */
/* helpers shared by the host functions                                 */
/* ------------------------------------------------------------------ */

#define TW_CTX() tether_wasi *wasi = (tether_wasi *)(_ctx->userdata); \
                 if (!wasi) m3ApiReturn(TW_ERRNO_INVAL);

/* Copies a guest iovec array into host iovecs, bounds-checking every buffer
 * against linear memory. Returns a wasi errno, or TW_ERRNO_SUCCESS. */
static tw_errno_t tw_collect_iovs(IM3Runtime runtime, void *_mem,
                                  const uint8_t *guest_iovs, uint32_t iovs_len,
                                  struct iovec *out, size_t *out_total)
{
    uint64_t mem_size = m3_GetMemorySize(runtime);
    size_t total = 0;

    for (uint32_t i = 0; i < iovs_len; ++i) {
        const uint8_t *slot = guest_iovs + (size_t)i * TW_IOVEC_SIZE;
        uint32_t buf = tw_load_u32(slot + TW_IOVEC_OFF_BUF);
        uint32_t len = tw_load_u32(slot + TW_IOVEC_OFF_BUF_LEN);

        if ((uint64_t)buf + (uint64_t)len > mem_size) return TW_ERRNO_FAULT;

        out[i].iov_base = (uint8_t *)_mem + buf;
        out[i].iov_len = len;
        total += len;
    }
    *out_total = total;
    return TW_ERRNO_SUCCESS;
}

/*
 * Rejects a guest path that would escape its preopened directory.
 *
 * Absolute paths and any prefix that walks above the root with ".." are
 * refused outright; the surviving relative path is resolved with openat
 * against the preopen descriptor. Symlinks inside the directory are followed
 * by the host and can in principle point outside it, which matches the
 * behaviour of other lightweight WASI hosts — callers that need a hard
 * boundary should preopen a directory they control.
 */
static bool tw_path_is_contained(const char *path)
{
    if (!path || !*path) return false;
    if (path[0] == '/') return false;

    int depth = 0;
    const char *p = path;
    while (*p) {
        const char *slash = strchr(p, '/');
        size_t seg_len = slash ? (size_t)(slash - p) : strlen(p);

        if (seg_len == 2 && p[0] == '.' && p[1] == '.') {
            if (--depth < 0) return false;
        } else if (seg_len != 0 && !(seg_len == 1 && p[0] == '.')) {
            depth++;
        }

        if (!slash) break;
        p = slash + 1;
    }
    return true;
}

/* Copies a guest string into a NUL-terminated host buffer. */
static tw_errno_t tw_copy_path(const char *guest, uint32_t len, char *out, size_t out_size)
{
    if (len >= out_size) return TW_ERRNO_NAMETOOLONG;
    memcpy(out, guest, len);
    out[len] = '\0';
    if (memchr(out, '\0', len) != NULL) return TW_ERRNO_INVAL;
    return TW_ERRNO_SUCCESS;
}

static void tw_write_filestat(uint8_t *dst, const struct stat *st)
{
    uint64_t dev      = (uint64_t)st->st_dev;
    uint64_t ino      = (uint64_t)st->st_ino;
    uint64_t nlink    = (uint64_t)st->st_nlink;
    uint64_t size     = (uint64_t)st->st_size;
    uint8_t  filetype = tw_filetype_from_mode(st->st_mode);

#if defined(__APPLE__)
    uint64_t atim = (uint64_t)st->st_atimespec.tv_sec * 1000000000ull + (uint64_t)st->st_atimespec.tv_nsec;
    uint64_t mtim = (uint64_t)st->st_mtimespec.tv_sec * 1000000000ull + (uint64_t)st->st_mtimespec.tv_nsec;
    uint64_t ctim = (uint64_t)st->st_ctimespec.tv_sec * 1000000000ull + (uint64_t)st->st_ctimespec.tv_nsec;
#else
    uint64_t atim = (uint64_t)st->st_atim.tv_sec * 1000000000ull + (uint64_t)st->st_atim.tv_nsec;
    uint64_t mtim = (uint64_t)st->st_mtim.tv_sec * 1000000000ull + (uint64_t)st->st_mtim.tv_nsec;
    uint64_t ctim = (uint64_t)st->st_ctim.tv_sec * 1000000000ull + (uint64_t)st->st_ctim.tv_nsec;
#endif

    memset(dst, 0, TW_FILESTAT_SIZE);
    tw_store_u64(dst + TW_FILESTAT_OFF_DEV,      dev);
    tw_store_u64(dst + TW_FILESTAT_OFF_INO,      ino);
    tw_store_u8 (dst + TW_FILESTAT_OFF_FILETYPE, filetype);
    tw_store_u64(dst + TW_FILESTAT_OFF_NLINK,    nlink);
    tw_store_u64(dst + TW_FILESTAT_OFF_SIZE,     size);
    tw_store_u64(dst + TW_FILESTAT_OFF_ATIM,     atim);
    tw_store_u64(dst + TW_FILESTAT_OFF_MTIM,     mtim);
    tw_store_u64(dst + TW_FILESTAT_OFF_CTIM,     ctim);
}

/* ------------------------------------------------------------------ */
/* args and environ                                                     */
/* ------------------------------------------------------------------ */

static m3ApiRawFunction(tw_args_sizes_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArgMem  (uint32_t *, argc_out)
    m3ApiGetArgMem  (uint32_t *, argv_buf_size_out)
    TW_CTX()

    m3ApiCheckMem(argc_out, 4);
    m3ApiCheckMem(argv_buf_size_out, 4);

    uint32_t total = 0;
    for (uint32_t i = 0; i < wasi->argc; ++i) total += (uint32_t)strlen(wasi->argv[i]) + 1;

    tw_store_u32(argc_out, wasi->argc);
    tw_store_u32(argv_buf_size_out, total);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_args_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArgMem  (uint32_t *, argv_out)
    m3ApiGetArgMem  (char *,     argv_buf)
    TW_CTX()

    m3ApiCheckMem(argv_out, (uint64_t)wasi->argc * 4);

    char *cursor = argv_buf;
    for (uint32_t i = 0; i < wasi->argc; ++i) {
        size_t len = strlen(wasi->argv[i]) + 1;
        m3ApiCheckMem(cursor, len);
        tw_store_u32(&argv_out[i], m3ApiPtrToOffset(cursor));
        memcpy(cursor, wasi->argv[i], len);
        cursor += len;
    }
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_environ_sizes_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArgMem  (uint32_t *, envc_out)
    m3ApiGetArgMem  (uint32_t *, env_buf_size_out)
    TW_CTX()

    m3ApiCheckMem(envc_out, 4);
    m3ApiCheckMem(env_buf_size_out, 4);

    uint32_t total = 0;
    for (uint32_t i = 0; i < wasi->envc; ++i) total += (uint32_t)strlen(wasi->envp[i]) + 1;

    tw_store_u32(envc_out, wasi->envc);
    tw_store_u32(env_buf_size_out, total);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_environ_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArgMem  (uint32_t *, env_out)
    m3ApiGetArgMem  (char *,     env_buf)
    TW_CTX()

    m3ApiCheckMem(env_out, (uint64_t)wasi->envc * 4);

    char *cursor = env_buf;
    for (uint32_t i = 0; i < wasi->envc; ++i) {
        size_t len = strlen(wasi->envp[i]) + 1;
        m3ApiCheckMem(cursor, len);
        tw_store_u32(&env_out[i], m3ApiPtrToOffset(cursor));
        memcpy(cursor, wasi->envp[i], len);
        cursor += len;
    }
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

/* ------------------------------------------------------------------ */
/* streams                                                              */
/* ------------------------------------------------------------------ */

static m3ApiRawFunction(tw_fd_read)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t,  fd)
    m3ApiGetArgMem  (uint8_t *, iovs)
    m3ApiGetArg     (uint32_t,  iovs_len)
    m3ApiGetArgMem  (uint32_t *, nread_out)
    TW_CTX()

    m3ApiCheckMem(nread_out, 4);
    if (iovs_len > TW_MAX_IOVS) m3ApiReturn(TW_ERRNO_INVAL);
    m3ApiCheckMem(iovs, (uint64_t)iovs_len * TW_IOVEC_SIZE);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);

    if (e->is_null) {                    /* no stdin supplied: immediate EOF */
        tw_store_u32(nread_out, 0);
        m3ApiReturn(TW_ERRNO_SUCCESS);
    }
    if (e->host_fd < 0) m3ApiReturn(TW_ERRNO_BADF);
    if (iovs_len == 0) { tw_store_u32(nread_out, 0); m3ApiReturn(TW_ERRNO_SUCCESS); }

    struct iovec vec[TW_MAX_IOVS];
    size_t total = 0;
    tw_errno_t err = tw_collect_iovs(runtime, _mem, iovs, iovs_len, vec, &total);
    if (err != TW_ERRNO_SUCCESS) m3ApiReturn(err);

    ssize_t got;
    do { got = readv(e->host_fd, vec, (int)iovs_len); } while (got < 0 && errno == EINTR);
    if (got < 0) m3ApiReturn(tw_errno_from_host(errno));

    tw_store_u32(nread_out, (uint32_t)got);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_write)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t,  fd)
    m3ApiGetArgMem  (uint8_t *, iovs)
    m3ApiGetArg     (uint32_t,  iovs_len)
    m3ApiGetArgMem  (uint32_t *, nwritten_out)
    TW_CTX()

    m3ApiCheckMem(nwritten_out, 4);
    if (iovs_len > TW_MAX_IOVS) m3ApiReturn(TW_ERRNO_INVAL);
    m3ApiCheckMem(iovs, (uint64_t)iovs_len * TW_IOVEC_SIZE);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);

    struct iovec vec[TW_MAX_IOVS];
    size_t total = 0;
    if (iovs_len > 0) {
        tw_errno_t err = tw_collect_iovs(runtime, _mem, iovs, iovs_len, vec, &total);
        if (err != TW_ERRNO_SUCCESS) m3ApiReturn(err);
    }

    if (e->is_null) {                    /* discard, but report full progress */
        tw_store_u32(nwritten_out, (uint32_t)total);
        m3ApiReturn(TW_ERRNO_SUCCESS);
    }
    if (e->host_fd < 0) m3ApiReturn(TW_ERRNO_BADF);
    if (iovs_len == 0) { tw_store_u32(nwritten_out, 0); m3ApiReturn(TW_ERRNO_SUCCESS); }

    /* Loop so a short writev still delivers everything the guest asked for. */
    size_t written = 0;
    int idx = 0;
    while ((size_t)idx < iovs_len) {
        ssize_t n;
        do { n = writev(e->host_fd, vec + idx, (int)(iovs_len - idx)); }
        while (n < 0 && errno == EINTR);

        if (n < 0) {
            if (written > 0) break;      /* partial success is still success */
            m3ApiReturn(tw_errno_from_host(errno));
        }
        if (n == 0) break;

        written += (size_t)n;
        size_t remaining = (size_t)n;
        while ((size_t)idx < iovs_len && remaining >= vec[idx].iov_len) {
            remaining -= vec[idx].iov_len;
            idx++;
        }
        if (remaining > 0 && (size_t)idx < iovs_len) {
            vec[idx].iov_base = (uint8_t *)vec[idx].iov_base + remaining;
            vec[idx].iov_len -= remaining;
        }
    }

    tw_store_u32(nwritten_out, (uint32_t)written);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_close)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    TW_CTX()

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);

    tw_fd_release(e);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_seek)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArg     (int64_t,  offset)
    m3ApiGetArg     (uint32_t, whence)
    m3ApiGetArgMem  (uint64_t *, newoffset_out)
    TW_CTX()

    m3ApiCheckMem(newoffset_out, 8);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);
    if (e->is_null || e->host_fd < 0) m3ApiReturn(TW_ERRNO_SPIPE);

    int host_whence;
    switch (whence) {
    case TW_WHENCE_SET: host_whence = SEEK_SET; break;
    case TW_WHENCE_CUR: host_whence = SEEK_CUR; break;
    case TW_WHENCE_END: host_whence = SEEK_END; break;
    default: m3ApiReturn(TW_ERRNO_INVAL);
    }

    off_t pos = lseek(e->host_fd, (off_t)offset, host_whence);
    if (pos < 0) m3ApiReturn(tw_errno_from_host(errno));

    tw_store_u64(newoffset_out, (uint64_t)pos);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_tell)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArgMem  (uint64_t *, offset_out)
    TW_CTX()

    m3ApiCheckMem(offset_out, 8);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);
    if (e->is_null || e->host_fd < 0) m3ApiReturn(TW_ERRNO_SPIPE);

    off_t pos = lseek(e->host_fd, 0, SEEK_CUR);
    if (pos < 0) m3ApiReturn(tw_errno_from_host(errno));

    tw_store_u64(offset_out, (uint64_t)pos);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_fdstat_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArgMem  (uint8_t *, buf)
    TW_CTX()

    m3ApiCheckMem(buf, TW_FDSTAT_SIZE);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);

    uint16_t fs_flags = 0;
    if (!e->is_null && e->host_fd >= 0) {
        int fl = fcntl(e->host_fd, F_GETFL);
        if (fl >= 0) {
            if (fl & O_APPEND)   fs_flags |= TW_FDFLAGS_APPEND;
            if (fl & O_NONBLOCK) fs_flags |= TW_FDFLAGS_NONBLOCK;
#ifdef O_DSYNC
            if (fl & O_DSYNC)    fs_flags |= TW_FDFLAGS_DSYNC;
#endif
#ifdef O_SYNC
            if (fl & O_SYNC)     fs_flags |= TW_FDFLAGS_SYNC;
#endif
        }
    }

    memset(buf, 0, TW_FDSTAT_SIZE);
    buf[TW_FDSTAT_OFF_FILETYPE] = e->filetype;
    tw_store_u16(buf + TW_FDSTAT_OFF_FLAGS, fs_flags);
    tw_store_u64(buf + TW_FDSTAT_OFF_RIGHTS_BASE, e->rights_base);
    tw_store_u64(buf + TW_FDSTAT_OFF_RIGHTS_INHERITING, e->rights_inheriting);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_fdstat_set_flags)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArg     (uint32_t, flags)
    TW_CTX()

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);
    if (e->is_null || e->host_fd < 0) m3ApiReturn(TW_ERRNO_SUCCESS);

    int fl = fcntl(e->host_fd, F_GETFL);
    if (fl < 0) m3ApiReturn(tw_errno_from_host(errno));

    fl &= ~(O_APPEND | O_NONBLOCK);
    if (flags & TW_FDFLAGS_APPEND)   fl |= O_APPEND;
    if (flags & TW_FDFLAGS_NONBLOCK) fl |= O_NONBLOCK;

    if (fcntl(e->host_fd, F_SETFL, fl) < 0) m3ApiReturn(tw_errno_from_host(errno));
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_filestat_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArgMem  (uint8_t *, buf)
    TW_CTX()

    m3ApiCheckMem(buf, TW_FILESTAT_SIZE);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);

    if (e->is_null || e->host_fd < 0) {
        memset(buf, 0, TW_FILESTAT_SIZE);
        buf[TW_FILESTAT_OFF_FILETYPE] = TW_FILETYPE_CHARACTER_DEVICE;
        m3ApiReturn(TW_ERRNO_SUCCESS);
    }

    struct stat st;
    if (fstat(e->host_fd, &st) < 0) m3ApiReturn(tw_errno_from_host(errno));

    tw_write_filestat(buf, &st);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_sync)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    TW_CTX()

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);
    if (e->is_null || e->host_fd < 0) m3ApiReturn(TW_ERRNO_SUCCESS);
    if (fsync(e->host_fd) < 0) m3ApiReturn(tw_errno_from_host(errno));
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_datasync)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    TW_CTX()

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);
    if (e->is_null || e->host_fd < 0) m3ApiReturn(TW_ERRNO_SUCCESS);
#if defined(__APPLE__)
    if (fsync(e->host_fd) < 0) m3ApiReturn(tw_errno_from_host(errno));
#else
    if (fdatasync(e->host_fd) < 0) m3ApiReturn(tw_errno_from_host(errno));
#endif
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

/* ------------------------------------------------------------------ */
/* preopens                                                             */
/* ------------------------------------------------------------------ */

static m3ApiRawFunction(tw_fd_prestat_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArgMem  (uint8_t *, buf)
    TW_CTX()

    m3ApiCheckMem(buf, TW_PRESTAT_SIZE);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    /* BADF here is how wasi-libc learns it has enumerated every preopen. */
    if (!e || !e->is_preopen || !e->guest_path) m3ApiReturn(TW_ERRNO_BADF);

    memset(buf, 0, TW_PRESTAT_SIZE);
    buf[TW_PRESTAT_OFF_TYPE] = TW_PREOPENTYPE_DIR;
    tw_store_u32(buf + TW_PRESTAT_OFF_NAME_LEN, (uint32_t)strlen(e->guest_path));
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_prestat_dir_name)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArgMem  (char *,   path)
    m3ApiGetArg     (uint32_t, path_len)
    TW_CTX()

    m3ApiCheckMem(path, path_len);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e || !e->is_preopen || !e->guest_path) m3ApiReturn(TW_ERRNO_BADF);

    size_t len = strlen(e->guest_path);
    if (path_len < len) m3ApiReturn(TW_ERRNO_NAMETOOLONG);

    memcpy(path, e->guest_path, len);
    if (path_len > len) path[len] = '\0';
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

/* ------------------------------------------------------------------ */
/* paths                                                                */
/* ------------------------------------------------------------------ */

static m3ApiRawFunction(tw_path_open)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, dirfd)
    m3ApiGetArg     (uint32_t, dirflags)
    m3ApiGetArgMem  (const char *, path)
    m3ApiGetArg     (uint32_t, path_len)
    m3ApiGetArg     (uint32_t, oflags)
    m3ApiGetArg     (uint64_t, fs_rights_base)
    m3ApiGetArg     (uint64_t, fs_rights_inheriting)
    m3ApiGetArg     (uint32_t, fdflags)
    m3ApiGetArgMem  (uint32_t *, fd_out)
    TW_CTX()

    m3ApiCheckMem(path, path_len);
    m3ApiCheckMem(fd_out, 4);

    tw_fd_entry *dir = tw_fd_get(wasi, dirfd);
    if (!dir) m3ApiReturn(TW_ERRNO_BADF);
    if (dir->filetype != TW_FILETYPE_DIRECTORY) m3ApiReturn(TW_ERRNO_NOTDIR);

    char host_path[TW_PATH_MAX];
    tw_errno_t perr = tw_copy_path(path, path_len, host_path, sizeof(host_path));
    if (perr != TW_ERRNO_SUCCESS) m3ApiReturn(perr);

    /* Guests reach a preopen's own root as "." — allow it, refuse escapes. */
    if (!tw_path_is_contained(host_path)) m3ApiReturn(TW_ERRNO_NOTCAPABLE);

    int flags = O_CLOEXEC;
    if (oflags & TW_OFLAGS_CREAT)     flags |= O_CREAT;
    if (oflags & TW_OFLAGS_EXCL)      flags |= O_EXCL;
    if (oflags & TW_OFLAGS_TRUNC)     flags |= O_TRUNC;
    if (oflags & TW_OFLAGS_DIRECTORY) flags |= O_DIRECTORY;

    if (fdflags & TW_FDFLAGS_APPEND)   flags |= O_APPEND;
    if (fdflags & TW_FDFLAGS_NONBLOCK) flags |= O_NONBLOCK;
#ifdef O_DSYNC
    if (fdflags & TW_FDFLAGS_DSYNC)    flags |= O_DSYNC;
#endif
#ifdef O_SYNC
    if (fdflags & TW_FDFLAGS_SYNC)     flags |= O_SYNC;
#endif
    if (!(dirflags & TW_LOOKUPFLAGS_SYMLINK_FOLLOW)) flags |= O_NOFOLLOW;

    bool want_read  = (fs_rights_base & TW_RIGHTS_FD_READ) != 0;
    bool want_write = (fs_rights_base & TW_RIGHTS_FD_WRITE) != 0;
    if (want_read && want_write)      flags |= O_RDWR;
    else if (want_write)              flags |= O_WRONLY;
    else                              flags |= O_RDONLY;

    /* A directory can only be opened read-only. */
    if (flags & O_DIRECTORY) flags = (flags & ~(O_RDWR | O_WRONLY)) | O_RDONLY;

    int host_fd = openat(dir->host_fd, host_path, flags, 0644);
    if (host_fd < 0) m3ApiReturn(tw_errno_from_host(errno));

    struct stat st;
    tw_filetype_t type = TW_FILETYPE_UNKNOWN;
    if (fstat(host_fd, &st) == 0) type = tw_filetype_from_mode(st.st_mode);

    int slot = tw_fd_alloc(wasi, host_fd, true, type,
                           fs_rights_base ? fs_rights_base : TW_FILE_RIGHTS,
                           fs_rights_inheriting);
    if (slot < 0) {
        close(host_fd);
        m3ApiReturn(TW_ERRNO_MFILE);
    }

    tw_store_u32(fd_out, (uint32_t)slot);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_path_filestat_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, dirfd)
    m3ApiGetArg     (uint32_t, flags)
    m3ApiGetArgMem  (const char *, path)
    m3ApiGetArg     (uint32_t, path_len)
    m3ApiGetArgMem  (uint8_t *, buf)
    TW_CTX()

    m3ApiCheckMem(path, path_len);
    m3ApiCheckMem(buf, TW_FILESTAT_SIZE);

    tw_fd_entry *dir = tw_fd_get(wasi, dirfd);
    if (!dir) m3ApiReturn(TW_ERRNO_BADF);
    if (dir->filetype != TW_FILETYPE_DIRECTORY) m3ApiReturn(TW_ERRNO_NOTDIR);

    char host_path[TW_PATH_MAX];
    tw_errno_t perr = tw_copy_path(path, path_len, host_path, sizeof(host_path));
    if (perr != TW_ERRNO_SUCCESS) m3ApiReturn(perr);
    if (!tw_path_is_contained(host_path)) m3ApiReturn(TW_ERRNO_NOTCAPABLE);

    int at_flags = (flags & TW_LOOKUPFLAGS_SYMLINK_FOLLOW) ? 0 : AT_SYMLINK_NOFOLLOW;

    struct stat st;
    if (fstatat(dir->host_fd, host_path, &st, at_flags) < 0)
        m3ApiReturn(tw_errno_from_host(errno));

    tw_write_filestat(buf, &st);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_path_create_directory)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, dirfd)
    m3ApiGetArgMem  (const char *, path)
    m3ApiGetArg     (uint32_t, path_len)
    TW_CTX()

    m3ApiCheckMem(path, path_len);

    tw_fd_entry *dir = tw_fd_get(wasi, dirfd);
    if (!dir) m3ApiReturn(TW_ERRNO_BADF);

    char host_path[TW_PATH_MAX];
    tw_errno_t perr = tw_copy_path(path, path_len, host_path, sizeof(host_path));
    if (perr != TW_ERRNO_SUCCESS) m3ApiReturn(perr);
    if (!tw_path_is_contained(host_path)) m3ApiReturn(TW_ERRNO_NOTCAPABLE);

    if (mkdirat(dir->host_fd, host_path, 0755) < 0) m3ApiReturn(tw_errno_from_host(errno));
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_path_unlink_file)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, dirfd)
    m3ApiGetArgMem  (const char *, path)
    m3ApiGetArg     (uint32_t, path_len)
    TW_CTX()

    m3ApiCheckMem(path, path_len);

    tw_fd_entry *dir = tw_fd_get(wasi, dirfd);
    if (!dir) m3ApiReturn(TW_ERRNO_BADF);

    char host_path[TW_PATH_MAX];
    tw_errno_t perr = tw_copy_path(path, path_len, host_path, sizeof(host_path));
    if (perr != TW_ERRNO_SUCCESS) m3ApiReturn(perr);
    if (!tw_path_is_contained(host_path)) m3ApiReturn(TW_ERRNO_NOTCAPABLE);

    if (unlinkat(dir->host_fd, host_path, 0) < 0) m3ApiReturn(tw_errno_from_host(errno));
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_path_remove_directory)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, dirfd)
    m3ApiGetArgMem  (const char *, path)
    m3ApiGetArg     (uint32_t, path_len)
    TW_CTX()

    m3ApiCheckMem(path, path_len);

    tw_fd_entry *dir = tw_fd_get(wasi, dirfd);
    if (!dir) m3ApiReturn(TW_ERRNO_BADF);

    char host_path[TW_PATH_MAX];
    tw_errno_t perr = tw_copy_path(path, path_len, host_path, sizeof(host_path));
    if (perr != TW_ERRNO_SUCCESS) m3ApiReturn(perr);
    if (!tw_path_is_contained(host_path)) m3ApiReturn(TW_ERRNO_NOTCAPABLE);

    if (unlinkat(dir->host_fd, host_path, AT_REMOVEDIR) < 0)
        m3ApiReturn(tw_errno_from_host(errno));
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_path_rename)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, old_dirfd)
    m3ApiGetArgMem  (const char *, old_path)
    m3ApiGetArg     (uint32_t, old_path_len)
    m3ApiGetArg     (uint32_t, new_dirfd)
    m3ApiGetArgMem  (const char *, new_path)
    m3ApiGetArg     (uint32_t, new_path_len)
    TW_CTX()

    m3ApiCheckMem(old_path, old_path_len);
    m3ApiCheckMem(new_path, new_path_len);

    tw_fd_entry *old_dir = tw_fd_get(wasi, old_dirfd);
    tw_fd_entry *new_dir = tw_fd_get(wasi, new_dirfd);
    if (!old_dir || !new_dir) m3ApiReturn(TW_ERRNO_BADF);

    char old_host[TW_PATH_MAX], new_host[TW_PATH_MAX];
    tw_errno_t perr = tw_copy_path(old_path, old_path_len, old_host, sizeof(old_host));
    if (perr != TW_ERRNO_SUCCESS) m3ApiReturn(perr);
    perr = tw_copy_path(new_path, new_path_len, new_host, sizeof(new_host));
    if (perr != TW_ERRNO_SUCCESS) m3ApiReturn(perr);

    if (!tw_path_is_contained(old_host) || !tw_path_is_contained(new_host))
        m3ApiReturn(TW_ERRNO_NOTCAPABLE);

    if (renameat(old_dir->host_fd, old_host, new_dir->host_fd, new_host) < 0)
        m3ApiReturn(tw_errno_from_host(errno));
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_fd_readdir)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, fd)
    m3ApiGetArgMem  (uint8_t *, buf)
    m3ApiGetArg     (uint32_t, buf_len)
    m3ApiGetArg     (uint64_t, cookie)
    m3ApiGetArgMem  (uint32_t *, bufused_out)
    TW_CTX()

    m3ApiCheckMem(buf, buf_len);
    m3ApiCheckMem(bufused_out, 4);

    tw_fd_entry *e = tw_fd_get(wasi, fd);
    if (!e) m3ApiReturn(TW_ERRNO_BADF);
    if (e->filetype != TW_FILETYPE_DIRECTORY) m3ApiReturn(TW_ERRNO_NOTDIR);

    if (!e->dir) {
        /* fdopendir takes ownership of the descriptor. */
        int dup_fd = dup(e->host_fd);
        if (dup_fd < 0) m3ApiReturn(tw_errno_from_host(errno));
        e->dir = fdopendir(dup_fd);
        if (!e->dir) { close(dup_fd); m3ApiReturn(tw_errno_from_host(errno)); }
    }

    if (cookie == 0) rewinddir(e->dir);
    else seekdir(e->dir, (long)cookie);

    uint32_t used = 0;
    for (;;) {
        errno = 0;
        struct dirent *de = readdir(e->dir);
        if (!de) {
            if (errno != 0) m3ApiReturn(tw_errno_from_host(errno));
            break;                       /* end of directory */
        }

        size_t namlen = strlen(de->d_name);
        uint64_t next = (uint64_t)telldir(e->dir);
        uint64_t ino = (uint64_t)de->d_ino;
        uint32_t nl = (uint32_t)namlen;

        uint8_t type;
        switch (de->d_type) {
        case DT_REG:  type = TW_FILETYPE_REGULAR_FILE;     break;
        case DT_DIR:  type = TW_FILETYPE_DIRECTORY;        break;
        case DT_LNK:  type = TW_FILETYPE_SYMBOLIC_LINK;    break;
        case DT_CHR:  type = TW_FILETYPE_CHARACTER_DEVICE; break;
        case DT_BLK:  type = TW_FILETYPE_BLOCK_DEVICE;     break;
        default:      type = TW_FILETYPE_UNKNOWN;          break;
        }

        /* A truncated entry still counts: the guest retries with a bigger
         * buffer once it sees bufused == buf_len. */
        uint8_t hdr[TW_DIRENT_SIZE];
        memset(hdr, 0, sizeof(hdr));
        tw_store_u64(hdr + TW_DIRENT_OFF_NEXT,   next);
        tw_store_u64(hdr + TW_DIRENT_OFF_INO,    ino);
        tw_store_u32(hdr + TW_DIRENT_OFF_NAMLEN, nl);
        hdr[TW_DIRENT_OFF_TYPE] = type;

        uint32_t hdr_copy = (buf_len - used < TW_DIRENT_SIZE) ? (buf_len - used) : TW_DIRENT_SIZE;
        memcpy(buf + used, hdr, hdr_copy);
        used += hdr_copy;
        if (used >= buf_len) break;

        uint32_t name_copy = (buf_len - used < namlen) ? (buf_len - used) : (uint32_t)namlen;
        memcpy(buf + used, de->d_name, name_copy);
        used += name_copy;
        if (used >= buf_len) break;
    }

    tw_store_u32(bufused_out, used);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

/* ------------------------------------------------------------------ */
/* clocks, randomness, scheduling                                       */
/* ------------------------------------------------------------------ */

static bool tw_host_clock(uint32_t id, clockid_t *out)
{
    switch (id) {
    case TW_CLOCKID_REALTIME:            *out = CLOCK_REALTIME;           return true;
    case TW_CLOCKID_MONOTONIC:           *out = CLOCK_MONOTONIC;          return true;
#if defined(CLOCK_PROCESS_CPUTIME_ID)
    case TW_CLOCKID_PROCESS_CPUTIME_ID:  *out = CLOCK_PROCESS_CPUTIME_ID; return true;
#endif
#if defined(CLOCK_THREAD_CPUTIME_ID)
    case TW_CLOCKID_THREAD_CPUTIME_ID:   *out = CLOCK_THREAD_CPUTIME_ID;  return true;
#endif
    default: return false;
    }
}

static m3ApiRawFunction(tw_clock_time_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, id)
    m3ApiGetArg     (uint64_t, precision)
    m3ApiGetArgMem  (uint64_t *, time_out)
    (void)precision;

    m3ApiCheckMem(time_out, 8);

    clockid_t host_id;
    if (!tw_host_clock(id, &host_id)) m3ApiReturn(TW_ERRNO_INVAL);

    struct timespec ts;
    if (clock_gettime(host_id, &ts) < 0) m3ApiReturn(tw_errno_from_host(errno));

    tw_store_u64(time_out, (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_clock_res_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, id)
    m3ApiGetArgMem  (uint64_t *, res_out)

    m3ApiCheckMem(res_out, 8);

    clockid_t host_id;
    if (!tw_host_clock(id, &host_id)) m3ApiReturn(TW_ERRNO_INVAL);

    struct timespec ts;
    if (clock_getres(host_id, &ts) < 0) m3ApiReturn(tw_errno_from_host(errno));

    tw_store_u64(res_out, (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_random_get)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArgMem  (uint8_t *, buf)
    m3ApiGetArg     (uint32_t, buf_len)

    m3ApiCheckMem(buf, buf_len);
    if (buf_len == 0) m3ApiReturn(TW_ERRNO_SUCCESS);

    /* /dev/urandom is the portable floor here; getrandom and getentropy are
     * not available everywhere the runner is meant to build. */
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) m3ApiReturn(tw_errno_from_host(errno));

    uint32_t got = 0;
    while (got < buf_len) {
        ssize_t n = read(fd, buf + got, buf_len - got);
        if (n < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            close(fd);
            m3ApiReturn(tw_errno_from_host(saved));
        }
        if (n == 0) break;
        got += (uint32_t)n;
    }
    close(fd);

    if (got < buf_len) m3ApiReturn(TW_ERRNO_IO);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

static m3ApiRawFunction(tw_sched_yield)
{
    m3ApiReturnType (uint32_t)
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

/*
 * poll_oneoff: only the clock subscriptions a sleep() turns into are honoured.
 * Descriptor readiness is reported as immediately ready, which is correct for
 * the blocking descriptors a command-line tool sees and keeps a guest from
 * hanging on a wait the runner cannot actually perform.
 */
static m3ApiRawFunction(tw_poll_oneoff)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArgMem  (const uint8_t *, in)
    m3ApiGetArgMem  (uint8_t *, out)
    m3ApiGetArg     (uint32_t, nsubscriptions)
    m3ApiGetArgMem  (uint32_t *, nevents_out)

    m3ApiCheckMem(nevents_out, 4);
    if (nsubscriptions == 0) m3ApiReturn(TW_ERRNO_INVAL);
    m3ApiCheckMem(in,  (uint64_t)nsubscriptions * TW_SUBSCRIPTION_SIZE);
    m3ApiCheckMem(out, (uint64_t)nsubscriptions * TW_EVENT_SIZE);

    uint32_t produced = 0;
    uint64_t sleep_ns = 0;
    bool have_sleep = false;

    for (uint32_t i = 0; i < nsubscriptions; ++i) {
        const uint8_t *sub = in + (size_t)i * TW_SUBSCRIPTION_SIZE;
        uint64_t userdata = tw_load_u64(sub + TW_SUB_OFF_USERDATA);
        uint8_t tag = sub[TW_SUB_OFF_TAG];

        uint8_t *ev = out + (size_t)produced * TW_EVENT_SIZE;
        memset(ev, 0, TW_EVENT_SIZE);
        tw_store_u64(ev + TW_EVENT_OFF_USERDATA, userdata);
        ev[TW_EVENT_OFF_TYPE] = tag;

        if (tag == TW_EVENTTYPE_CLOCK) {
            uint32_t clock_id  = tw_load_u32(sub + TW_SUB_CLOCK_OFF_ID);
            uint64_t timeout   = tw_load_u64(sub + TW_SUB_CLOCK_OFF_TIMEOUT);
            uint16_t sub_flags = tw_load_u16(sub + TW_SUB_CLOCK_OFF_FLAGS);

            uint64_t delay = timeout;
            if (sub_flags & TW_SUBCLOCKFLAGS_ABSTIME) {
                clockid_t host_id;
                struct timespec now;
                if (tw_host_clock(clock_id, &host_id) && clock_gettime(host_id, &now) == 0) {
                    uint64_t now_ns = (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
                    delay = (timeout > now_ns) ? (timeout - now_ns) : 0;
                } else {
                    delay = 0;
                }
            }
            if (!have_sleep || delay < sleep_ns) { sleep_ns = delay; have_sleep = true; }
            produced++;
        } else if (tag == TW_EVENTTYPE_FD_READ || tag == TW_EVENTTYPE_FD_WRITE) {
            tw_store_u64(ev + TW_EVENT_OFF_FD_NBYTES, 1);
            produced++;
        } else {
            tw_store_u16(ev + TW_EVENT_OFF_ERROR, TW_ERRNO_INVAL);
            produced++;
        }
    }

    if (have_sleep && sleep_ns > 0) {
        struct timespec req = {
            .tv_sec  = (time_t)(sleep_ns / 1000000000ull),
            .tv_nsec = (long)(sleep_ns % 1000000000ull)
        };
        while (nanosleep(&req, &req) < 0 && errno == EINTR) { }
    }

    tw_store_u32(nevents_out, produced);
    m3ApiReturn(TW_ERRNO_SUCCESS);
}

/* ------------------------------------------------------------------ */
/* process exit                                                         */
/* ------------------------------------------------------------------ */

/*
 * proc_exit records the status and traps. wasm3 unwinds the interpreter with
 * m3Err_trapExit, which the runner recognises as an orderly exit rather than a
 * fault — this is the only way to stop a running module from a host call.
 */
static m3ApiRawFunction(tw_proc_exit)
{
    m3ApiGetArg(uint32_t, code)

    tether_wasi *wasi = (tether_wasi *)(_ctx->userdata);
    if (wasi) {
        wasi->exited = true;
        wasi->exit_code = (int)(code & 0xff);
    }
    m3ApiTrap(m3Err_trapExit);
}

static m3ApiRawFunction(tw_proc_raise)
{
    m3ApiReturnType (uint32_t)
    m3ApiGetArg     (uint32_t, sig)
    (void)sig;
    m3ApiReturn(TW_ERRNO_NOTSUP);
}

/* ------------------------------------------------------------------ */
/* linking                                                              */
/* ------------------------------------------------------------------ */

/* An import the guest never calls must not fail the load, so a missing-import
 * result from wasm3 is swallowed here and surfaces later only if the guest
 * actually reaches that function. */
static M3Result tw_allow_missing(M3Result r)
{
    return (r == m3Err_functionLookupFailed) ? m3Err_none : r;
}

typedef struct tw_import {
    const char *name;
    const char *signature;
    M3RawCall   fn;
} tw_import;

static const tw_import k_imports[] = {
    { "args_get",               "i(**)",         &tw_args_get },
    { "args_sizes_get",         "i(**)",         &tw_args_sizes_get },
    { "environ_get",            "i(**)",         &tw_environ_get },
    { "environ_sizes_get",      "i(**)",         &tw_environ_sizes_get },

    { "fd_read",                "i(i*i*)",       &tw_fd_read },
    { "fd_write",               "i(i*i*)",       &tw_fd_write },
    { "fd_close",               "i(i)",          &tw_fd_close },
    { "fd_seek",                "i(iIi*)",       &tw_fd_seek },
    { "fd_tell",                "i(i*)",         &tw_fd_tell },
    { "fd_fdstat_get",          "i(i*)",         &tw_fd_fdstat_get },
    { "fd_fdstat_set_flags",    "i(ii)",         &tw_fd_fdstat_set_flags },
    { "fd_filestat_get",        "i(i*)",         &tw_fd_filestat_get },
    { "fd_sync",                "i(i)",          &tw_fd_sync },
    { "fd_datasync",            "i(i)",          &tw_fd_datasync },
    { "fd_readdir",             "i(i*iI*)",      &tw_fd_readdir },
    { "fd_prestat_get",         "i(i*)",         &tw_fd_prestat_get },
    { "fd_prestat_dir_name",    "i(i*i)",        &tw_fd_prestat_dir_name },

    { "path_open",              "i(ii*iiIIi*)",  &tw_path_open },
    { "path_filestat_get",      "i(ii*i*)",      &tw_path_filestat_get },
    { "path_create_directory",  "i(i*i)",        &tw_path_create_directory },
    { "path_remove_directory",  "i(i*i)",        &tw_path_remove_directory },
    { "path_unlink_file",       "i(i*i)",        &tw_path_unlink_file },
    { "path_rename",            "i(i*ii*i)",     &tw_path_rename },

    { "clock_time_get",         "i(iI*)",        &tw_clock_time_get },
    { "clock_res_get",          "i(i*)",         &tw_clock_res_get },
    { "random_get",             "i(*i)",         &tw_random_get },
    { "sched_yield",            "i()",           &tw_sched_yield },
    { "poll_oneoff",            "i(**i*)",       &tw_poll_oneoff },

    { "proc_exit",              "v(i)",          &tw_proc_exit },
    { "proc_raise",             "i(i)",          &tw_proc_raise },
};

M3Result tether_wasi_link(IM3Module module, tether_wasi *wasi)
{
    /* Both module names are linked: current toolchains emit
     * wasi_snapshot_preview1, older ones wasi_unstable. */
    static const char *const modules[] = { "wasi_snapshot_preview1", "wasi_unstable" };

    for (size_t m = 0; m < sizeof(modules) / sizeof(modules[0]); ++m) {
        for (size_t i = 0; i < sizeof(k_imports) / sizeof(k_imports[0]); ++i) {
            M3Result r = tw_allow_missing(m3_LinkRawFunctionEx(
                module, modules[m], k_imports[i].name, k_imports[i].signature,
                k_imports[i].fn, wasi));
            if (r != m3Err_none) return r;
        }
    }
    return m3Err_none;
}
