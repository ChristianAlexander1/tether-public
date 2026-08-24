/*
 * tether_fakefs.c — Tether fakefs reader: open, stat, readlink, resolve,
 * read, readdir, verify. Clean-room implementation. MIT licensed.
 */
#define _GNU_SOURCE
#include "tether_fakefs.h"
#include "tether_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

struct tether_fakefs {
    char *dir;                       /* store directory                 */
    uint8_t *idx;                    /* whole tetherfs.idx in memory    */
    size_t idx_size;
    tether_idx_header hdr;
    const tether_idx_entry *entries; /* points into idx                 */
    const char *strtab;              /* points into idx                 */
};

static void set_err(char *errbuf, size_t errlen, const char *fmt, ...)
{
    if (!errbuf || errlen == 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(errbuf, errlen, fmt, ap);
    va_end(ap);
}

/* ---------------- open / close ------------------------------------- */

static const char *ent_path(const tether_fakefs *fs, const tether_idx_entry *e)
{
    return fs->strtab + e->path_off;
}

static int validate(tether_fakefs *fs, char *errbuf, size_t errlen)
{
    const tether_idx_header *h = &fs->hdr;

    if (fs->idx_size < sizeof(tether_idx_header) ||
        memcmp(h->magic, TETHER_IDX_MAGIC, 8) != 0) {
        set_err(errbuf, errlen, "not a Tether fakefs index (bad magic)");
        return -EINVAL;
    }
    if (h->version != TETHER_IDX_VERSION) {
        set_err(errbuf, errlen, "unsupported index version %u", h->version);
        return -EINVAL;
    }

    uint64_t entries_end = sizeof(tether_idx_header) +
                           (uint64_t)h->entry_count * sizeof(tether_idx_entry);
    if (entries_end > fs->idx_size ||
        h->strtab_off != entries_end ||
        h->strtab_off + h->strtab_size != fs->idx_size) {
        set_err(errbuf, errlen, "index layout is corrupt");
        return -EINVAL;
    }
    if (h->strtab_size == 0 || fs->idx[fs->idx_size - 1] != '\0') {
        set_err(errbuf, errlen, "string table is not NUL-terminated");
        return -EINVAL;
    }

    fs->entries = (const tether_idx_entry *)(fs->idx + sizeof(tether_idx_header));
    fs->strtab = (const char *)(fs->idx + h->strtab_off);

    const char *prev = NULL;
    for (uint32_t i = 0; i < h->entry_count; i++) {
        const tether_idx_entry *e = &fs->entries[i];
        if (e->path_off >= h->strtab_size ||
            (e->link_off != TETHER_NO_STR && e->link_off >= h->strtab_size)) {
            set_err(errbuf, errlen, "entry %u: string offset out of range", i);
            return -EINVAL;
        }
        if (e->inode != TETHER_NO_INODE && e->inode >= h->inode_count) {
            set_err(errbuf, errlen, "entry %u: inode out of range", i);
            return -EINVAL;
        }
        const char *p = ent_path(fs, e);
        if (prev && strcmp(prev, p) >= 0) {
            set_err(errbuf, errlen, "index is not sorted/unique at entry %u", i);
            return -EINVAL;
        }
        prev = p;
    }
    return 0;
}

tether_fakefs *tether_fakefs_open(const char *dir, char *errbuf, size_t errlen)
{
    if (!dir) {
        set_err(errbuf, errlen, "dir is NULL");
        return NULL;
    }

    char path[TETHER_FAKEFS_PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s", dir, TETHER_IDX_NAME) >=
        (int)sizeof(path)) {
        set_err(errbuf, errlen, "path too long");
        return NULL;
    }

    FILE *f = fopen(path, "rb");
    if (!f) {
        set_err(errbuf, errlen, "cannot open %s: %s", path, strerror(errno));
        return NULL;
    }

    tether_fakefs *fs = calloc(1, sizeof(*fs));
    if (!fs) {
        fclose(f);
        return NULL;
    }

    struct stat st;
    if (fstat(fileno(f), &st) != 0 || st.st_size < (off_t)sizeof(tether_idx_header)) {
        set_err(errbuf, errlen, "index file truncated");
        goto fail;
    }
    fs->idx_size = (size_t)st.st_size;
    fs->idx = malloc(fs->idx_size);
    if (!fs->idx || fread(fs->idx, 1, fs->idx_size, f) != fs->idx_size) {
        set_err(errbuf, errlen, "cannot read index: %s", strerror(errno));
        goto fail;
    }
    memcpy(&fs->hdr, fs->idx, sizeof(fs->hdr));

    fs->dir = strdup(dir);
    if (!fs->dir)
        goto fail;
    if (validate(fs, errbuf, errlen) != 0)
        goto fail;

    fclose(f);
    return fs;

fail:
    fclose(f);
    free(fs->idx);
    free(fs->dir);
    free(fs);
    return NULL;
}

void tether_fakefs_close(tether_fakefs *fs)
{
    if (!fs)
        return;
    free(fs->idx);
    free(fs->dir);
    free(fs);
}

/* ---------------- lookup -------------------------------------------- */

static const tether_idx_entry *lookup(const tether_fakefs *fs, const char *norm)
{
    uint32_t lo = 0, hi = fs->hdr.entry_count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        int c = strcmp(ent_path(fs, &fs->entries[mid]), norm);
        if (c == 0)
            return &fs->entries[mid];
        if (c < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    return NULL;
}

/* Does any entry live strictly below `norm` (i.e. is it an implicit dir)? */
static int has_children(const tether_fakefs *fs, const char *norm)
{
    size_t plen = strlen(norm);
    uint32_t lo = 0, hi = fs->hdr.entry_count;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (strcmp(ent_path(fs, &fs->entries[mid]), norm) <= 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo >= fs->hdr.entry_count)
        return 0;
    const char *p = ent_path(fs, &fs->entries[lo]);
    if (plen == 0)
        return 1; /* root: any entry is a child */
    return strncmp(p, norm, plen) == 0 && p[plen] == '/';
}

static void fill_stat(const tether_fakefs *fs, const tether_idx_entry *e,
                      tether_fakefs_stat *st)
{
    st->mode = e->mode;
    st->uid = e->uid;
    st->gid = e->gid;
    st->size = e->size;
    st->mtime = e->mtime;
    st->rdev = e->rdev;
    st->inode = e->inode;
    st->nlink = 1;
    if (e->inode != TETHER_NO_INODE) {
        uint32_t n = 0;
        for (uint32_t i = 0; i < fs->hdr.entry_count; i++)
            if (fs->entries[i].inode == e->inode)
                n++;
        st->nlink = n;
    }
}

/* ---------------- symlink resolution -------------------------------- */

/*
 * Resolve `path` to a canonical store-relative path in `out`.
 * follow_last: whether a trailing symlink is dereferenced.
 * Returns 0 with *ent_out set (NULL if the final path has no entry but
 * the caller may still want the name, e.g. resolve of a nonexistent leaf
 * returns -ENOENT below).
 */
static int resolve_path(const tether_fakefs *fs, const char *path,
                        int follow_last, char *out, size_t outlen,
                        const tether_idx_entry **ent_out)
{
    char work[TETHER_FAKEFS_PATH_MAX];   /* remaining components */
    char res[TETHER_FAKEFS_PATH_MAX];    /* resolved so far      */
    int rc = tether_normalize_path(path, work, sizeof(work));
    if (rc != 0)
        return rc;
    res[0] = '\0';

    int hops = 0;
    char *rest = work;

    while (*rest) {
        char *slash = strchr(rest, '/');
        size_t clen = slash ? (size_t)(slash - rest) : strlen(rest);
        char comp[TETHER_FAKEFS_PATH_MAX];
        memcpy(comp, rest, clen);
        comp[clen] = '\0';
        rest = slash ? slash + 1 : rest + clen;
        int is_last = (*rest == '\0');

        /* candidate = res + "/" + comp */
        char cand[TETHER_FAKEFS_PATH_MAX];
        int n = snprintf(cand, sizeof(cand), "%s%s%s",
                         res, res[0] ? "/" : "", comp);
        if (n < 0 || n >= (int)sizeof(cand))
            return -ENAMETOOLONG;

        const tether_idx_entry *e = lookup(fs, cand);
        if (e && S_ISLNK(e->mode) && (!is_last || follow_last)) {
            if (++hops > TETHER_FAKEFS_MAX_SYMLINKS)
                return -ELOOP;
            const char *target = fs->strtab + e->link_off;
            /* splice: new remaining = target + "/" + rest */
            char next[TETHER_FAKEFS_PATH_MAX];
            n = snprintf(next, sizeof(next), "%s%s%s",
                         target, *rest ? "/" : "", rest);
            if (n < 0 || n >= (int)sizeof(next))
                return -ENAMETOOLONG;
            if (target[0] == '/')
                res[0] = '\0';           /* absolute target: restart at root */
            rc = tether_normalize_path(next, work, sizeof(work));
            if (rc != 0)
                return rc;
            /* ".." in the target must be resolved against res; simplest
             * correct approach: prepend res, renormalize, restart. */
            if (res[0]) {
                char joined[TETHER_FAKEFS_PATH_MAX];
                n = snprintf(joined, sizeof(joined), "%s/%s", res, work);
                if (n < 0 || n >= (int)sizeof(joined))
                    return -ENAMETOOLONG;
                rc = tether_normalize_path(joined, work, sizeof(work));
                if (rc != 0)
                    return rc;
                res[0] = '\0';
            }
            rest = work;
            continue;
        }

        if (!is_last) {
            /* must be traversable: an explicit dir, or an implicit dir */
            if (e && !S_ISDIR(e->mode))
                return -ENOTDIR;
            if (!e && !has_children(fs, cand))
                return -ENOENT;
        }

        memcpy(res, cand, (size_t)n + 1);
        if (is_last) {
            if (strlen(res) + 1 > outlen)
                return -ENAMETOOLONG;
            strcpy(out, res);
            if (ent_out)
                *ent_out = e;
            return 0;
        }
    }

    /* path normalized to root */
    if (outlen < 1)
        return -ENAMETOOLONG;
    out[0] = '\0';
    if (ent_out)
        *ent_out = NULL;
    return 0;
}

/* ---------------- public metadata API -------------------------------- */

int tether_fakefs_stat_path(const tether_fakefs *fs, const char *path,
                            tether_fakefs_stat *st)
{
    if (!fs || !path || !st)
        return -EINVAL;
    char out[TETHER_FAKEFS_PATH_MAX];
    const tether_idx_entry *e = NULL;
    int rc = resolve_path(fs, path, 0, out, sizeof(out), &e);
    if (rc != 0)
        return rc;
    if (!e) {
        if (out[0] == '\0' || has_children(fs, out)) {
            /* implicit directory (incl. root) */
            memset(st, 0, sizeof(*st));
            st->mode = S_IFDIR | 0755;
            st->inode = TETHER_NO_INODE;
            st->nlink = 1;
            return 0;
        }
        return -ENOENT;
    }
    fill_stat(fs, e, st);
    return 0;
}

int tether_fakefs_stat_follow(const tether_fakefs *fs, const char *path,
                              tether_fakefs_stat *st)
{
    if (!fs || !path || !st)
        return -EINVAL;
    char out[TETHER_FAKEFS_PATH_MAX];
    const tether_idx_entry *e = NULL;
    int rc = resolve_path(fs, path, 1, out, sizeof(out), &e);
    if (rc != 0)
        return rc;
    if (!e) {
        if (out[0] == '\0' || has_children(fs, out)) {
            memset(st, 0, sizeof(*st));
            st->mode = S_IFDIR | 0755;
            st->inode = TETHER_NO_INODE;
            st->nlink = 1;
            return 0;
        }
        return -ENOENT;
    }
    fill_stat(fs, e, st);
    return 0;
}

int tether_fakefs_readlink(const tether_fakefs *fs, const char *path,
                           char *buf, size_t buflen)
{
    if (!fs || !path || !buf)
        return -EINVAL;
    char out[TETHER_FAKEFS_PATH_MAX];
    const tether_idx_entry *e = NULL;
    int rc = resolve_path(fs, path, 0, out, sizeof(out), &e);
    if (rc != 0)
        return rc;
    if (!e)
        return -ENOENT;
    if (!S_ISLNK(e->mode))
        return -EINVAL;
    const char *target = fs->strtab + e->link_off;
    size_t tlen = strlen(target);
    if (tlen + 1 > buflen)
        return -ENAMETOOLONG;
    memcpy(buf, target, tlen + 1);
    return (int)tlen;
}

int tether_fakefs_resolve(const tether_fakefs *fs, const char *path,
                          char *resolved, size_t resolvedlen)
{
    if (!fs || !path || !resolved)
        return -EINVAL;
    const tether_idx_entry *e = NULL;
    int rc = resolve_path(fs, path, 1, resolved, resolvedlen, &e);
    if (rc != 0)
        return rc;
    if (!e && resolved[0] != '\0' && !has_children(fs, resolved))
        return -ENOENT;
    return 0;
}

/* ---------------- content ------------------------------------------- */

static int open_data_fd(const tether_fakefs *fs, uint32_t inode)
{
    char path[TETHER_FAKEFS_PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s/%08" PRIx32,
                 fs->dir, TETHER_DATA_DIR, inode) >= (int)sizeof(path))
        return -ENAMETOOLONG;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    return fd >= 0 ? fd : -errno;
}

static int entry_for_read(const tether_fakefs *fs, const char *path,
                          const tether_idx_entry **e_out)
{
    char out[TETHER_FAKEFS_PATH_MAX];
    const tether_idx_entry *e = NULL;
    int rc = resolve_path(fs, path, 1, out, sizeof(out), &e);
    if (rc != 0)
        return rc;
    if (!e)
        return (out[0] == '\0' || has_children(fs, out)) ? -EISDIR : -ENOENT;
    if (S_ISDIR(e->mode))
        return -EISDIR;
    if (!S_ISREG(e->mode))
        return -EINVAL;
    *e_out = e;
    return 0;
}

ssize_t tether_fakefs_read(const tether_fakefs *fs, const char *path,
                           void *buf, size_t len, uint64_t offset)
{
    if (!fs || !path || (!buf && len))
        return -EINVAL;
    const tether_idx_entry *e;
    int rc = entry_for_read(fs, path, &e);
    if (rc != 0)
        return rc;
    if (e->inode == TETHER_NO_INODE || offset >= e->size)
        return 0;
    if (len > e->size - offset)
        len = (size_t)(e->size - offset);

    int fd = open_data_fd(fs, e->inode);
    if (fd < 0)
        return fd;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(fd, (char *)buf + done, len - done,
                          (off_t)(offset + done));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            close(fd);
            return -errno;
        }
        if (n == 0)
            break;
        done += (size_t)n;
    }
    close(fd);
    return (ssize_t)done;
}

int tether_fakefs_open_fd(const tether_fakefs *fs, const char *path)
{
    if (!fs || !path)
        return -EINVAL;
    const tether_idx_entry *e;
    int rc = entry_for_read(fs, path, &e);
    if (rc != 0)
        return rc;
    if (e->inode == TETHER_NO_INODE)
        return -EIO;
    return open_data_fd(fs, e->inode);
}

/* ---------------- enumeration ---------------------------------------- */

uint32_t tether_fakefs_count(const tether_fakefs *fs)
{
    return fs ? fs->hdr.entry_count : 0;
}

int tether_fakefs_entry_at(const tether_fakefs *fs, uint32_t idx,
                           const char **path_out, tether_fakefs_stat *st)
{
    if (!fs || !path_out || idx >= fs->hdr.entry_count)
        return -EINVAL;
    const tether_idx_entry *e = &fs->entries[idx];
    *path_out = ent_path(fs, e);
    if (st)
        fill_stat(fs, e, st);
    return 0;
}

int tether_fakefs_readdir(const tether_fakefs *fs, const char *dirpath,
                          tether_fakefs_dirent_cb cb, void *user)
{
    if (!fs || !dirpath || !cb)
        return -EINVAL;

    char norm[TETHER_FAKEFS_PATH_MAX];
    const tether_idx_entry *de = NULL;
    int rc = resolve_path(fs, dirpath, 1, norm, sizeof(norm), &de);
    if (rc != 0)
        return rc;
    if (de && !S_ISDIR(de->mode))
        return -ENOTDIR;
    if (!de && norm[0] != '\0' && !has_children(fs, norm))
        return -ENOENT;

    size_t plen = strlen(norm);

    /* first entry with prefix norm + "/" (or 0 for root) */
    uint32_t lo = 0, hi = fs->hdr.entry_count;
    if (plen) {
        while (lo < hi) {
            uint32_t mid = lo + (hi - lo) / 2;
            if (strcmp(ent_path(fs, &fs->entries[mid]), norm) <= 0)
                lo = mid + 1;
            else
                hi = mid;
        }
    }

    int count = 0;
    for (uint32_t i = lo; i < fs->hdr.entry_count; i++) {
        const char *p = ent_path(fs, &fs->entries[i]);
        const char *rel;
        if (plen) {
            if (strncmp(p, norm, plen) != 0 || p[plen] != '/')
                break;                    /* left the subtree */
            rel = p + plen + 1;
        } else {
            rel = p;
        }
        if (strchr(rel, '/'))
            continue;                     /* grandchild, not immediate */
        tether_fakefs_stat st;
        fill_stat(fs, &fs->entries[i], &st);
        count++;
        if (cb(rel, p, &st, user) != 0)
            break;
    }
    return count;
}

/* ---------------- verify ---------------------------------------------- */

int tether_fakefs_verify(const tether_fakefs *fs,
                         tether_fakefs_report_cb report, void *user)
{
    if (!fs)
        return -EINVAL;

    int bad = 0;
    char buf[65536];

    for (uint32_t i = 0; i < fs->hdr.entry_count; i++) {
        const tether_idx_entry *e = &fs->entries[i];
        const char *p = ent_path(fs, e);

        if (S_ISLNK(e->mode) && e->link_off == TETHER_NO_STR) {
            bad++;
            if (report)
                report(p, "symlink with no target", user);
            continue;
        }
        if (!S_ISREG(e->mode))
            continue;
        if (e->inode == TETHER_NO_INODE) {
            if (e->size != 0) {
                bad++;
                if (report)
                    report(p, "regular file with size but no data", user);
            }
            continue;
        }

        int fd = open_data_fd(fs, e->inode);
        if (fd < 0) {
            bad++;
            if (report)
                report(p, "data file missing or unreadable", user);
            continue;
        }
        uint64_t total = 0;
        uint32_t crc = 0;
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            crc = tether_crc32(crc, buf, (size_t)n);
            total += (uint64_t)n;
        }
        close(fd);
        if (n < 0) {
            bad++;
            if (report)
                report(p, "I/O error reading data file", user);
            continue;
        }
        if (total != e->size) {
            bad++;
            if (report)
                report(p, "size mismatch", user);
            continue;
        }
        if (crc != e->crc32) {
            bad++;
            if (report)
                report(p, "CRC-32 mismatch (content corrupt)", user);
        }
    }
    return bad;
}
