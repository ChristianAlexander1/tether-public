#ifndef TERMX_CORE_H
#define TERMX_CORE_H
#include <stdint.h>
#include <stdbool.h>
typedef int32_t termx_pid;
typedef struct { const char *cmdline; int stdin_fd; int stdout_fd; int stderr_fd; const char *cwd; const char **envp; bool interactive; } termx_spawn_req;
typedef int (*termx_cmd_main)(int argc, char **argv);
termx_pid termx_spawn(const termx_spawn_req *req);
int termx_wait(termx_pid pid, int *exit_code);
int termx_signal(termx_pid pid, int sig);
int termx_run(const termx_spawn_req *req, int *exit_code);
int termx_register_command(const char *name, termx_cmd_main entry);
int termx_register_fallback(bool (*can_run)(const char *name), int (*run)(const termx_spawn_req *req));
#endif
