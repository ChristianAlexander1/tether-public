/*
 * tether_wasm_cli.c — thin command-line driver for the Tether runner
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Exists so the runner can be exercised from a shell exactly as an embedder
 * would call it:
 *
 *     tether-wasm [--dir DIR] [--env K=V]... MODULE.wasm [args...]
 *
 * Its own stdin/stdout/stderr are handed straight to the guest, so pipes and
 * redirection behave as expected. The process exit status is the guest's;
 * runner failures report 1..N above 255 as described in tether_wasm.h and are
 * mapped onto a shell-visible status here.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tether_wasm.h"

static void usage(FILE *out, const char *prog)
{
    fprintf(out,
        "usage: %s [--dir DIR] [--env KEY=VALUE]... MODULE.wasm [args...]\n"
        "\n"
        "  --dir DIR        working directory for the guest (default: .)\n"
        "  --env KEY=VALUE  add an environment variable (repeatable)\n"
        "  --timeout MS     stop the guest after MS milliseconds (0 = no limit)\n"
        "  --version        print the runner version and exit\n"
        "  --help           print this message\n",
        prog);
}

int main(int argc, char **argv)
{
    const char *prog = argv[0] ? argv[0] : "tether-wasm";
    const char *cwd = ".";
    unsigned long timeout_ms = 0;

    char **envp = NULL;
    int envc = 0;

    int i = 1;
    for (; i < argc; ++i) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(stdout, prog);
            free(envp);
            return 0;
        }
        if (strcmp(argv[i], "--version") == 0) {
            printf("tether-wasm %s\n", tether_wasm_version());
            free(envp);
            return 0;
        }
        if (strcmp(argv[i], "--dir") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --dir needs a value\n", prog); free(envp); return 2; }
            cwd = argv[i];
            continue;
        }
        if (strcmp(argv[i], "--timeout") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --timeout needs a value\n", prog); free(envp); return 2; }
            timeout_ms = strtoul(argv[i], NULL, 10);
            continue;
        }
        if (strcmp(argv[i], "--env") == 0) {
            if (++i >= argc) { fprintf(stderr, "%s: --env needs KEY=VALUE\n", prog); free(envp); return 2; }
            char **grown = (char **)realloc(envp, (size_t)(envc + 2) * sizeof(char *));
            if (!grown) { fprintf(stderr, "%s: out of memory\n", prog); free(envp); return 2; }
            envp = grown;
            envp[envc++] = argv[i];
            envp[envc] = NULL;
            continue;
        }
        if (strcmp(argv[i], "--") == 0) { i++; break; }
        break;                                  /* first non-option: the module */
    }

    if (i >= argc) {
        usage(stderr, prog);
        free(envp);
        return 2;
    }

    const char *module = argv[i];

    /* argv[0] the guest sees is the module path, as a shell would pass it. */
    char *const *guest_argv = &argv[i];
    int guest_argc = argc - i;

    tether_wasm_options options;
    memset(&options, 0, sizeof(options));
    options.envp = envp;
    options.timeout_ms = timeout_ms;

    char *error = NULL;
    int rc = tether_wasm_run_opts(module, guest_argv, guest_argc, cwd,
                                  0, 1, 2, &options, &error);

    if (rc >= TETHER_WASM_ERR_ARGS) {
        fprintf(stderr, "%s: %s\n", prog, error ? error : "failed to run module");
        tether_wasm_free(error);
        free(envp);
        /* Squeeze the runner's own failures into a shell-representable status,
         * following the shell convention of 126/127 for "could not execute". */
        return (rc == TETHER_WASM_ERR_LOAD) ? 127 : 126;
    }

    tether_wasm_free(error);
    free(envp);
    return rc;
}
