/*
 * echo.c — sample wasm32-wasi filter for the Tether runner
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Copies stdin to stdout until EOF, exercising fd_read and fd_write against
 * whatever descriptors the embedder supplied.
 */

#include <stdio.h>
#include <unistd.h>

int main(void)
{
    char buf[4096];
    ssize_t n;

    while ((n = read(STDIN_FILENO, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t written = write(STDOUT_FILENO, buf + off, (size_t)(n - off));
            if (written <= 0) return 1;
            off += written;
        }
    }
    return (n < 0) ? 1 : 0;
}
