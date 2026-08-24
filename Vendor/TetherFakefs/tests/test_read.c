/*
 * T2 — read a known file's bytes back and compare with the source,
 * including NUL and 0xFF bytes and multi-byte UTF-8; also exercise
 * offset reads and EOF behavior. MIT.
 */
#include "test_common.h"

#include <errno.h>

int main(void)
{
    const char *store = TEST_WORK_DIR "/store_t2";
    tether_fakefs *fs = open_store_built_from_tarball(store);

    unsigned char buf[4096];

    /* whole-file read matches the source bytes exactly */
    ssize_t n = tether_fakefs_read(fs, "bin/hello.txt", buf, sizeof(buf), 0);
    CHECK(n == (ssize_t)sizeof(HELLO_BYTES),
          "read returned %zd, want %zu", n, sizeof(HELLO_BYTES));
    CHECK(memcmp(buf, HELLO_BYTES, sizeof(HELLO_BYTES)) == 0,
          "content mismatch vs source bytes");

    /* stat size agrees */
    tether_fakefs_stat st;
    CHECK(tether_fakefs_stat_path(fs, "bin/hello.txt", &st) == 0, "stat");
    CHECK(st.size == sizeof(HELLO_BYTES), "size %llu, want %zu",
          (unsigned long long)st.size, sizeof(HELLO_BYTES));

    /* offset read */
    n = tether_fakefs_read(fs, "bin/hello.txt", buf, 5, 6);
    CHECK(n == 5 && memcmp(buf, "from ", 5) == 0, "offset read wrong");

    /* read at/after EOF returns 0 */
    n = tether_fakefs_read(fs, "bin/hello.txt", buf, 16, st.size);
    CHECK(n == 0, "EOF read should be 0, got %zd", n);
    n = tether_fakefs_read(fs, "bin/hello.txt", buf, 16, st.size + 100);
    CHECK(n == 0, "past-EOF read should be 0, got %zd", n);

    /* leading slash is accepted */
    n = tether_fakefs_read(fs, "/bin/hello.txt", buf, sizeof(buf), 0);
    CHECK(n == (ssize_t)sizeof(HELLO_BYTES), "leading-slash read failed");

    /* hardlink returns identical content */
    unsigned char buf2[4096];
    ssize_t n1 = tether_fakefs_read(fs, "bin/tool", buf, sizeof(buf), 0);
    ssize_t n2 = tether_fakefs_read(fs, "bin/tool-link", buf2, sizeof(buf2), 0);
    CHECK(n1 > 0 && n1 == n2 && memcmp(buf, buf2, (size_t)n1) == 0,
          "hardlink content mismatch");

    /* errors */
    CHECK(tether_fakefs_read(fs, "no/such/file", buf, 16, 0) == -ENOENT,
          "missing file should be -ENOENT");
    CHECK(tether_fakefs_read(fs, "bin", buf, 16, 0) == -EISDIR,
          "directory read should be -EISDIR");

    tether_fakefs_close(fs);
    printf("T2 read: OK\n");
    return 0;
}
