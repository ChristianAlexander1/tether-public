#include "tether_offload.h"

#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

static int node_exec(
    const char *prog, char *const argv[], char *const envp[],
    int stdin_fd, int stdout_fd, int stderr_fd, void *ctx)
{
    int *calls = (int *)ctx;
    (void)argv;
    (void)envp;
    (void)stdin_fd;
    (void)stdout_fd;
    (void)stderr_fd;
    assert(strcmp(prog, "node") == 0);
    ++*calls;
    return 27;
}

static int claude_exec(
    const char *prog, char *const argv[], char *const envp[],
    int stdin_fd, int stdout_fd, int stderr_fd, void *ctx)
{
    (void)prog;
    (void)argv;
    (void)envp;
    (void)stdin_fd;
    (void)stdout_fd;
    (void)stderr_fd;
    (void)ctx;
    return 0;
}

static int replacement_exec(
    const char *prog, char *const argv[], char *const envp[],
    int stdin_fd, int stdout_fd, int stderr_fd, void *ctx)
{
    (void)prog;
    (void)argv;
    (void)envp;
    (void)stdin_fd;
    (void)stdout_fd;
    (void)stderr_fd;
    (void)ctx;
    return 0;
}

int main(void)
{
    tether_offload_entry entry;
    int node_calls = 0;

    tether_offload_clear();

    /* Required: register node, then resolve node. */
    assert(tether_offload_register_basename("node", node_exec, &node_calls) == 0);
    assert(tether_offload_resolve("node") == node_exec);
    assert(tether_offload_resolve("/usr/local/bin/node") == node_exec);

    /* Required: register /usr/bin/claude, then resolve by exact path. */
    assert(tether_offload_register_guest_path(
        "/usr/bin/claude", claude_exec, NULL) == 0);
    assert(tether_offload_resolve("/usr/bin/claude") == claude_exec);
    assert(tether_offload_resolve("claude") == NULL);

    /* Required: unknown programs do not resolve. */
    assert(tether_offload_resolve("unknown") == NULL);

    /* Exact path has priority over basename. */
    assert(tether_offload_register_basename("claude", node_exec, &node_calls) == 0);
    assert(tether_offload_resolve("/usr/bin/claude") == claude_exec);
    assert(tether_offload_resolve("/opt/bin/claude") == node_exec);

    /* Context resolution and execution. */
    assert(tether_offload_resolve_entry("node", &entry) == 0);
    assert(entry.fn == node_exec);
    assert(entry.ctx == &node_calls);
    assert(tether_offload_execute("node", NULL, NULL, 0, 1, 2) == 27);
    assert(node_calls == 1);
    assert(tether_offload_execute("missing", NULL, NULL, 0, 1, 2) ==
        TETHER_OFFLOAD_ENOENT);

    /* Duplicate registration replaces callback and context. */
    assert(tether_offload_register_basename("node", replacement_exec, NULL) == 0);
    assert(tether_offload_resolve("node") == replacement_exec);

    /* Invalid selectors and null callbacks are rejected. */
    assert(tether_offload_register_basename("/bin/node", node_exec, NULL) ==
        TETHER_OFFLOAD_EINVAL);
    assert(tether_offload_register_guest_path("node", node_exec, NULL) ==
        TETHER_OFFLOAD_EINVAL);
    assert(tether_offload_register_basename("node", NULL, NULL) ==
        TETHER_OFFLOAD_EINVAL);

    assert(tether_offload_unregister_guest_path("/usr/bin/claude") == 0);
    assert(tether_offload_resolve("/usr/bin/claude") == node_exec);
    assert(tether_offload_unregister_basename("claude") == 0);
    assert(tether_offload_resolve("/usr/bin/claude") == NULL);

    tether_offload_clear();
    assert(tether_offload_resolve("node") == NULL);

    puts("all tether offload tests passed");
    return 0;
}
