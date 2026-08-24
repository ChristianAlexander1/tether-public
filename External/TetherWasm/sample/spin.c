/*
 * spin.c — sample wasm32-wasi command that never finishes
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Loops forever without syscalls or output. Stands in for a buggy or hostile
 * command so the tests can prove the runner's timeout and cancellation
 * actually interrupt a running guest.
 */

int main(void)
{
    volatile unsigned long long n = 0;
    for (;;) {
        n++;
    }
    return 0;
}
