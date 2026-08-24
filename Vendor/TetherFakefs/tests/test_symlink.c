/*
 * T3 — symlink resolution: relative and absolute targets, readlink,
 * resolve, read-through-symlink, and ELOOP on cycles. MIT.
 */
#include "test_common.h"

#include <errno.h>
#include <sys/stat.h>

int main(void)
{
    const char *store = TEST_WORK_DIR "/store_t3";
    tether_fakefs *fs = open_store_built_from_tarball(store);

    char buf[TETHER_FAKEFS_PATH_MAX];

    /* readlink returns the raw target */
    int n = tether_fakefs_readlink(fs, "lib/libtest.so", buf, sizeof(buf));
    CHECK(n == (int)strlen("libtest.so.1") && strcmp(buf, "libtest.so.1") == 0,
          "readlink relative: got '%s'", buf);

    n = tether_fakefs_readlink(fs, "usr/bin/hello-abs", buf, sizeof(buf));
    CHECK(n > 0 && strcmp(buf, "/bin/hello.txt") == 0,
          "readlink absolute: got '%s'", buf);

    /* readlink on a non-symlink is -EINVAL */
    CHECK(tether_fakefs_readlink(fs, "bin/hello.txt", buf, sizeof(buf)) ==
          -EINVAL, "readlink on regular file should be -EINVAL");

    /* resolve: relative target resolves within its own directory */
    CHECK(tether_fakefs_resolve(fs, "lib/libtest.so", buf, sizeof(buf)) == 0,
          "resolve relative failed");
    CHECK(strcmp(buf, "lib/libtest.so.1") == 0,
          "resolve relative: got '%s', want 'lib/libtest.so.1'", buf);

    /* resolve: absolute target restarts at the fakefs root */
    CHECK(tether_fakefs_resolve(fs, "usr/bin/hello-abs", buf, sizeof(buf)) == 0,
          "resolve absolute failed");
    CHECK(strcmp(buf, "bin/hello.txt") == 0,
          "resolve absolute: got '%s', want 'bin/hello.txt'", buf);

    /* stat_follow lands on the target (a regular file) */
    tether_fakefs_stat st;
    CHECK(tether_fakefs_stat_follow(fs, "usr/bin/hello-abs", &st) == 0,
          "stat_follow failed");
    CHECK(S_ISREG(st.mode) && st.size == sizeof(HELLO_BYTES),
          "stat_follow should see the regular file");

    /* lstat-style stat sees the link itself */
    CHECK(tether_fakefs_stat_path(fs, "usr/bin/hello-abs", &st) == 0,
          "stat_path failed");
    CHECK(S_ISLNK(st.mode), "stat_path should see the symlink");

    /* reading through the symlink yields the target's exact bytes */
    unsigned char content[4096];
    ssize_t r = tether_fakefs_read(fs, "usr/bin/hello-abs",
                                   content, sizeof(content), 0);
    CHECK(r == (ssize_t)sizeof(HELLO_BYTES) &&
          memcmp(content, HELLO_BYTES, sizeof(HELLO_BYTES)) == 0,
          "read through symlink mismatch");

    /* symlink used as an intermediate directory component:
       lib/libtest.so is a file, so traversing through it is -ENOTDIR */
    CHECK(tether_fakefs_resolve(fs, "lib/libtest.so/x", buf, sizeof(buf)) ==
          -ENOTDIR, "file used as directory should be -ENOTDIR");

    /* cycles terminate with -ELOOP */
    CHECK(tether_fakefs_resolve(fs, "usr/bin/loop-a", buf, sizeof(buf)) ==
          -ELOOP, "symlink cycle should be -ELOOP");

    tether_fakefs_close(fs);
    printf("T3 symlink: OK\n");
    return 0;
}
