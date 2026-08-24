/*
 * tether_wasm.h — Tether wasm32-wasi command runner (public C API)
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Runs a wasm32-wasi command module to completion on the calling thread and
 * returns its exit status. Everything the guest can observe — argv, environ,
 * working directory, and the three standard streams — is supplied per call, so
 * the runner holds no process-wide state and several runs may be in flight on
 * different threads at once.
 */

#ifndef TETHER_WASM_H
#define TETHER_WASM_H

#include <stddef.h>

#if defined(__cplusplus)
extern "C" {
#endif

/*
 * Exit statuses produced by the runner itself, as opposed to by the guest.
 *
 * A wasm32-wasi command exits with a value in 0..255, so the runner reports its
 * own failures above that range. Callers that only care about success versus
 * failure can simply test for non-zero.
 */
enum {
    TETHER_WASM_OK               = 0,   /* never returned as an error; guest exit 0 */
    TETHER_WASM_ERR_ARGS         = 256, /* invalid arguments from the caller       */
    TETHER_WASM_ERR_LOAD         = 257, /* module file missing/unreadable          */
    TETHER_WASM_ERR_COMPILE      = 258, /* not valid wasm, or uses unsupported features */
    TETHER_WASM_ERR_LINK         = 259, /* imports the runner cannot satisfy       */
    TETHER_WASM_ERR_NO_ENTRY     = 260, /* no _start export: not a wasi command    */
    TETHER_WASM_ERR_TRAP         = 261, /* guest trapped (unreachable, OOB, ...)   */
    TETHER_WASM_ERR_OOM          = 262, /* runner could not allocate               */
    TETHER_WASM_ERR_TIMEOUT      = 263, /* exceeded options.timeout_ms             */
    TETHER_WASM_ERR_CANCELLED    = 264  /* options.cancel_flag was set             */
};

/*
 * Optional tuning. Pass NULL to tether_wasm_run_opts (or use tether_wasm_run)
 * to accept the defaults, which suit ordinary command-line tools.
 */
typedef struct tether_wasm_options {
    /* Linear-memory ceiling in bytes. The guest's own `memory.grow` requests
     * are refused past this point, which the guest sees as an allocation
     * failure rather than a crash. 0 selects the default (256 MiB). */
    size_t   max_memory_bytes;

    /* Interpreter value-stack size in bytes. Deeply recursive guests may need
     * more; 0 selects the default (256 KiB). */
    size_t   stack_bytes;

    /* NULL-terminated array of "KEY=VALUE" strings exposed to the guest via
     * environ_get. NULL means the guest sees an empty environment; the host's
     * own environment is never leaked implicitly. */
    char *const *envp;

    /* Extra host directories to preopen, as NULL-terminated arrays of equal
     * length: guest_dirs[i] is the path the guest sees, host_dirs[i] the
     * directory it resolves to. `cwd` is always preopened as "." and "/", so
     * most callers can leave these NULL. */
    const char *const *guest_dirs;
    const char *const *host_dirs;

    /* Wall-clock limit in milliseconds. A guest still running past it is
     * stopped and the call returns TETHER_WASM_ERR_TIMEOUT. 0 means no limit.
     *
     * Worth setting for untrusted or unfamiliar commands: nothing stops a
     * wasm module from looping forever, and without a limit tether_wasm_run
     * simply never returns. */
    unsigned long timeout_ms;

    /* Cooperative cancellation. When non-NULL, the runner samples *cancel_flag
     * as the guest runs and stops it with TETHER_WASM_ERR_CANCELLED once the
     * value is non-zero. Lets another thread interrupt a long command — for a
     * UI's stop button, say. The flag is only read, never written. */
    const volatile int *cancel_flag;
} tether_wasm_options;

/*
 * Run the wasm32-wasi command at `wasm_path` to completion.
 *
 *   argv        argv[0] is the program name as the guest should see it.
 *               May be NULL when argc is 0, in which case the guest sees a
 *               single argument derived from the module's filename.
 *   argc        number of entries in argv.
 *   cwd         working directory for the guest, preopened as "." and "/".
 *               NULL means the host's current directory. The guest cannot
 *               reach outside the preopened directories.
 *   stdin_fd    host descriptors wired to guest fds 0, 1 and 2. Any may be -1
 *   stdout_fd   to give the guest an empty stdin / discard its output. These
 *   stderr_fd   descriptors are borrowed: the runner never closes them.
 *
 * Returns the guest's exit status (0..255), or one of the TETHER_WASM_ERR_*
 * codes above if the command could not be run. Never returns a negative value.
 *
 * Thread-safe: concurrent calls share no mutable state.
 */
int tether_wasm_run(const char *wasm_path, char *const argv[], int argc,
                    const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd);

/* As tether_wasm_run, with tuning and an optional diagnostic message.
 *
 * When `error_out` is non-NULL it receives a malloc'd, NUL-terminated
 * description of any failure — the caller frees it with tether_wasm_free — or
 * NULL when the command ran to completion. */
int tether_wasm_run_opts(const char *wasm_path, char *const argv[], int argc,
                         const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd,
                         const tether_wasm_options *options, char **error_out);

/* Frees a string returned through `error_out`. Ignores NULL. */
void tether_wasm_free(char *ptr);

/* Runner version, e.g. "1.0.0". Valid for the lifetime of the process. */
const char *tether_wasm_version(void);

#if defined(__cplusplus)
}
#endif

#endif /* TETHER_WASM_H */
