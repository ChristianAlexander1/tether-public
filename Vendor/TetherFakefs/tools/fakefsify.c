/*
 * fakefsify.c — Tether fakefs CLI: pack a tar.gz rootfs into a fakefs store.
 *
 *   fakefsify input.tar.gz output_dir
 *
 * Exit status: 0 on success, 1 on failure. MIT licensed.
 */
#include "tether_fakefs.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr,
                "Tether fakefsify %d.%d — pack a tar.gz rootfs into a fakefs store\n"
                "usage: %s input.tar.gz output_dir\n",
                TETHER_FAKEFS_VERSION_MAJOR, TETHER_FAKEFS_VERSION_MINOR,
                argv[0]);
        return 2;
    }

    char err[512];
    int rc = tether_fakefs_create(argv[1], argv[2], err, sizeof(err));
    if (rc != 0) {
        fprintf(stderr, "fakefsify: %s (error %d)\n",
                err[0] ? err : "failed", rc);
        return 1;
    }

    /* Report a short summary. */
    tether_fakefs *fs = tether_fakefs_open(argv[2], err, sizeof(err));
    if (!fs) {
        fprintf(stderr, "fakefsify: store written but reopen failed: %s\n", err);
        return 1;
    }
    printf("fakefsify: OK — %u entries packed into %s\n",
           tether_fakefs_count(fs), argv[2]);
    tether_fakefs_close(fs);
    return 0;
}
