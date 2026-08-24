/*
 * T4 — verify 1000 paths: every data/fNNNN.txt must read back exactly the
 * bytes that were packed, and the store-wide CRC verification must pass.
 * Also proves corruption IS detected (flip one byte -> verify fails). MIT.
 */
#include "test_common.h"

#include <stdio.h>
#include <unistd.h>

static void report(const char *path, const char *problem, void *user)
{
    (void)user;
    fprintf(stderr, "  problem: %s: %s\n", path, problem);
}

int main(void)
{
    const char *store = TEST_WORK_DIR "/store_t4";
    tether_fakefs *fs = open_store_built_from_tarball(store);

    /* 1) read all 1000 paths and compare content byte-for-byte */
    int checked = 0;
    for (int i = 0; i < 1000; i++) {
        char path[64], want[64];
        unsigned char got[256];
        snprintf(path, sizeof(path), "data/f%04d.txt", i);
        int wlen = snprintf(want, sizeof(want),
                            "payload %d for tether fakefs\n", i);

        tether_fakefs_stat st;
        CHECK(tether_fakefs_stat_path(fs, path, &st) == 0, "stat %s", path);
        CHECK(st.size == (uint64_t)wlen, "%s: size %llu want %d",
              path, (unsigned long long)st.size, wlen);

        ssize_t n = tether_fakefs_read(fs, path, got, sizeof(got), 0);
        CHECK(n == wlen, "%s: read %zd want %d", path, n, wlen);
        CHECK(memcmp(got, want, (size_t)wlen) == 0,
              "%s: content mismatch", path);
        checked++;
    }
    CHECK(checked == 1000, "checked %d paths, want 1000", checked);

    /* 2) whole-store integrity verification passes */
    int bad = tether_fakefs_verify(fs, report, NULL);
    CHECK(bad == 0, "verify found %d problems in a fresh store", bad);

    /* 3) corruption is detected: flip one byte in the data file
          backing data/f0500.txt, then verify must report >= 1 problem */
    int fd = tether_fakefs_open_fd(fs, "data/f0500.txt");
    CHECK(fd >= 0, "open_fd failed: %d", fd);
    /* find the real path via /proc so we can reopen it writable */
    char linkbuf[TETHER_FAKEFS_PATH_MAX], proc[64];
    snprintf(proc, sizeof(proc), "/proc/self/fd/%d", fd);
    ssize_t ln = readlink(proc, linkbuf, sizeof(linkbuf) - 1);
    CHECK(ln > 0, "readlink /proc fd failed");
    linkbuf[ln] = '\0';
    close(fd);

    FILE *f = fopen(linkbuf, "r+b");
    CHECK(f != NULL, "cannot reopen data file for corruption test");
    int c = fgetc(f);
    CHECK(c != EOF, "empty data file?");
    fseek(f, 0, SEEK_SET);
    fputc(c ^ 0xFF, f);
    fclose(f);

    bad = tether_fakefs_verify(fs, NULL, NULL);
    CHECK(bad >= 1, "corruption was not detected");

    /* repair it back so reruns start clean */
    f = fopen(linkbuf, "r+b");
    CHECK(f != NULL, "cannot reopen data file for repair");
    fputc(c, f);
    fclose(f);
    CHECK(tether_fakefs_verify(fs, NULL, NULL) == 0, "repair failed");

    tether_fakefs_close(fs);
    printf("T4 verify: OK (1000 paths read + CRC verify + corruption detected)\n");
    return 0;
}
