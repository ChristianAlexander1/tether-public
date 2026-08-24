/*
 * test_tether_wasm.c — test suite for the Tether wasm runner
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Covers the three cases required of the runner — hello.wasm prints and exits
 * 0, a bad path fails with a non-zero status, and a filter reading stdin
 * echoes it back — plus the surrounding behaviour an embedder depends on:
 * argv, environ, exit codes, stream isolation, file access, path containment
 * and repeated runs in one process.
 *
 * Guest output is captured through real pipes rather than a temporary file, so
 * the descriptors the runner receives are the kind an embedder would supply.
 */

#include <errno.h>
#include <pthread.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <signal.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "tether_wasm.h"

static int g_failures = 0;
static int g_checks = 0;
static const char *g_current_test = "";

static void check(bool ok, const char *fmt, ...)
{
    g_checks++;
    if (ok) return;

    g_failures++;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "  FAIL [%s] ", g_current_test);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

#define TEST(name) \
    static void name(void); \
    static void run_##name(void) { g_current_test = #name; printf("- %s\n", #name); name(); } \
    static void name(void)

/* ------------------------------------------------------------------ */
/* helpers                                                              */
/* ------------------------------------------------------------------ */

static const char *sample_dir(void)
{
    const char *dir = getenv("TETHER_WASM_SAMPLE_DIR");
    return (dir && *dir) ? dir : "sample";
}

static char *sample_path(const char *name)
{
    static char buf[4096];
    snprintf(buf, sizeof(buf), "%s/%s", sample_dir(), name);
    return buf;
}

/*
 * Runs a module with `input` on stdin, capturing stdout and stderr.
 *
 * Pipes have a finite buffer, so a guest that outsizes it would block forever
 * if we simply waited for it. Input is written from a forked child and the
 * output pipes are drained after the run, which keeps each direction moving
 * independently for the modest volumes the samples produce.
 */
static int run_capture(const char *module, char *const argv[], int argc,
                       const char *cwd, const char *input,
                       char **out_stdout, char **out_stderr,
                       const tether_wasm_options *options, char **error_out)
{
    int in_pipe[2] = { -1, -1 };
    int out_pipe[2], err_pipe[2];

    if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
        fprintf(stderr, "pipe() failed: %s\n", strerror(errno));
        exit(70);
    }

    pid_t writer = -1;
    if (input) {
        if (pipe(in_pipe) != 0) {
            fprintf(stderr, "pipe() failed: %s\n", strerror(errno));
            exit(70);
        }
        size_t len = strlen(input);
        if (len == 0) {
            close(in_pipe[1]);          /* immediate EOF */
            in_pipe[1] = -1;
        } else {
            writer = fork();
            if (writer == 0) {
                close(in_pipe[0]);
                close(out_pipe[0]); close(out_pipe[1]);
                close(err_pipe[0]); close(err_pipe[1]);
                signal(SIGPIPE, SIG_IGN);
                size_t off = 0;
                while (off < len) {
                    ssize_t n = write(in_pipe[1], input + off, len - off);
                    if (n <= 0) break;
                    off += (size_t)n;
                }
                close(in_pipe[1]);
                _exit(0);
            }
            close(in_pipe[1]);
            in_pipe[1] = -1;
        }
    }

    int rc = tether_wasm_run_opts(module, argv, argc, cwd,
                                  input ? in_pipe[0] : -1,
                                  out_pipe[1], err_pipe[1],
                                  options, error_out);

    /* Close the write ends so the reads below see EOF. */
    close(out_pipe[1]);
    close(err_pipe[1]);
    if (in_pipe[0] >= 0) close(in_pipe[0]);
    if (writer > 0) waitpid(writer, NULL, 0);

    for (int which = 0; which < 2; ++which) {
        int fd = which == 0 ? out_pipe[0] : err_pipe[0];
        char **dst = which == 0 ? out_stdout : out_stderr;

        size_t cap = 4096, len = 0;
        char *buf = (char *)malloc(cap);
        for (;;) {
            if (len + 1024 > cap) { cap *= 2; buf = (char *)realloc(buf, cap); }
            ssize_t n = read(fd, buf + len, cap - len - 1);
            if (n <= 0) break;
            len += (size_t)n;
        }
        buf[len] = '\0';
        close(fd);

        if (dst) *dst = buf; else free(buf);
    }

    return rc;
}

static int run_simple(const char *module, char **out_stdout)
{
    char *module_path = sample_path(module);
    char *argv[] = { module_path };
    return run_capture(module_path, argv, 1, sample_dir(), NULL,
                       out_stdout, NULL, NULL, NULL);
}

/* ------------------------------------------------------------------ */
/* required cases                                                       */
/* ------------------------------------------------------------------ */

/* hello.wasm prints "hello" and exits 0. */
TEST(test_hello_prints_and_exits_zero)
{
    char *out = NULL;
    int rc = run_simple("hello.wasm", &out);

    check(rc == 0, "expected exit 0, got %d", rc);
    check(out && strcmp(out, "hello\n") == 0,
          "expected \"hello\\n\", got \"%s\"", out ? out : "(null)");
    free(out);
}

/* A module path that does not exist fails, without crashing or hanging. */
TEST(test_bad_path_fails)
{
    char *error = NULL;
    int rc = tether_wasm_run_opts("/nonexistent/definitely-not-here.wasm",
                                  NULL, 0, ".", -1, -1, -1, NULL, &error);

    check(rc != 0, "expected non-zero exit for a missing module, got %d", rc);
    check(rc == TETHER_WASM_ERR_LOAD, "expected ERR_LOAD (%d), got %d",
          TETHER_WASM_ERR_LOAD, rc);
    check(error != NULL, "expected a diagnostic message");
    tether_wasm_free(error);

    /* A directory is not a module either. */
    rc = tether_wasm_run("/tmp", NULL, 0, ".", -1, -1, -1);
    check(rc != 0, "expected non-zero exit for a directory, got %d", rc);

    /* Neither is a file that exists but is not wasm. */
    char tmpl[] = "/tmp/tether-notwasm-XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd >= 0) {
        write(fd, "this is not a wasm module", 25);
        close(fd);

        error = NULL;
        rc = tether_wasm_run_opts(tmpl, NULL, 0, ".", -1, -1, -1, NULL, &error);
        check(rc == TETHER_WASM_ERR_COMPILE, "expected ERR_COMPILE (%d), got %d",
              TETHER_WASM_ERR_COMPILE, rc);
        tether_wasm_free(error);
        unlink(tmpl);
    }

    /* An empty path is a caller error, not a load failure. */
    rc = tether_wasm_run("", NULL, 0, ".", -1, -1, -1);
    check(rc == TETHER_WASM_ERR_ARGS, "expected ERR_ARGS (%d), got %d",
          TETHER_WASM_ERR_ARGS, rc);
}

/* echo.wasm reads stdin and writes it back. */
TEST(test_stdin_echo)
{
    const char *input = "the quick brown fox\njumps over the lazy dog\n";
    char *module = sample_path("echo.wasm");
    char *argv[] = { module };

    char *out = NULL;
    int rc = run_capture(module, argv, 1, sample_dir(), input, &out, NULL, NULL, NULL);

    check(rc == 0, "expected exit 0, got %d", rc);
    check(out && strcmp(out, input) == 0,
          "echo mismatch: got \"%s\"", out ? out : "(null)");
    free(out);

    /* Empty stdin yields empty output, not a hang or an error. */
    out = NULL;
    rc = run_capture(module, argv, 1, sample_dir(), "", &out, NULL, NULL, NULL);
    check(rc == 0, "expected exit 0 on empty stdin, got %d", rc);
    check(out && *out == '\0', "expected no output, got \"%s\"", out ? out : "(null)");
    free(out);
}

/* ------------------------------------------------------------------ */
/* behaviour an embedder relies on                                      */
/* ------------------------------------------------------------------ */

/* argv reaches the guest intact. */
TEST(test_args_are_passed)
{
    char *module = sample_path("hello.wasm");
    char *argv[] = { module, (char *)"world", (char *)"and", (char *)"moon" };

    char *out = NULL;
    int rc = run_capture(module, argv, 4, sample_dir(), NULL, &out, NULL, NULL, NULL);

    check(rc == 0, "expected exit 0, got %d", rc);
    check(out && strcmp(out, "hello world and moon\n") == 0,
          "expected \"hello world and moon\\n\", got \"%s\"", out ? out : "(null)");
    free(out);
}

/* proc_exit's status reaches the caller, and stderr stays separate. */
TEST(test_exit_code_and_stderr)
{
    char *module = sample_path("exitcode.wasm");
    char *argv[] = { module, (char *)"7" };

    char *out = NULL, *err = NULL;
    int rc = run_capture(module, argv, 2, sample_dir(), NULL, &out, &err, NULL, NULL);

    check(rc == 7, "expected exit 7, got %d", rc);
    check(err && strcmp(err, "exiting with 7\n") == 0,
          "expected the message on stderr, got \"%s\"", err ? err : "(null)");
    check(out && *out == '\0', "expected stdout to stay empty, got \"%s\"", out ? out : "(null)");
    free(out); free(err);

    /* Exit 0 through the same path. */
    char *argv0[] = { module, (char *)"0" };
    rc = run_capture(module, argv0, 2, sample_dir(), NULL, NULL, NULL, NULL, NULL);
    check(rc == 0, "expected exit 0, got %d", rc);

    /* WASI exit statuses are a byte; 255 must survive round-tripping. */
    char *argv255[] = { module, (char *)"255" };
    rc = run_capture(module, argv255, 2, sample_dir(), NULL, NULL, NULL, NULL, NULL);
    check(rc == 255, "expected exit 255, got %d", rc);
}

/* environ_get exposes exactly what the caller supplied. */
TEST(test_environment)
{
    char *module = sample_path("envcat.wasm");
    char *argv[] = { module };

    char *env[] = { (char *)"TETHER_TEST=1", (char *)"PRODUCT=Tether", NULL };
    tether_wasm_options options;
    memset(&options, 0, sizeof(options));
    options.envp = env;

    char *out = NULL;
    int rc = run_capture(module, argv, 1, sample_dir(), NULL, &out, NULL, &options, NULL);

    check(rc == 0, "expected exit 0, got %d", rc);
    check(out && strstr(out, "TETHER_TEST=1") != NULL, "missing TETHER_TEST in \"%s\"", out ? out : "");
    check(out && strstr(out, "PRODUCT=Tether") != NULL, "missing PRODUCT in \"%s\"", out ? out : "");
    free(out);

    /* With no environment supplied the guest sees none, and in particular
     * does not inherit the host's. */
    setenv("TETHER_HOST_ONLY", "leaked", 1);
    out = NULL;
    rc = run_capture(module, argv, 1, sample_dir(), NULL, &out, NULL, NULL, NULL);
    check(rc == 0, "expected exit 0, got %d", rc);
    check(out && strstr(out, "TETHER_HOST_ONLY") == NULL,
          "host environment leaked into the guest: \"%s\"", out ? out : "");
    free(out);
}

/* path_open, path_filestat_get and fd_read work inside the preopened cwd. */
TEST(test_file_access_in_cwd)
{
    char dir[] = "/tmp/tether-fs-XXXXXX";
    check(mkdtemp(dir) != NULL, "could not create a temp directory");

    char file[4096];
    snprintf(file, sizeof(file), "%s/note.txt", dir);
    const char *contents = "tethered\n";

    FILE *f = fopen(file, "wb");
    check(f != NULL, "could not write the fixture file");
    if (f) { fputs(contents, f); fclose(f); }

    char *module = sample_path("envcat.wasm");
    char *argv[] = { module, (char *)"note.txt" };

    char *out = NULL, *err = NULL;
    int rc = run_capture(module, argv, 2, dir, NULL, &out, &err, NULL, NULL);

    check(rc == 0, "expected exit 0, got %d (stderr: %s)", rc, err ? err : "");
    check(out && strstr(out, "size=9") != NULL,
          "expected the file size from path_filestat_get, got \"%s\"", out ? out : "");
    check(out && strstr(out, contents) != NULL,
          "expected the file contents, got \"%s\"", out ? out : "");
    free(out); free(err);

    unlink(file);
    rmdir(dir);
}

/* A guest cannot reach outside the directory the embedder preopened. */
TEST(test_path_escape_is_refused)
{
    char dir[] = "/tmp/tether-jail-XXXXXX";
    check(mkdtemp(dir) != NULL, "could not create a temp directory");

    /* A file that exists, but one level above the preopened directory. */
    char outside[4096];
    snprintf(outside, sizeof(outside), "%s/../tether-secret.txt", dir);
    FILE *f = fopen(outside, "wb");
    if (f) { fputs("secret\n", f); fclose(f); }

    char *module = sample_path("envcat.wasm");

    char *argv_rel[] = { module, (char *)"../tether-secret.txt" };
    int rc = run_capture(module, argv_rel, 2, dir, NULL, NULL, NULL, NULL, NULL);
    check(rc != 0, "escaping with .. should fail, got %d", rc);

    char *argv_abs[] = { module, (char *)"/etc/passwd" };
    rc = run_capture(module, argv_abs, 2, dir, NULL, NULL, NULL, NULL, NULL);
    check(rc != 0, "reading an absolute host path should fail, got %d", rc);

    unlink(outside);
    rmdir(dir);
}

/* -1 descriptors give an empty stdin and swallow output without failing. */
TEST(test_null_descriptors)
{
    char *module = sample_path("hello.wasm");
    char *argv[] = { module };

    int rc = tether_wasm_run(module, argv, 1, sample_dir(), -1, -1, -1);
    check(rc == 0, "expected exit 0 with no streams attached, got %d", rc);

    /* A filter reading a stdin that was never supplied sees EOF at once. */
    char *echo = sample_path("echo.wasm");
    char *echo_argv[] = { echo };
    rc = tether_wasm_run(echo, echo_argv, 1, sample_dir(), -1, -1, -1);
    check(rc == 0, "expected exit 0 reading an absent stdin, got %d", rc);
}

/* The runner holds no state between runs, so repeats behave identically. */
TEST(test_repeated_runs)
{
    for (int i = 0; i < 5; ++i) {
        char *out = NULL;
        int rc = run_simple("hello.wasm", &out);

        check(rc == 0, "run %d: expected exit 0, got %d", i, rc);
        check(out && strcmp(out, "hello\n") == 0,
              "run %d: expected \"hello\\n\", got \"%s\"", i, out ? out : "(null)");
        free(out);
    }
}

/* argc == 0 still gives the guest an argv[0]. */
TEST(test_default_argv)
{
    char *module = sample_path("hello.wasm");

    char *out = NULL;
    int rc = run_capture(module, NULL, 0, sample_dir(), NULL, &out, NULL, NULL, NULL);

    check(rc == 0, "expected exit 0, got %d", rc);
    check(out && strcmp(out, "hello\n") == 0,
          "expected \"hello\\n\", got \"%s\"", out ? out : "(null)");
    free(out);
}

/* A runaway guest is stopped by the timeout instead of hanging the caller. */
TEST(test_timeout_stops_runaway_guest)
{
    char *module = sample_path("spin.wasm");
    char *argv[] = { module };

    tether_wasm_options options;
    memset(&options, 0, sizeof(options));
    options.timeout_ms = 250;

    time_t started = time(NULL);
    char *error = NULL;
    int rc = tether_wasm_run_opts(module, argv, 1, sample_dir(),
                                  -1, -1, -1, &options, &error);
    double elapsed = difftime(time(NULL), started);

    check(rc == TETHER_WASM_ERR_TIMEOUT, "expected ERR_TIMEOUT (%d), got %d",
          TETHER_WASM_ERR_TIMEOUT, rc);
    check(elapsed < 10, "timeout took too long: %.0fs", elapsed);
    check(error != NULL, "expected a diagnostic message");
    tether_wasm_free(error);

    /* The runner must be reusable afterwards: no interrupt state left armed. */
    char *out = NULL;
    rc = run_simple("hello.wasm", &out);
    check(rc == 0, "expected exit 0 after a timeout, got %d", rc);
    check(out && strcmp(out, "hello\n") == 0,
          "expected \"hello\\n\" after a timeout, got \"%s\"", out ? out : "(null)");
    free(out);
}

/* A cancel flag set from another thread stops the guest. */
static volatile int g_cancel = 0;

static void *cancel_after_delay(void *arg)
{
    (void)arg;
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 200 * 1000 * 1000 };
    nanosleep(&ts, NULL);
    g_cancel = 1;
    return NULL;
}

TEST(test_cancellation)
{
    char *module = sample_path("spin.wasm");
    char *argv[] = { module };

    g_cancel = 0;

    pthread_t canceller;
    check(pthread_create(&canceller, NULL, cancel_after_delay, NULL) == 0,
          "could not start the cancelling thread");

    tether_wasm_options options;
    memset(&options, 0, sizeof(options));
    options.cancel_flag = &g_cancel;
    options.timeout_ms = 15000;      /* backstop so a failure cannot hang CI */

    int rc = tether_wasm_run_opts(module, argv, 1, sample_dir(),
                                  -1, -1, -1, &options, NULL);

    pthread_join(canceller, NULL);

    check(rc == TETHER_WASM_ERR_CANCELLED, "expected ERR_CANCELLED (%d), got %d",
          TETHER_WASM_ERR_CANCELLED, rc);
}

/* A timeout generous enough never fires for a well-behaved command. */
TEST(test_timeout_not_triggered_for_fast_guest)
{
    char *module = sample_path("hello.wasm");
    char *argv[] = { module };

    tether_wasm_options options;
    memset(&options, 0, sizeof(options));
    options.timeout_ms = 30000;

    int rc = tether_wasm_run_opts(module, argv, 1, sample_dir(),
                                  -1, -1, -1, &options, NULL);
    check(rc == 0, "expected exit 0, got %d", rc);
}

/* The version string is present and non-empty. */
TEST(test_version)
{
    const char *v = tether_wasm_version();
    check(v != NULL && *v != '\0', "expected a version string");
}

/* ------------------------------------------------------------------ */

int main(void)
{
    printf("TetherWasm test suite (runner %s)\n", tether_wasm_version());
    printf("samples: %s\n\n", sample_dir());

    /* Fail early and clearly if the samples were never built. */
    struct stat st;
    if (stat(sample_path("hello.wasm"), &st) != 0) {
        fprintf(stderr,
                "error: %s not found.\n"
                "Build the samples first: WASI_SDK_PATH=... sample/build.sh\n",
                sample_path("hello.wasm"));
        return 2;
    }

    run_test_hello_prints_and_exits_zero();
    run_test_bad_path_fails();
    run_test_stdin_echo();
    run_test_args_are_passed();
    run_test_exit_code_and_stderr();
    run_test_environment();
    run_test_file_access_in_cwd();
    run_test_path_escape_is_refused();
    run_test_null_descriptors();
    run_test_repeated_runs();
    run_test_default_argv();
    run_test_timeout_stops_runaway_guest();
    run_test_cancellation();
    run_test_timeout_not_triggered_for_fast_guest();
    run_test_version();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures == 0) printf("PASS\n");
    else printf("FAIL\n");

    return g_failures == 0 ? 0 : 1;
}
