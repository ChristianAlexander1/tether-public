#include "termx_core.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#define TERMX_MAX_COMMANDS 256
static struct { char *name; termx_cmd_main entry; } commands[TERMX_MAX_COMMANDS];
static size_t command_count = 0;
static bool (*fallback_can_run)(const char *name) = NULL;
static int (*fallback_run)(const termx_spawn_req *req) = NULL;
static char *next_word(char **cursor) { char *p = *cursor; while (*p && isspace((unsigned char)*p)) p++; if (!*p) { *cursor = p; return NULL; } char *start = p; while (*p && !isspace((unsigned char)*p)) p++; if (*p) *p++ = '\0'; *cursor = p; return start; }
termx_pid termx_spawn(const termx_spawn_req *req) { (void)req; return (termx_pid)-ENOTSUP; }
int termx_wait(termx_pid pid, int *exit_code) { (void)pid; (void)exit_code; return -ENOTSUP; }
int termx_signal(termx_pid pid, int sig) { (void)pid; (void)sig; return -ENOTSUP; }
int termx_register_command(const char *name, termx_cmd_main entry) { if (!name || !*name || !entry) return -EINVAL; for (size_t i = 0; i < command_count; i++) if (strcmp(commands[i].name, name) == 0) { commands[i].entry = entry; return 0; } if (command_count >= TERMX_MAX_COMMANDS) return -ENOSPC; commands[command_count].name = strdup(name); if (!commands[command_count].name) return -ENOMEM; commands[command_count++].entry = entry; return 0; }
int termx_register_fallback(bool (*can_run)(const char *name), int (*run)(const termx_spawn_req *req)) { if (!can_run || !run) return -EINVAL; fallback_can_run = can_run; fallback_run = run; return 0; }
int termx_run(const termx_spawn_req *req, int *exit_code) { if (!req || !req->cmdline || !exit_code) return -EINVAL; char *line = strdup(req->cmdline); if (!line) return -ENOMEM; char *cursor = line; char *name = next_word(&cursor); if (!name) { free(line); return -EINVAL; } for (size_t i = 0; i < command_count; i++) if (strcmp(commands[i].name, name) == 0) { char *argv[128]; int argc = 0; argv[argc++] = name; char *word; while (argc < 127 && (word = next_word(&cursor))) argv[argc++] = word; argv[argc] = NULL; *exit_code = commands[i].entry(argc, argv); free(line); return 0; } if (fallback_can_run && fallback_can_run(name)) { *exit_code = fallback_run(req); free(line); return 0; } free(line); *exit_code = 127; return -ENOENT; }
