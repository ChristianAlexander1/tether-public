/*
 * tether_fakefs_overlay.c — copy-up writable layer over an immutable store.
 * Whiteouts use the overlayfs `.wh.<basename>` convention. MIT licensed.
 */
#define _GNU_SOURCE
#include "tether_fakefs.h"
#include "tether_internal.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct tether_fakefs_rw {
    tether_fakefs *lower;
    char *upper;
};

static int join_upper(const tether_fakefs_rw *rw, const char *rel,
                      char *out, size_t outlen)
{
    if (!rel || rel[0] == '\0') {
        if (snprintf(out, outlen, "%s", rw->upper) >= (int)outlen)
            return -ENAMETOOLONG;
        return 0;
    }
    if (snprintf(out, outlen, "%s/%s", rw->upper, rel) >= (int)outlen)
        return -ENAMETOOLONG;
    return 0;
}

static int parent_and_base(const char *rel, char *parent, size_t parentlen,
                           const char **base_out)
{
    const char *slash = strrchr(rel, '/');
    if (!slash) {
        if (parentlen < 1) return -ENAMETOOLONG;
        parent[0] = '\0';
        *base_out = rel;
        return 0;
    }
    size_t n = (size_t)(slash - rel);
    if (n + 1 > parentlen) return -ENAMETOOLONG;
    memcpy(parent, rel, n);
    parent[n] = '\0';
    *base_out = slash + 1;
    return 0;
}

static int whiteout_path(const tether_fakefs_rw *rw, const char *rel,
                         char *out, size_t outlen)
{
    char parent[TETHER_FAKEFS_PATH_MAX];
    const char *base;
    char rel_wh[TETHER_FAKEFS_PATH_MAX];
    int rc = parent_and_base(rel, parent, sizeof(parent), &base);
    if (rc != 0) return rc;
    if (parent[0] == '\0') {
        if (snprintf(rel_wh, sizeof(rel_wh), ".wh.%s", base) >= (int)sizeof(rel_wh))
            return -ENAMETOOLONG;
    } else if (snprintf(rel_wh, sizeof(rel_wh), "%s/.wh.%s", parent, base) >=
               (int)sizeof(rel_wh)) {
        return -ENAMETOOLONG;
    }
    return join_upper(rw, rel_wh, out, outlen);
}

static int is_whiteout(const tether_fakefs_rw *rw, const char *rel)
{
    char path[TETHER_FAKEFS_PATH_MAX];
    if (whiteout_path(rw, rel, path, sizeof(path)) != 0) return 0;
    return access(path, F_OK) == 0;
}

static int mkdir_p(const char *path, mode_t mode)
{
    char tmp[TETHER_FAKEFS_PATH_MAX];
    size_t len;
    if (!path || !path[0]) return -EINVAL;
    if (snprintf(tmp, sizeof(tmp), "%s", path) >= (int)sizeof(tmp))
        return -ENAMETOOLONG;
    len = strlen(tmp);
    if (len > 0 && tmp[len - 1] == '/') tmp[len - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -errno;
        *p = '/';
    }
    if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -errno;
    return 0;
}

static int ensure_upper_parents(tether_fakefs_rw *rw, const char *rel)
{
    char parent[TETHER_FAKEFS_PATH_MAX];
    const char *base;
    char host[TETHER_FAKEFS_PATH_MAX];
    int rc = parent_and_base(rel, parent, sizeof(parent), &base);
    if (rc != 0) return rc;
    (void)base;
    if (parent[0] == '\0') return mkdir_p(rw->upper, 0755);
    rc = join_upper(rw, parent, host, sizeof(host));
    if (rc != 0) return rc;
    return mkdir_p(host, 0755);
}

static void fill_stat_from_host(const struct stat *hs, tether_fakefs_stat *st)
{
    memset(st, 0, sizeof(*st));
    st->mode = (uint32_t)hs->st_mode;
    st->uid = (uint32_t)hs->st_uid;
    st->gid = (uint32_t)hs->st_gid;
    st->size = (uint64_t)hs->st_size;
    st->mtime = (int64_t)hs->st_mtime;
    st->inode = (uint32_t)hs->st_ino;
    st->nlink = (uint32_t)hs->st_nlink;
}

static int copy_up_file(tether_fakefs_rw *rw, const char *rel)
{
    char host[TETHER_FAKEFS_PATH_MAX];
    unsigned char buf[8192];
    ssize_t n;
    uint64_t off = 0;
    int fd, rc;

    rc = ensure_upper_parents(rw, rel);
    if (rc != 0) return rc;
    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    if (access(host, F_OK) == 0) return 0;

    fd = open(host, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) return -errno;
    for (;;) {
        n = tether_fakefs_read(rw->lower, rel, buf, sizeof(buf), off);
        if (n < 0) {
            close(fd);
            unlink(host);
            return (int)n;
        }
        if (n == 0) break;
        if (write(fd, buf, (size_t)n) != n) {
            int e = -errno;
            close(fd);
            unlink(host);
            return e;
        }
        off += (uint64_t)n;
    }
    close(fd);
    return 0;
}

tether_fakefs_rw *tether_fakefs_overlay_open(const char *lower_dir,
                                             const char *upper_dir,
                                             char *errbuf, size_t errlen)
{
    tether_fakefs_rw *rw;
    tether_fakefs *lower;

    if (!lower_dir || !upper_dir) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "lower and upper required");
        return NULL;
    }
    lower = tether_fakefs_open(lower_dir, errbuf, errlen);
    if (!lower) return NULL;
    if (mkdir_p(upper_dir, 0755) != 0) {
        if (errbuf && errlen) snprintf(errbuf, errlen, "cannot create upper dir");
        tether_fakefs_close(lower);
        return NULL;
    }
    rw = calloc(1, sizeof(*rw));
    if (!rw) {
        tether_fakefs_close(lower);
        return NULL;
    }
    rw->lower = lower;
    rw->upper = strdup(upper_dir);
    if (!rw->upper) {
        tether_fakefs_close(lower);
        free(rw);
        return NULL;
    }
    return rw;
}

void tether_fakefs_overlay_close(tether_fakefs_rw *rw)
{
    if (!rw) return;
    tether_fakefs_close(rw->lower);
    free(rw->upper);
    free(rw);
}

int tether_fakefs_overlay_stat(const tether_fakefs_rw *rw, const char *path,
                               tether_fakefs_stat *st)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    struct stat hs;
    int rc;

    if (!rw || !path || !st) return -EINVAL;
    rc = tether_normalize_path(path, rel, sizeof(rel));
    if (rc != 0) return rc;
    if (is_whiteout(rw, rel)) return -ENOENT;
    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    if (lstat(host, &hs) == 0) {
        fill_stat_from_host(&hs, st);
        return 0;
    }
    if (errno != ENOENT) return -errno;
    return tether_fakefs_stat_path(rw->lower, rel, st);
}

ssize_t tether_fakefs_overlay_read(const tether_fakefs_rw *rw, const char *path,
                                   void *buf, size_t len, uint64_t offset)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    int fd, rc;
    ssize_t n;

    if (!rw || !path || (!buf && len)) return -EINVAL;
    rc = tether_normalize_path(path, rel, sizeof(rel));
    if (rc != 0) return rc;
    if (is_whiteout(rw, rel)) return -ENOENT;
    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    fd = open(host, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        n = pread(fd, buf, len, (off_t)offset);
        close(fd);
        return n >= 0 ? n : -errno;
    }
    if (errno != ENOENT) return -errno;
    return tether_fakefs_read(rw->lower, rel, buf, len, offset);
}

ssize_t tether_fakefs_overlay_write(tether_fakefs_rw *rw, const char *path,
                                    const void *buf, size_t len, uint64_t offset)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    char wh[TETHER_FAKEFS_PATH_MAX];
    tether_fakefs_stat st;
    int fd, rc;
    ssize_t n;

    if (!rw || !path || (!buf && len)) return -EINVAL;
    rc = tether_normalize_path(path, rel, sizeof(rel));
    if (rc != 0) return rc;

    if (whiteout_path(rw, rel, wh, sizeof(wh)) == 0)
        unlink(wh);

    rc = tether_fakefs_stat_path(rw->lower, rel, &st);
    if (rc == 0 && S_ISREG(st.mode)) {
        rc = copy_up_file(rw, rel);
        if (rc != 0) return rc;
    } else {
        rc = ensure_upper_parents(rw, rel);
        if (rc != 0) return rc;
    }

    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    fd = open(host, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return -errno;
    n = pwrite(fd, buf, len, (off_t)offset);
    close(fd);
    return n >= 0 ? n : -errno;
}

int tether_fakefs_overlay_mkdir(tether_fakefs_rw *rw, const char *path, uint32_t mode)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    char wh[TETHER_FAKEFS_PATH_MAX];
    int rc;

    if (!rw || !path) return -EINVAL;
    rc = tether_normalize_path(path, rel, sizeof(rel));
    if (rc != 0) return rc;
    if (whiteout_path(rw, rel, wh, sizeof(wh)) == 0)
        unlink(wh);
    rc = ensure_upper_parents(rw, rel);
    if (rc != 0) return rc;
    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    if (mkdir(host, (mode_t)(mode ? mode : 0755)) != 0 && errno != EEXIST)
        return -errno;
    return 0;
}

int tether_fakefs_overlay_unlink(tether_fakefs_rw *rw, const char *path)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    char wh[TETHER_FAKEFS_PATH_MAX];
    tether_fakefs_stat st;
    int rc, lower_exists;

    if (!rw || !path) return -EINVAL;
    rc = tether_normalize_path(path, rel, sizeof(rel));
    if (rc != 0) return rc;
    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    if (unlink(host) != 0 && errno != ENOENT)
        rmdir(host);

    lower_exists = tether_fakefs_stat_path(rw->lower, rel, &st) == 0;
    if (!lower_exists) return 0;
    rc = whiteout_path(rw, rel, wh, sizeof(wh));
    if (rc != 0) return rc;
    rc = ensure_upper_parents(rw, rel);
    if (rc != 0) return rc;
    {
        int fd = open(wh, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd < 0) return -errno;
        close(fd);
    }
    return 0;
}

int tether_fakefs_overlay_create(tether_fakefs_rw *rw, const char *path,
                                 uint32_t mode)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    char wh[TETHER_FAKEFS_PATH_MAX];
    int fd, rc;

    if (!rw || !path) return -EINVAL;
    rc = tether_normalize_path(path, rel, sizeof(rel));
    if (rc != 0) return rc;
    if (whiteout_path(rw, rel, wh, sizeof(wh)) == 0)
        unlink(wh);
    rc = ensure_upper_parents(rw, rel);
    if (rc != 0) return rc;
    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    fd = open(host, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
              (mode_t)(mode ? mode : 0644));
    if (fd < 0) return -errno;
    close(fd);
    return 0;
}

static int join_child(const char *dir, const char *name, char *out, size_t outlen)
{
    if (!dir[0]) {
        if (snprintf(out, outlen, "%s", name) >= (int)outlen)
            return -ENAMETOOLONG;
        return 0;
    }
    if (snprintf(out, outlen, "%s/%s", dir, name) >= (int)outlen)
        return -ENAMETOOLONG;
    return 0;
}

struct overlay_seen {
    char **v;
    size_t n;
    size_t cap;
};

static int overlay_seen_has(const struct overlay_seen *s, const char *name)
{
    size_t i;
    for (i = 0; i < s->n; i++) {
        if (strcmp(s->v[i], name) == 0) return 1;
    }
    return 0;
}

static int overlay_seen_add(struct overlay_seen *s, const char *name)
{
    char **nv;
    char *dup;
    if (overlay_seen_has(s, name)) return 0;
    if (s->n == s->cap) {
        size_t ncap = s->cap ? s->cap * 2 : 16;
        nv = realloc(s->v, ncap * sizeof(*nv));
        if (!nv) return -ENOMEM;
        s->v = nv;
        s->cap = ncap;
    }
    dup = strdup(name);
    if (!dup) return -ENOMEM;
    s->v[s->n++] = dup;
    return 0;
}

static void overlay_seen_free(struct overlay_seen *s)
{
    size_t i;
    for (i = 0; i < s->n; i++) free(s->v[i]);
    free(s->v);
    s->v = NULL;
    s->n = s->cap = 0;
}

struct overlay_merge {
    const tether_fakefs_rw *rw;
    tether_fakefs_dirent_cb cb;
    void *user;
    struct overlay_seen *seen;
    int count;
    int stop;
    int err;
};

static int overlay_lower_cb(const char *name, const char *full,
                            const tether_fakefs_stat *st, void *user)
{
    struct overlay_merge *m = user;
    int rc;
    if (m->stop) return 1;
    if (!name || !name[0] || strncmp(name, ".wh.", 4) == 0) return 0;
    if (overlay_seen_has(m->seen, name)) return 0;
    if (is_whiteout(m->rw, full)) return 0;
    rc = overlay_seen_add(m->seen, name);
    if (rc != 0) {
        m->err = rc;
        return 1;
    }
    m->count++;
    if (m->cb(name, full, st, m->user) != 0) {
        m->stop = 1;
        return 1;
    }
    return 0;
}

int tether_fakefs_overlay_rename(tether_fakefs_rw *rw, const char *from,
                                 const char *to)
{
    char frel[TETHER_FAKEFS_PATH_MAX];
    char trel[TETHER_FAKEFS_PATH_MAX];
    char fhost[TETHER_FAKEFS_PATH_MAX];
    char thost[TETHER_FAKEFS_PATH_MAX];
    char fwh[TETHER_FAKEFS_PATH_MAX];
    char twh[TETHER_FAKEFS_PATH_MAX];
    tether_fakefs_stat st;
    struct stat hs;
    int rc, src_upper, src_lower;

    if (!rw || !from || !to) return -EINVAL;
    rc = tether_normalize_path(from, frel, sizeof(frel));
    if (rc != 0) return rc;
    rc = tether_normalize_path(to, trel, sizeof(trel));
    if (rc != 0) return rc;
    if (is_whiteout(rw, frel)) return -ENOENT;

    rc = join_upper(rw, frel, fhost, sizeof(fhost));
    if (rc != 0) return rc;
    rc = join_upper(rw, trel, thost, sizeof(thost));
    if (rc != 0) return rc;

    src_upper = lstat(fhost, &hs) == 0;
    src_lower = tether_fakefs_stat_path(rw->lower, frel, &st) == 0;
    if (!src_upper && !src_lower) return -ENOENT;

    if (!src_upper) {
        if (!S_ISREG(st.mode)) return -EXDEV;
        rc = copy_up_file(rw, frel);
        if (rc != 0) return rc;
    }

    rc = ensure_upper_parents(rw, trel);
    if (rc != 0) return rc;
    if (unlink(thost) != 0 && errno != ENOENT)
        rmdir(thost);
    if (whiteout_path(rw, trel, twh, sizeof(twh)) == 0)
        unlink(twh);

    if (rename(fhost, thost) != 0) return -errno;

    if (src_lower) {
        rc = whiteout_path(rw, frel, fwh, sizeof(fwh));
        if (rc != 0) return rc;
        rc = ensure_upper_parents(rw, frel);
        if (rc != 0) return rc;
        {
            int fd = open(fwh, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
            if (fd < 0) return -errno;
            close(fd);
        }
    }
    return 0;
}

int tether_fakefs_overlay_readdir(const tether_fakefs_rw *rw, const char *dirpath,
                                  tether_fakefs_dirent_cb cb, void *user)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    tether_fakefs_stat st;
    struct overlay_seen seen = {0};
    struct overlay_merge merge;
    DIR *dp;
    struct dirent *de;
    int rc, lower_rc;

    if (!rw || !dirpath || !cb) return -EINVAL;
    rc = tether_normalize_path(dirpath, rel, sizeof(rel));
    if (rc != 0) return rc;
    rc = tether_fakefs_overlay_stat(rw, rel[0] ? rel : "/", &st);
    if (rc != 0) return rc;
    if (!S_ISDIR(st.mode)) return -ENOTDIR;

    merge.rw = rw;
    merge.cb = cb;
    merge.user = user;
    merge.seen = &seen;
    merge.count = 0;
    merge.stop = 0;
    merge.err = 0;

    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;
    dp = opendir(host);
    if (dp) {
        while ((de = readdir(dp)) != NULL) {
            char full[TETHER_FAKEFS_PATH_MAX];
            struct stat hs;
            tether_fakefs_stat child;
            char childhost[TETHER_FAKEFS_PATH_MAX];
            if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
                continue;
            if (strncmp(de->d_name, ".wh.", 4) == 0) continue;
            if (join_child(rel, de->d_name, full, sizeof(full)) != 0) continue;
            if (join_upper(rw, full, childhost, sizeof(childhost)) != 0) continue;
            if (lstat(childhost, &hs) != 0) continue;
            if (overlay_seen_add(&seen, de->d_name) != 0) {
                closedir(dp);
                overlay_seen_free(&seen);
                return -ENOMEM;
            }
            fill_stat_from_host(&hs, &child);
            merge.count++;
            if (cb(de->d_name, full, &child, user) != 0) {
                merge.stop = 1;
                break;
            }
        }
        closedir(dp);
    } else if (errno != ENOENT) {
        return -errno;
    }

    if (!merge.stop) {
        lower_rc = tether_fakefs_readdir(rw->lower, rel[0] ? rel : "/",
                                         overlay_lower_cb, &merge);
        if (lower_rc < 0 && lower_rc != -ENOENT) {
            overlay_seen_free(&seen);
            return lower_rc;
        }
        if (merge.err != 0) {
            overlay_seen_free(&seen);
            return merge.err;
        }
    }
    overlay_seen_free(&seen);
    return merge.count;
}

int tether_fakefs_overlay_open_fd(tether_fakefs_rw *rw, const char *path,
                                  int flags)
{
    char rel[TETHER_FAKEFS_PATH_MAX];
    char host[TETHER_FAKEFS_PATH_MAX];
    char wh[TETHER_FAKEFS_PATH_MAX];
    tether_fakefs_stat st;
    int fd, rc, writable;

    if (!rw || !path) return -EINVAL;
    rc = tether_normalize_path(path, rel, sizeof(rel));
    if (rc != 0) return rc;
    if (is_whiteout(rw, rel)) return -ENOENT;

    writable = (flags & O_ACCMODE) != O_RDONLY;
    rc = join_upper(rw, rel, host, sizeof(host));
    if (rc != 0) return rc;

    if (writable) {
        if (whiteout_path(rw, rel, wh, sizeof(wh)) == 0)
            unlink(wh);
        rc = tether_fakefs_stat_path(rw->lower, rel, &st);
        if (rc == 0 && S_ISREG(st.mode)) {
            rc = copy_up_file(rw, rel);
            if (rc != 0) return rc;
        } else {
            rc = ensure_upper_parents(rw, rel);
            if (rc != 0) return rc;
        }
        fd = open(host, flags | O_CLOEXEC, 0644);
        return fd >= 0 ? fd : -errno;
    }

    fd = open(host, flags | O_CLOEXEC);
    if (fd >= 0) return fd;
    if (errno != ENOENT) return -errno;
    return tether_fakefs_open_fd(rw->lower, rel);
}
