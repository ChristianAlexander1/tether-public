/*
 * T1 — create a fakefs store from the bundled mini tarball; must succeed
 * (exit 0) and the resulting store must open and enumerate entries. MIT.
 */
#include "test_common.h"

#include <sys/stat.h>

int main(void)
{
    const char *store = TEST_WORK_DIR "/store_t1";
    tether_fakefs *fs = open_store_built_from_tarball(store);

    uint32_t n = tether_fakefs_count(fs);
    CHECK(n > 1000, "expected >1000 entries, got %u", n);

    /* index and data dir exist on disk */
    struct stat st;
    CHECK(stat(TEST_WORK_DIR "/store_t1/tetherfs.idx", &st) == 0,
          "tetherfs.idx missing");
    CHECK(stat(TEST_WORK_DIR "/store_t1/data", &st) == 0 && S_ISDIR(st.st_mode),
          "data/ missing");

    /* spot-check metadata of a directory and a device node */
    tether_fakefs_stat fst;
    CHECK(tether_fakefs_stat_path(fs, "bin", &fst) == 0, "stat bin");
    CHECK(S_ISDIR(fst.mode), "bin should be a directory");

    CHECK(tether_fakefs_stat_path(fs, "dev/null", &fst) == 0, "stat dev/null");
    CHECK(S_ISCHR(fst.mode), "dev/null should be a char device");
    CHECK(fst.rdev != 0, "dev/null should have a device number");

    /* hardlink shares inode and reports nlink 2 */
    tether_fakefs_stat a, b;
    CHECK(tether_fakefs_stat_path(fs, "bin/tool", &a) == 0, "stat bin/tool");
    CHECK(tether_fakefs_stat_path(fs, "bin/tool-link", &b) == 0,
          "stat bin/tool-link");
    CHECK(a.inode == b.inode, "hardlink must share inode");
    CHECK(a.nlink == 2 && b.nlink == 2, "nlink should be 2, got %u/%u",
          a.nlink, b.nlink);

    tether_fakefs_close(fs);
    printf("T1 create: OK (%u entries)\n", n);
    return 0;
}
