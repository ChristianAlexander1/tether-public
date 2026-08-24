/*
 * hello.c — sample wasm32-wasi command for the Tether runner
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Prints "hello" and exits 0. With arguments it echoes them, which lets the
 * tests confirm args_get/args_sizes_get as well as fd_write.
 */

#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc <= 1) {
        printf("hello\n");
    } else {
        printf("hello");
        for (int i = 1; i < argc; ++i) printf(" %s", argv[i]);
        printf("\n");
    }
    fflush(stdout);
    return 0;
}
