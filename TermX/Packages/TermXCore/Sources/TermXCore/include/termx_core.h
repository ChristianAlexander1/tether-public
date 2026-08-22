#ifndef TERMX_CORE_H
#define TERMX_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Everything is fd-based. fds are real POSIX fds (pipe or pty slave).
typedef int32_t termx_pid;

typedef struct {
    const char  *cmdline;      // full command line, shell-parsed by TermXCore
    int          stdin_fd, stdout_fd, stderr_fd;
    const char  *cwd;          // absolute POSIX path (already workspace-resolved)
    const char **envp;         // NULL-terminated "KEY=VALUE" array
    bool         interactive;  // true when attached to a pty (isatty must report this)
} termx_spawn_req;

termx_pid termx_spawn(const termx_spawn_req *req);        // async; returns pid or -errno
int       termx_wait(termx_pid pid, int *exit_code);       // blocks calling thread
int       termx_signal(termx_pid pid, int sig);            // SIGINT/SIGTERM/SIGWINCH/SIGKILL
int       termx_run(const termx_spawn_req *req, int *exit_code); // spawn+wait convenience

// Registry (consumed by C4/C6 to add commands):
typedef int (*termx_cmd_main)(int argc, char **argv);
int termx_register_command(const char *name, termx_cmd_main entry);
int termx_register_fallback(  // called when a command isn't found (C6 uses this)
        bool (*can_run)(const char *name),
        int  (*run)(const termx_spawn_req *req));

#ifdef __cplusplus
}
#endif

#endif /* TERMX_CORE_H */
