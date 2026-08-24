/*
 * tether_fakefs_create.c — build a Tether fakefs store from a tar.gz.
 * Uses libarchive (BSD-2-Clause) to read the archive. Clean-room. MIT.
 */
#define _GNU_SOURCE
#include "tether_fakefs.h"
#include "tether_internal.h"

#include <archive.h>
#include <archive_entry.h>

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

typedef struct build_entry {
    char *path;          /* normalized, store-relative                  */
    char *link;          /* symlink target or NULL                      */
    uint32_t mode;
    uint32_t uid, gid;
    uint32_t inode;      /* TETHER_NO_INODE if no content               */
    uint64_t size;
    uint64_t rdev;
    int64_t mtime;
    uint32_t crc32;
    uint64_t seq;        /* archive order; later duplicate paths win    */
} build_entry;

typedef struct builder {
    build_entry *v;
    size_t n, cap;
    uint32_t next_inode;
    uint64_t seq;
    const char *out_dir;
    char *errbuf;
    size_t errlen;
} builder;

static void bset_err(builder *b, const char *fmt, ...)
{
    if (!b->errbuf || !b->errlen)
        return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b->errbuf, b->errlen, fmt, ap);
    va_end(ap);
}

static build_entry *badd(builder *b)
{
    if (b->n == b->cap) {
        size_t ncap = b->cap ? b->cap * 2 : 256;
        build_entry *nv = realloc(b->v, ncap * sizeof(*nv));
        if (!nv)
            return NULL;
        b->v = nv;
        b->cap = ncap;
    }
    build_entry *e = &b->v[b->n++];
    memset(e, 0, sizeof(*e));
    e->inode = TETHER_NO_INODE;
    e->seq = b->seq++;
    return e;
}

static build_entry *bfind(builder *b, const char *path)
{
    /* linear scan from the end so the most recent duplicate wins */
    for (size_t i = b->n; i > 0; i--)
        if (strcmp(b->v[i - 1].path, path) == 0)
            return &b->v[i - 1];
    return NULL;
}

static int mkdir_p(const char *path)
{
    if (mkdir(path, 0755) == 0 || errno == EEXIST)
        return 0;
    return -errno;
}

/* Stream one archive member's content into data/%08x, computing CRC-32. */
static int write_data_file(builder *b, struct archive *a, uint32_t inode,
                           uint64_t *size_out, uint32_t *crc_out)
{
    char path[TETHER_FAKEFS_PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s/%08" PRIx32,
                 b->out_dir, TETHER_DATA_DIR, inode) >= (int)sizeof(path))
        return -ENAMETOOLONG;

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        bset_err(b, "cannot create %s: %s", path, strerror(errno));
        return -errno;
    }

    uint64_t total = 0;
    uint32_t crc = 0;
    char buf[65536];
    for (;;) {
        ssize_t n = archive_read_data(a, buf, sizeof(buf));
        if (n == 0)
            break;
        if (n < 0) {
            bset_err(b, "archive read error: %s", archive_error_string(a));
            close(fd);
            return -EIO;
        }
        crc = tether_crc32(crc, buf, (size_t)n);
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(fd, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR)
                    continue;
                bset_err(b, "write %s: %s", path, strerror(errno));
                close(fd);
                return -errno;
            }
            off += w;
        }
        total += (uint64_t)n;
    }
    if (close(fd) != 0)
        return -errno;
    *size_out = total;
    *crc_out = crc;
    return 0;
}

static int cmp_path(const void *pa, const void *pb)
{
    const build_entry *a = pa, *b = pb;
    int c = strcmp(a->path, b->path);
    if (c)
        return c;
    /* equal paths: older first, so the newer one survives dedup */
    return (a->seq < b->seq) ? -1 : 1;
}

/* Serialize the sorted, deduped entry list into tetherfs.idx (atomic). */
static int write_index(builder *b)
{
    /* dedup in place: keep the last (highest seq) of each path run */
    qsort(b->v, b->n, sizeof(*b->v), cmp_path);
    size_t w = 0;
    for (size_t i = 0; i < b->n; i++) {
        if (i + 1 < b->n && strcmp(b->v[i].path, b->v[i + 1].path) == 0) {
            free(b->v[i].path);
            free(b->v[i].link);
            continue; /* superseded by the next (newer) one */
        }
        b->v[w++] = b->v[i];
    }
    b->n = w;

    /* build string table */
    size_t st_cap = 4096, st_len = 1; /* offset 0 = "" */
    char *strtab = malloc(st_cap);
    if (!strtab)
        return -ENOMEM;
    strtab[0] = '\0';

    tether_idx_entry *recs = calloc(b->n ? b->n : 1, sizeof(*recs));
    if (!recs) {
        free(strtab);
        return -ENOMEM;
    }

    int rc = 0;
    for (size_t i = 0; i < b->n; i++) {
        const char *strs[2] = { b->v[i].path, b->v[i].link };
        uint32_t offs[2] = { 0, TETHER_NO_STR };
        for (int k = 0; k < 2; k++) {
            if (!strs[k])
                continue;
            size_t len = strlen(strs[k]) + 1;
            if (st_len + len > st_cap) {
                while (st_len + len > st_cap)
                    st_cap *= 2;
                char *ns = realloc(strtab, st_cap);
                if (!ns) { rc = -ENOMEM; goto out; }
                strtab = ns;
            }
            offs[k] = (uint32_t)st_len;
            memcpy(strtab + st_len, strs[k], len);
            st_len += len;
        }
        tether_idx_entry *r = &recs[i];
        r->path_off = offs[0];
        r->link_off = offs[1];
        r->mode = b->v[i].mode;
        r->uid = b->v[i].uid;
        r->gid = b->v[i].gid;
        r->inode = b->v[i].inode;
        r->size = b->v[i].size;
        r->rdev = b->v[i].rdev;
        r->mtime = b->v[i].mtime;
        r->crc32 = b->v[i].crc32;
        r->reserved = 0;
    }

    tether_idx_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    memcpy(hdr.magic, TETHER_IDX_MAGIC, 8);
    hdr.version = TETHER_IDX_VERSION;
    hdr.entry_count = (uint32_t)b->n;
    hdr.strtab_off = sizeof(hdr) + b->n * sizeof(tether_idx_entry);
    hdr.strtab_size = st_len;
    hdr.inode_count = b->next_inode;

    char tmp[TETHER_FAKEFS_PATH_MAX], fin[TETHER_FAKEFS_PATH_MAX];
    if (snprintf(tmp, sizeof(tmp), "%s/%s.tmp", b->out_dir, TETHER_IDX_NAME) >=
            (int)sizeof(tmp) ||
        snprintf(fin, sizeof(fin), "%s/%s", b->out_dir, TETHER_IDX_NAME) >=
            (int)sizeof(fin)) {
        rc = -ENAMETOOLONG;
        goto out;
    }

    FILE *f = fopen(tmp, "wb");
    if (!f) {
        bset_err(b, "cannot create %s: %s", tmp, strerror(errno));
        rc = -errno;
        goto out;
    }
    if (fwrite(&hdr, sizeof(hdr), 1, f) != 1 ||
        (b->n && fwrite(recs, sizeof(*recs), b->n, f) != b->n) ||
        fwrite(strtab, 1, st_len, f) != st_len ||
        fflush(f) != 0 || fsync(fileno(f)) != 0) {
        bset_err(b, "cannot write index: %s", strerror(errno));
        fclose(f);
        unlink(tmp);
        rc = -EIO;
        goto out;
    }
    fclose(f);
    if (rename(tmp, fin) != 0) {
        bset_err(b, "cannot finalize index: %s", strerror(errno));
        unlink(tmp);
        rc = -errno;
    }

out:
    free(strtab);
    free(recs);
    return rc;
}

int tether_fakefs_create(const char *tarball_path, const char *out_dir,
                         char *errbuf, size_t errlen)
{
    if (!tarball_path || !out_dir)
        return -EINVAL;
    if (errbuf && errlen)
        errbuf[0] = '\0';

    builder b;
    memset(&b, 0, sizeof(b));
    b.out_dir = out_dir;
    b.errbuf = errbuf;
    b.errlen = errlen;

    int rc = mkdir_p(out_dir);
    if (rc != 0) {
        if (errbuf) snprintf(errbuf, errlen, "mkdir %s: %s", out_dir, strerror(-rc));
        return rc;
    }
    char datadir[TETHER_FAKEFS_PATH_MAX];
    if (snprintf(datadir, sizeof(datadir), "%s/%s", out_dir, TETHER_DATA_DIR) >=
        (int)sizeof(datadir))
        return -ENAMETOOLONG;
    rc = mkdir_p(datadir);
    if (rc != 0) {
        if (errbuf) snprintf(errbuf, errlen, "mkdir %s: %s", datadir, strerror(-rc));
        return rc;
    }

    struct archive *a = archive_read_new();
    if (!a)
        return -ENOMEM;
    archive_read_support_filter_all(a);
    archive_read_support_format_tar(a);
    archive_read_support_format_gnutar(a);

    if (archive_read_open_filename(a, tarball_path, 65536) != ARCHIVE_OK) {
        bset_err(&b, "cannot open archive %s: %s",
                 tarball_path, archive_error_string(a));
        archive_read_free(a);
        return -EIO;
    }

    struct archive_entry *ae;
    for (;;) {
        int ar = archive_read_next_header(a, &ae);
        if (ar == ARCHIVE_EOF)
            break;
        if (ar == ARCHIVE_WARN)
            ar = ARCHIVE_OK; /* tolerate benign warnings */
        if (ar != ARCHIVE_OK) {
            bset_err(&b, "archive error: %s", archive_error_string(a));
            rc = -EIO;
            goto fail;
        }

        const char *raw = archive_entry_pathname(ae);
        char norm[TETHER_FAKEFS_PATH_MAX];
        if (!raw || tether_normalize_path(raw, norm, sizeof(norm)) != 0)
            continue;
        if (norm[0] == '\0')
            continue; /* the root dir itself: implicit */

        mode_t mode = archive_entry_mode(ae);
        const char *hardlink = archive_entry_hardlink(ae);

        build_entry *e = badd(&b);
        if (!e) { rc = -ENOMEM; goto fail; }
        e->path = strdup(norm);
        if (!e->path) { rc = -ENOMEM; goto fail; }
        e->uid = (uint32_t)archive_entry_uid(ae);
        e->gid = (uint32_t)archive_entry_gid(ae);
        e->mtime = archive_entry_mtime_is_set(ae)
                       ? (int64_t)archive_entry_mtime(ae) : 0;

        if (hardlink) {
            /* Hardlink: share the target's inode/content. */
            char hnorm[TETHER_FAKEFS_PATH_MAX];
            if (tether_normalize_path(hardlink, hnorm, sizeof(hnorm)) != 0) {
                bset_err(&b, "bad hardlink target for %s", norm);
                rc = -EINVAL;
                goto fail;
            }
            build_entry *t = bfind(&b, hnorm);
            if (!t || t == e) {
                bset_err(&b, "hardlink %s -> %s: target not seen yet",
                         norm, hnorm);
                rc = -EINVAL;
                goto fail;
            }
            e->mode = t->mode;
            e->inode = t->inode;
            e->size = t->size;
            e->crc32 = t->crc32;
            continue;
        }

        e->mode = (uint32_t)mode;

        if (S_ISREG(mode)) {
            e->inode = b.next_inode++;
            rc = write_data_file(&b, a, e->inode, &e->size, &e->crc32);
            if (rc != 0)
                goto fail;
        } else if (S_ISLNK(mode)) {
            const char *target = archive_entry_symlink(ae);
            if (!target) {
                bset_err(&b, "symlink %s has no target", norm);
                rc = -EINVAL;
                goto fail;
            }
            e->link = strdup(target);
            if (!e->link) { rc = -ENOMEM; goto fail; }
        } else if (S_ISCHR(mode) || S_ISBLK(mode)) {
            e->rdev = (uint64_t)archive_entry_rdev(ae);
        }
        /* dirs, fifos, sockets: metadata only */
    }

    archive_read_free(a);
    a = NULL;

    rc = write_index(&b);
    if (rc != 0)
        goto fail_noarchive;

    for (size_t i = 0; i < b.n; i++) {
        free(b.v[i].path);
        free(b.v[i].link);
    }
    free(b.v);
    return 0;

fail:
    if (a)
        archive_read_free(a);
fail_noarchive:
    for (size_t i = 0; i < b.n; i++) {
        free(b.v[i].path);
        free(b.v[i].link);
    }
    free(b.v);
    return rc;
}
