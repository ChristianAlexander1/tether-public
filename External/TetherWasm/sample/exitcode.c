/*
 * exitcode.c — sample wasm32-wasi command that exits with a chosen status
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Exits with the status given as argv[1] (default 42), writing a line to
 * stderr first. Confirms that proc_exit's code reaches the embedder and that
 * stderr is wired separately from stdout.
 */

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    int code = (argc > 1) ? atoi(argv[1]) : 42;
    fprintf(stderr, "exiting with %d\n", code);
    fflush(stderr);
    return code;
}
