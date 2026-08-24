/*
 * tether_wasi.h — per-run WASI instance (internal)
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * One tether_wasi instance backs exactly one tether_wasm_run call. All guest
 * visible state — the descriptor table, argv, environ, preopens and the exit
 * status — lives here and is reached through the import context wasm3 hands to
 * each host function, so nothing is shared between concurrent runs.
 */

#ifndef TETHER_WASI_H
#define TETHER_WASI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <dirent.h>

#include "wasm3.h"
#include "tether_wasi_abi.h"

/* One entry in the guest descriptor table. */
typedef struct tw_fd_entry {
    int             host_fd;    /* underlying host descriptor, -1 if unused    */
    bool            in_use;
    bool            owned;      /* runner opened it, so runner closes it       */
    bool            is_null;    /* sink/EOF stream: caller passed -1           */
    bool            is_preopen;
    tw_filetype_t   filetype;
    tw_rights_t     rights_base;
    tw_rights_t     rights_inheriting;
    char           *guest_path; /* preopen name the guest sees, e.g. "."       */
    DIR            *dir;        /* lazily opened for fd_readdir                */
} tw_fd_entry;

typedef struct tether_wasi {
    tw_fd_entry    *fds;
    uint32_t        fd_count;       /* allocated table slots */

    char *const    *argv;
    uint32_t        argc;
    char *const    *envp;
    uint32_t        envc;

    bool            exited;         /* proc_exit was called  */
    int             exit_code;

    /* Set when a host-side failure needs to surface after the trap unwinds. */
    const char     *fatal;
} tether_wasi;

/* Creates an instance whose fds 0/1/2 are wired to the given host descriptors
 * (-1 meaning an empty/discarding stream) and whose fd 3 and 4 preopen `cwd`
 * as "." and "/". Returns NULL on allocation failure or if cwd cannot be
 * opened, writing a short reason to *error when error is non-NULL. */
tether_wasi *tether_wasi_new(const char *cwd,
                             int stdin_fd, int stdout_fd, int stderr_fd,
                             char *const argv[], int argc,
                             char *const envp[],
                             const char *const *guest_dirs,
                             const char *const *host_dirs,
                             const char **error);

void tether_wasi_free(tether_wasi *wasi);

/* Links the implemented wasi_snapshot_preview1 (and wasi_unstable) imports
 * into a freshly parsed module. Imports the runner does not provide are left
 * unresolved on purpose: wasm3 only reports them if the guest actually needs
 * them, so a module that merely mentions an unsupported call still runs. */
M3Result tether_wasi_link(IM3Module module, tether_wasi *wasi);

#endif /* TETHER_WASI_H */
