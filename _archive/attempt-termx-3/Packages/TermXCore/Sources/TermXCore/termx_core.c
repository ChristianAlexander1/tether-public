#define _POSIX_C_SOURCE 200809L
#include "termx_core.h"
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_COMMANDS 256
static termx_command commands[MAX_COMMANDS];
static size_t command_count;
static bool (*fallback_can_run)(const char *name);
static int (*fallback_run)(const termx_spawn_req *req);

termx_pid termx_spawn(const termx_spawn_req *req) {
    if (!req || !req->cmdline || !req->cwd) return -EINVAL;
    pid_t pid = fork();
    if (pid < 0) return -errno;
    if (pid == 0) {
        if (chdir(req->cwd) != 0) _exit(127);
        if (req->stdin_fd >= 0) dup2(req->stdin_fd, STDIN_FILENO);
        if (req->stdout_fd >= 0) dup2(req->stdout_fd, STDOUT_FILENO);
        if (req->stderr_fd >= 0) dup2(req->stderr_fd, STDERR_FILENO);
        if (req->envp) {
            execle("/bin/sh", "sh", "-lc", req->cmdline, (char *)NULL, (char *const *)req->envp);
        } else {
            execl("/bin/sh", "sh", "-lc", req->cmdline, (char *)NULL);
        }
        _exit(127);
    }
    return (termx_pid)pid;
}

int termx_wait(termx_pid pid, int *exit_code) {
    int status;
    pid_t result;
    do { result = waitpid((pid_t)pid, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    if (exit_code) *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : (128 + WTERMSIG(status));
    return 0;
}

int termx_signal(termx_pid pid, int sig) { return kill((pid_t)pid, sig) == 0 ? 0 : -errno; }

int termx_run(const termx_spawn_req *req, int *exit_code) {
    termx_pid pid = termx_spawn(req);
    if (pid < 0) return pid;
    return termx_wait(pid, exit_code);
}

int termx_register_command(const char *name, termx_cmd_main entry) {
    if (!name || !entry || command_count >= MAX_COMMANDS) return -EINVAL;
    commands[command_count++] = (termx_command){ strdup(name), entry };
    return 0;
}

int termx_register_fallback(bool (*can_run)(const char *name), int (*run)(const termx_spawn_req *req)) {
    if (!can_run || !run) return -EINVAL;
    fallback_can_run = can_run; fallback_run = run; return 0;
}

void termx_shutdown(void) {
    for (size_t i = 0; i < command_count; i++) free((void *)commands[i].name);
    command_count = 0; fallback_can_run = NULL; fallback_run = NULL;
}
