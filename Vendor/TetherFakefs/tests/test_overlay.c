/* t5_overlay — copy-up writes, new files, mkdir, whiteout unlink, readdir, rename. MIT. */
#include "test_common.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct name_list {
    char names[32][256];
    int n;
};

static int collect_name(const char *name, const char *full,
                        const tether_fakefs_stat *st, void *user)
{
    struct name_list *list = user;
    (void)full;
    (void)st;
    if (list->n >= 32) return 1;
    snprintf(list->names[list->n], sizeof(list->names[0]), "%s", name);
    list->n++;
    return 0;
}

static int has_name(const struct name_list *list, const char *want)
{
    int i;
    for (i = 0; i < list->n; i++) {
        if (strcmp(list->names[i], want) == 0) return 1;
    }
    return 0;
}

int main(void)
{
    char store[512];
    char upper[512];
    char err[256];
    tether_fakefs_stat st;
    unsigned char buf[128];
    ssize_t n;
    int rc;
    struct name_list names;

    snprintf(store, sizeof(store), "%s/overlay_store_%d", TEST_WORK_DIR, (int)getpid());
    snprintf(upper, sizeof(upper), "%s/overlay_upper_%d", TEST_WORK_DIR, (int)getpid());

    tether_fakefs *lower = open_store_built_from_tarball(store);
    tether_fakefs_close(lower);

    tether_fakefs_rw *rw = tether_fakefs_overlay_open(store, upper, err, sizeof(err));
    CHECK(rw != NULL, "overlay_open failed: %s", err);

    rc = tether_fakefs_overlay_stat(rw, "bin/hello.txt", &st);
    CHECK(rc == 0, "lower stat failed: %d", rc);
    CHECK(st.size == sizeof(HELLO_BYTES), "hello size");

    n = tether_fakefs_overlay_read(rw, "bin/hello.txt", buf, sizeof(buf), 0);
    CHECK(n == (ssize_t)sizeof(HELLO_BYTES), "hello read %zd", n);
    CHECK(memcmp(buf, HELLO_BYTES, sizeof(HELLO_BYTES)) == 0, "hello bytes");

    const char *payload = "apk-layer\n";
    n = tether_fakefs_overlay_write(rw, "bin/hello.txt", payload, strlen(payload), 0);
    CHECK(n == (ssize_t)strlen(payload), "copy-up write %zd", n);
    n = tether_fakefs_overlay_read(rw, "bin/hello.txt", buf, sizeof(buf), 0);
    CHECK(n >= (ssize_t)strlen(payload), "read after write %zd", n);
    CHECK(memcmp(buf, payload, strlen(payload)) == 0, "upper content");

    {
        int fd = tether_fakefs_overlay_open_fd(rw, "bin/hello.txt", O_RDONLY);
        CHECK(fd >= 0, "open_fd read %d", fd);
        n = read(fd, buf, sizeof(buf));
        close(fd);
        CHECK(n >= (ssize_t)strlen(payload), "open_fd read size %zd", n);
        CHECK(memcmp(buf, payload, strlen(payload)) == 0, "open_fd bytes");
    }

    rc = tether_fakefs_overlay_mkdir(rw, "opt/tether", 0755);
    CHECK(rc == 0, "mkdir %d", rc);
    rc = tether_fakefs_overlay_create(rw, "opt/tether/installed", 0644);
    CHECK(rc == 0, "create %d", rc);
    n = tether_fakefs_overlay_write(rw, "opt/tether/installed", "ok\n", 3, 0);
    CHECK(n == 3, "new file write %zd", n);
    n = tether_fakefs_overlay_read(rw, "opt/tether/installed", buf, sizeof(buf), 0);
    CHECK(n == 3 && buf[0] == 'o' && buf[1] == 'k', "new file read");

    memset(&names, 0, sizeof(names));
    rc = tether_fakefs_overlay_readdir(rw, "bin", collect_name, &names);
    CHECK(rc >= 3, "readdir bin count %d", rc);
    CHECK(has_name(&names, "hello.txt"), "bin still lists copied-up hello.txt");
    CHECK(has_name(&names, "tool"), "bin lists lower tool");
    CHECK(has_name(&names, "tool-link"), "bin lists lower tool-link");

    rc = tether_fakefs_overlay_rename(rw, "opt/tether/installed", "opt/tether/moved");
    CHECK(rc == 0, "rename %d", rc);
    rc = tether_fakefs_overlay_stat(rw, "opt/tether/installed", &st);
    CHECK(rc == -ENOENT, "rename source must vanish, got %d", rc);
    n = tether_fakefs_overlay_read(rw, "opt/tether/moved", buf, sizeof(buf), 0);
    CHECK(n == 3 && buf[0] == 'o', "rename dest read");

    memset(&names, 0, sizeof(names));
    rc = tether_fakefs_overlay_readdir(rw, "opt/tether", collect_name, &names);
    CHECK(rc == 1, "readdir after rename count %d", rc);
    CHECK(has_name(&names, "moved"), "readdir shows renamed file");
    CHECK(!has_name(&names, "installed"), "readdir hides old name");

    rc = tether_fakefs_overlay_unlink(rw, "bin/hello.txt");
    CHECK(rc == 0, "unlink %d", rc);
    rc = tether_fakefs_overlay_stat(rw, "bin/hello.txt", &st);
    CHECK(rc == -ENOENT, "whiteout must hide lower file, got %d", rc);

    memset(&names, 0, sizeof(names));
    rc = tether_fakefs_overlay_readdir(rw, "bin", collect_name, &names);
    CHECK(rc >= 2, "readdir after whiteout count %d", rc);
    CHECK(!has_name(&names, "hello.txt"), "whiteout must hide hello.txt from readdir");
    CHECK(!has_name(&names, ".wh.hello.txt"), "whiteout marker must not be listed");
    CHECK(has_name(&names, "tool"), "bin still lists tool after whiteout");

    tether_fakefs_overlay_close(rw);
    printf("PASS t5_overlay\n");
    return 0;
}
