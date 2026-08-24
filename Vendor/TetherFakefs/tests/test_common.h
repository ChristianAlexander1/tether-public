/* test_common.h — shared helpers for Tether fakefs tests. MIT. */
#ifndef TEST_COMMON_H
#define TEST_COMMON_H

#include "tether_fakefs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Set by CMake: absolute path of tests/data and of the build scratch dir. */
#ifndef TEST_DATA_DIR
#error "TEST_DATA_DIR must be defined"
#endif
#ifndef TEST_WORK_DIR
#error "TEST_WORK_DIR must be defined"
#endif

#define TARBALL   TEST_DATA_DIR "/mini_rootfs.tar.gz"

#define CHECK(cond, ...)                                                  \
    do {                                                                  \
        if (!(cond)) {                                                    \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);          \
            fprintf(stderr, __VA_ARGS__);                                 \
            fprintf(stderr, "\n");                                        \
            exit(1);                                                      \
        }                                                                 \
    } while (0)

/* Known content of bin/hello.txt (must match tests/gen_tarball.py). */
static const unsigned char HELLO_BYTES[] = {
    'H','e','l','l','o',' ','f','r','o','m',' ','T','e','t','h','e','r',
    ' ','f','a','k','e','f','s','!',' ',
    0xf0,0x9f,0x94,0x97,
    ' ','b','i','n','a','r','y','-','s','a','f','e',' ',
    'b','y','t','e','s',':',' ',
    0x00,0x01,0x02,0xff,'\n'
};

static tether_fakefs *open_store_built_from_tarball(const char *store_dir)
{
    char err[512];
    int rc = tether_fakefs_create(TARBALL, store_dir, err, sizeof(err));
    CHECK(rc == 0, "create failed (%d): %s", rc, err);
    tether_fakefs *fs = tether_fakefs_open(store_dir, err, sizeof(err));
    CHECK(fs != NULL, "open failed: %s", err);
    return fs;
}

#endif /* TEST_COMMON_H */
