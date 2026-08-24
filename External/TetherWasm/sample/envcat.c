/*
 * envcat.c — sample wasm32-wasi command for environment and file access
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * With no arguments prints every environment variable, one per line
 * (environ_get / environ_sizes_get). Given a path it prints the file's size
 * and then its contents (path_filestat_get, path_open, fd_read).
 */

#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

extern char **environ;

int main(int argc, char **argv)
{
    if (argc <= 1) {
        for (char **e = environ; *e; ++e) printf("%s\n", *e);
        fflush(stdout);
        return 0;
    }

    const char *path = argv[1];

    struct stat st;
    if (stat(path, &st) != 0) {
        fprintf(stderr, "stat failed: %s\n", path);
        return 2;
    }
    printf("size=%lld\n", (long long)st.st_size);

    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "open failed: %s\n", path);
        return 3;
    }

    char buf[1024];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) fwrite(buf, 1, n, stdout);

    fclose(f);
    fflush(stdout);
    return 0;
}
