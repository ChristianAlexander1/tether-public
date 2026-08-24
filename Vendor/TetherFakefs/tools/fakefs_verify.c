/*
 * fakefs_verify.c — Tether fakefs CLI: verify a fakefs store's integrity.
 *
 *   fakefs_verify output_dir
 *
 * Checks that every regular file's data file exists and matches its
 * recorded size and CRC-32, and that every symlink has a target.
 * Exit status: 0 = store valid, 1 = problems found or unreadable.
 * MIT licensed.
 */
#include "tether_fakefs.h"

#include <stdio.h>

static void report(const char *path, const char *problem, void *user)
{
    (void)user;
    fprintf(stderr, "fakefs_verify: %s: %s\n", path, problem);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr,
                "Tether fakefs_verify %d.%d — verify a fakefs store\n"
                "usage: %s store_dir\n",
                TETHER_FAKEFS_VERSION_MAJOR, TETHER_FAKEFS_VERSION_MINOR,
                argv[0]);
        return 2;
    }

    char err[512];
    tether_fakefs *fs = tether_fakefs_open(argv[1], err, sizeof(err));
    if (!fs) {
        fprintf(stderr, "fakefs_verify: cannot open store: %s\n", err);
        return 1;
    }

    int bad = tether_fakefs_verify(fs, report, NULL);
    unsigned count = tether_fakefs_count(fs);
    tether_fakefs_close(fs);

    if (bad != 0) {
        fprintf(stderr, "fakefs_verify: FAILED — %d problem(s) in %u entries\n",
                bad, count);
        return 1;
    }
    printf("fakefs_verify: OK — %u entries verified\n", count);
    return 0;
}
