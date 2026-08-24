/*
 * tether_wasm.c — Tether wasm32-wasi command runner
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Loads a wasm32-wasi command module, links the per-run WASI instance, calls
 * _start, and turns however the guest stopped — clean return, proc_exit, or
 * trap — into a single exit status.
 */

#include "include/tether_wasm.h"
#include "tether_wasi.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "wasm3.h"
/* m3_env.h completes struct M3Runtime, which the public wasm3.h keeps opaque.
 * The runner needs it to set memoryLimit; there is no accessor for that. */
#include "m3_env.h"

#define TETHER_WASM_VERSION_STRING "1.0.0"

/* ------------------------------------------------------------------ */
/* interrupting a running guest                                         */
/* ------------------------------------------------------------------ */

/*
 * wasm3 calls m3_Yield() on every function call and loop back-edge, and treats
 * a non-NULL result as a trap that unwinds the interpreter. The default
 * implementation is a weak symbol returning success, so defining it here
 * overrides it and gives the runner its only means of stopping a guest that
 * would otherwise loop forever.
 *
 * The deadline lives in thread-local storage so concurrent runs each get their
 * own, keeping the promise made in tether_wasm.h.
 */

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L && !defined(__STDC_NO_THREADS__)
#  define TW_THREAD_LOCAL _Thread_local
#elif defined(__GNUC__) || defined(__clang__)
#  define TW_THREAD_LOCAL __thread
#elif defined(_MSC_VER)
#  define TW_THREAD_LOCAL __declspec(thread)
#else
#  define TW_THREAD_LOCAL      /* single-threaded fallback */
#endif

/* Distinct sentinels so the reason survives the unwind. Any non-NULL M3Result
 * is a trap to wasm3; the pointer identity is what we match on. */
static const char *const k_trap_timeout   = "[trap] tether: time limit exceeded";
static const char *const k_trap_cancelled = "[trap] tether: cancelled";

typedef struct tw_interrupt {
    bool                    active;
    struct timespec         deadline;       /* CLOCK_MONOTONIC; tv_sec 0 = none */
    const volatile int     *cancel_flag;
    uint32_t                countdown;      /* clock_gettime is not free       */
} tw_interrupt;

static TW_THREAD_LOCAL tw_interrupt g_interrupt;

/* Checking the clock on every back-edge would dominate the run; sample it
 * every N yields instead, which bounds overrun without measurable cost. */
#define TW_YIELD_CHECK_INTERVAL 2048

M3Result m3_Yield(void)
{
    tw_interrupt *irq = &g_interrupt;
    if (!irq->active) return m3Err_none;

    if (irq->cancel_flag && *irq->cancel_flag) return (M3Result)k_trap_cancelled;

    if (irq->deadline.tv_sec || irq->deadline.tv_nsec) {
        if (irq->countdown-- == 0) {
            irq->countdown = TW_YIELD_CHECK_INTERVAL;

            struct timespec now;
            if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
                if (now.tv_sec > irq->deadline.tv_sec ||
                    (now.tv_sec == irq->deadline.tv_sec &&
                     now.tv_nsec >= irq->deadline.tv_nsec)) {
                    return (M3Result)k_trap_timeout;
                }
            }
        }
    }
    return m3Err_none;
}

static void tw_interrupt_begin(unsigned long timeout_ms, const volatile int *cancel_flag)
{
    tw_interrupt *irq = &g_interrupt;
    memset(irq, 0, sizeof(*irq));

    if (!timeout_ms && !cancel_flag) return;   /* stay on the fast path */

    irq->active = true;
    irq->cancel_flag = cancel_flag;
    irq->countdown = 0;                        /* check on the first yield */

    if (timeout_ms) {
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
            uint64_t ns = (uint64_t)now.tv_nsec + (uint64_t)(timeout_ms % 1000) * 1000000ull;
            irq->deadline.tv_sec = now.tv_sec + (time_t)(timeout_ms / 1000) + (time_t)(ns / 1000000000ull);
            irq->deadline.tv_nsec = (long)(ns % 1000000000ull);
        }
    }
}

static void tw_interrupt_end(void)
{
    memset(&g_interrupt, 0, sizeof(g_interrupt));
}

#define TW_DEFAULT_STACK_BYTES   (256u * 1024u)
#define TW_DEFAULT_MAX_MEMORY    (256u * 1024u * 1024u)
#define TW_MAX_MODULE_BYTES      (256u * 1024u * 1024u)

const char *tether_wasm_version(void) { return TETHER_WASM_VERSION_STRING; }

void tether_wasm_free(char *ptr) { free(ptr); }

/* Builds a caller-owned message; ignored when error_out is NULL. */
static void tw_set_error(char **error_out, const char *fmt, ...)
{
    if (!error_out) return;

    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;

    char *copy = (char *)malloc(strlen(buf) + 1);
    if (copy) {
        strcpy(copy, buf);
        *error_out = copy;
    }
}

/* Reads the whole module into memory: wasm3 requires the bytes to outlive the
 * runtime, and command modules are small enough that mapping buys little. */
static uint8_t *tw_read_file(const char *path, size_t *out_size, const char **why)
{
    FILE *f = fopen(path, "rb");
    if (!f) { *why = strerror(errno); return NULL; }

    struct stat st;
    if (fstat(fileno(f), &st) != 0) { *why = strerror(errno); fclose(f); return NULL; }
    if (S_ISDIR(st.st_mode))        { *why = "is a directory";  fclose(f); return NULL; }
    if (st.st_size <= 0)            { *why = "file is empty";   fclose(f); return NULL; }
    if ((uint64_t)st.st_size > TW_MAX_MODULE_BYTES) {
        *why = "module too large";
        fclose(f);
        return NULL;
    }

    size_t size = (size_t)st.st_size;
    uint8_t *bytes = (uint8_t *)malloc(size);
    if (!bytes) { *why = "out of memory"; fclose(f); return NULL; }

    size_t got = fread(bytes, 1, size, f);
    fclose(f);

    if (got != size) { *why = "short read"; free(bytes); return NULL; }

    *out_size = size;
    return bytes;
}

/* Maps a wasm3 result to a TETHER_WASM_ERR_* code. Distinguishing link
 * failures from genuinely malformed modules gives callers a usable diagnosis. */
static int tw_classify(M3Result r)
{
    if (r == m3Err_moduleNotLinked ||
        r == m3Err_functionLookupFailed ||
        r == m3Err_functionImportMissing) {
        return TETHER_WASM_ERR_LINK;
    }
    if (r == m3Err_mallocFailed) return TETHER_WASM_ERR_OOM;
    return TETHER_WASM_ERR_COMPILE;
}

int tether_wasm_run_opts(const char *wasm_path, char *const argv[], int argc,
                         const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd,
                         const tether_wasm_options *options, char **error_out)
{
    if (error_out) *error_out = NULL;

    if (!wasm_path || !*wasm_path) {
        tw_set_error(error_out, "no module path given");
        return TETHER_WASM_ERR_ARGS;
    }
    if (argc < 0 || (argc > 0 && !argv)) {
        tw_set_error(error_out, "invalid argv/argc");
        return TETHER_WASM_ERR_ARGS;
    }

    size_t stack_bytes = TW_DEFAULT_STACK_BYTES;
    size_t max_memory = TW_DEFAULT_MAX_MEMORY;
    char *const *envp = NULL;
    const char *const *guest_dirs = NULL;
    const char *const *host_dirs = NULL;
    unsigned long timeout_ms = 0;
    const volatile int *cancel_flag = NULL;

    if (options) {
        if (options->stack_bytes)      stack_bytes = options->stack_bytes;
        if (options->max_memory_bytes) max_memory = options->max_memory_bytes;
        envp = options->envp;
        guest_dirs = options->guest_dirs;
        host_dirs = options->host_dirs;
        timeout_ms = options->timeout_ms;
        cancel_flag = options->cancel_flag;
    }

    /* Fall back to the module's filename so the guest always sees an argv[0]. */
    char *fallback_argv[1];
    char *const *effective_argv = argv;
    int effective_argc = argc;
    if (argc == 0) {
        const char *slash = strrchr(wasm_path, '/');
        fallback_argv[0] = (char *)(slash ? slash + 1 : wasm_path);
        effective_argv = fallback_argv;
        effective_argc = 1;
    }

    const char *why = NULL;
    size_t module_size = 0;
    uint8_t *module_bytes = tw_read_file(wasm_path, &module_size, &why);
    if (!module_bytes) {
        tw_set_error(error_out, "cannot read '%s': %s", wasm_path, why ? why : "unknown error");
        return TETHER_WASM_ERR_LOAD;
    }

    int status = TETHER_WASM_ERR_TRAP;
    IM3Environment env = NULL;
    IM3Runtime runtime = NULL;
    IM3Module module = NULL;
    tether_wasi *wasi = NULL;
    bool module_owned = true;   /* until m3_LoadModule succeeds */

    env = m3_NewEnvironment();
    if (!env) {
        tw_set_error(error_out, "out of memory creating wasm environment");
        status = TETHER_WASM_ERR_OOM;
        goto cleanup;
    }

    runtime = m3_NewRuntime(env, (uint32_t)stack_bytes, NULL);
    if (!runtime) {
        tw_set_error(error_out, "out of memory creating wasm runtime");
        status = TETHER_WASM_ERR_OOM;
        goto cleanup;
    }
    runtime->memoryLimit = max_memory;

    M3Result r = m3_ParseModule(env, &module, module_bytes, (uint32_t)module_size);
    if (r) {
        tw_set_error(error_out, "not a valid wasm module: %s", r);
        status = TETHER_WASM_ERR_COMPILE;
        goto cleanup;
    }

    r = m3_LoadModule(runtime, module);
    if (r) {
        tw_set_error(error_out, "cannot load module: %s", r);
        status = tw_classify(r);
        goto cleanup;
    }
    module_owned = false;       /* runtime owns it now */

    const char *wasi_error = NULL;
    wasi = tether_wasi_new(cwd, stdin_fd, stdout_fd, stderr_fd,
                           effective_argv, effective_argc, envp,
                           guest_dirs, host_dirs, &wasi_error);
    if (!wasi) {
        tw_set_error(error_out, "cannot set up wasi: %s",
                     wasi_error ? wasi_error : "unknown error");
        status = TETHER_WASM_ERR_LOAD;
        goto cleanup;
    }

    r = tether_wasi_link(module, wasi);
    if (r) {
        tw_set_error(error_out, "cannot link wasi imports: %s", r);
        status = TETHER_WASM_ERR_LINK;
        goto cleanup;
    }

    /* wasi-libc reactors/commands may carry a start section; run it first so
     * data segments and constructors are in place before _start. */
    r = m3_RunStart(module);
    if (r && r != m3Err_trapExit) {
        tw_set_error(error_out, "module start section failed: %s", r);
        status = TETHER_WASM_ERR_TRAP;
        goto cleanup;
    }
    if (wasi->exited) {
        status = wasi->exit_code;
        goto cleanup;
    }

    IM3Function start = NULL;
    r = m3_FindFunction(&start, runtime, "_start");
    if (r || !start) {
        tw_set_error(error_out,
                     "module has no _start export (not a wasm32-wasi command)");
        status = TETHER_WASM_ERR_NO_ENTRY;
        goto cleanup;
    }

    /* Armed only for the guest's own execution, so a timeout cannot be charged
     * against module parsing or setup. */
    tw_interrupt_begin(timeout_ms, cancel_flag);
    r = m3_CallV(start);
    tw_interrupt_end();

    if (r == (M3Result)k_trap_timeout) {
        tw_set_error(error_out, "timed out after %lu ms", timeout_ms);
        status = TETHER_WASM_ERR_TIMEOUT;
    } else if (r == (M3Result)k_trap_cancelled) {
        tw_set_error(error_out, "cancelled by the host");
        status = TETHER_WASM_ERR_CANCELLED;
    } else if (!r) {
        /* Returned normally: a command that never calls proc_exit exits 0. */
        status = wasi->exited ? wasi->exit_code : 0;
    } else if (r == m3Err_trapExit) {
        /* proc_exit trapped out of the interpreter; our handler recorded the
         * status on the way through. */
        status = wasi->exited ? wasi->exit_code : 0;
    } else {
        M3ErrorInfo info;
        m3_GetErrorInfo(runtime, &info);
        if (info.message && *info.message) {
            tw_set_error(error_out, "%s (%s)", r, info.message);
        } else {
            tw_set_error(error_out, "%s", r);
        }
        status = TETHER_WASM_ERR_TRAP;
    }

cleanup:
    /* Flush the guest's output before the caller inspects the streams. Only
     * real descriptors are synced, and a failure here is not the guest's. */
    if (stdout_fd >= 0) (void)fsync(stdout_fd);
    if (stderr_fd >= 0) (void)fsync(stderr_fd);

    if (wasi) tether_wasi_free(wasi);
    if (module && module_owned) m3_FreeModule(module);
    if (runtime) m3_FreeRuntime(runtime);
    if (env) m3_FreeEnvironment(env);
    free(module_bytes);

    return status;
}

int tether_wasm_run(const char *wasm_path, char *const argv[], int argc,
                    const char *cwd, int stdin_fd, int stdout_fd, int stderr_fd)
{
    return tether_wasm_run_opts(wasm_path, argv, argc, cwd,
                                stdin_fd, stdout_fd, stderr_fd, NULL, NULL);
}
