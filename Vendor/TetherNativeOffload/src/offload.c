#include "tether_offload.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef enum rule_kind {
    RULE_BASENAME,
    RULE_GUEST_PATH
} rule_kind;

typedef struct rule {
    char *selector;
    tether_host_exec_fn fn;
    void *ctx;
    rule_kind kind;
} rule;

static rule *g_rules;
static size_t g_rule_count;
static size_t g_rule_capacity;
static atomic_flag g_lock = ATOMIC_FLAG_INIT;

static void registry_lock(void)
{
    while (atomic_flag_test_and_set_explicit(&g_lock, memory_order_acquire)) {
        /* Registry operations are short; avoid a platform threading dependency. */
    }
}

static void registry_unlock(void)
{
    atomic_flag_clear_explicit(&g_lock, memory_order_release);
}

static char *copy_string(const char *value)
{
    size_t length = strlen(value) + 1;
    char *copy = (char *)malloc(length);
    if (copy != NULL) {
        memcpy(copy, value, length);
    }
    return copy;
}

static int valid_selector(const char *selector, rule_kind kind)
{
    int has_slash;

    if (selector == NULL || selector[0] == '\0') {
        return 0;
    }
    has_slash = strchr(selector, '/') != NULL;
    return kind == RULE_BASENAME ? !has_slash : has_slash;
}

static int register_rule(
    const char *selector,
    tether_host_exec_fn fn,
    void *ctx,
    rule_kind kind)
{
    size_t i;
    char *selector_copy;

    if (!valid_selector(selector, kind) || fn == NULL) {
        return TETHER_OFFLOAD_EINVAL;
    }

    selector_copy = copy_string(selector);
    if (selector_copy == NULL) {
        return TETHER_OFFLOAD_ENOMEM;
    }

    registry_lock();
    for (i = 0; i < g_rule_count; ++i) {
        if (g_rules[i].kind == kind && strcmp(g_rules[i].selector, selector) == 0) {
            g_rules[i].fn = fn;
            g_rules[i].ctx = ctx;
            registry_unlock();
            free(selector_copy);
            return TETHER_OFFLOAD_OK;
        }
    }

    if (g_rule_count == g_rule_capacity) {
        size_t new_capacity = g_rule_capacity == 0 ? 8 : g_rule_capacity * 2;
        rule *new_rules;

        if (new_capacity < g_rule_capacity ||
            new_capacity > (size_t)-1 / sizeof(*g_rules)) {
            registry_unlock();
            free(selector_copy);
            return TETHER_OFFLOAD_ENOMEM;
        }
        new_rules = (rule *)realloc(g_rules, new_capacity * sizeof(*g_rules));
        if (new_rules == NULL) {
            registry_unlock();
            free(selector_copy);
            return TETHER_OFFLOAD_ENOMEM;
        }
        g_rules = new_rules;
        g_rule_capacity = new_capacity;
    }

    g_rules[g_rule_count].selector = selector_copy;
    g_rules[g_rule_count].fn = fn;
    g_rules[g_rule_count].ctx = ctx;
    g_rules[g_rule_count].kind = kind;
    ++g_rule_count;
    registry_unlock();
    return TETHER_OFFLOAD_OK;
}

int tether_offload_register_basename(
    const char *name,
    tether_host_exec_fn fn,
    void *ctx)
{
    return register_rule(name, fn, ctx, RULE_BASENAME);
}

int tether_offload_register_guest_path(
    const char *guest_path,
    tether_host_exec_fn fn,
    void *ctx)
{
    return register_rule(guest_path, fn, ctx, RULE_GUEST_PATH);
}

int tether_offload_resolve_entry(
    const char *prog,
    tether_offload_entry *out_entry)
{
    const char *basename;
    size_t i;

    if (out_entry == NULL) {
        return TETHER_OFFLOAD_EINVAL;
    }
    out_entry->fn = NULL;
    out_entry->ctx = NULL;
    if (prog == NULL || prog[0] == '\0') {
        return TETHER_OFFLOAD_EINVAL;
    }

    basename = strrchr(prog, '/');
    basename = basename == NULL ? prog : basename + 1;

    registry_lock();

    /* Exact path registrations always win, independent of registration order. */
    for (i = 0; i < g_rule_count; ++i) {
        if (g_rules[i].kind == RULE_GUEST_PATH &&
            strcmp(g_rules[i].selector, prog) == 0) {
            out_entry->fn = g_rules[i].fn;
            out_entry->ctx = g_rules[i].ctx;
            registry_unlock();
            return TETHER_OFFLOAD_OK;
        }
    }

    if (basename[0] != '\0') {
        for (i = 0; i < g_rule_count; ++i) {
            if (g_rules[i].kind == RULE_BASENAME &&
                strcmp(g_rules[i].selector, basename) == 0) {
                out_entry->fn = g_rules[i].fn;
                out_entry->ctx = g_rules[i].ctx;
                registry_unlock();
                return TETHER_OFFLOAD_OK;
            }
        }
    }

    registry_unlock();
    return TETHER_OFFLOAD_ENOENT;
}

tether_host_exec_fn tether_offload_resolve(const char *prog)
{
    tether_offload_entry entry;
    return tether_offload_resolve_entry(prog, &entry) == TETHER_OFFLOAD_OK
        ? entry.fn
        : NULL;
}

int tether_offload_execute(
    const char *prog,
    char *const argv[],
    char *const envp[],
    int stdin_fd,
    int stdout_fd,
    int stderr_fd)
{
    tether_offload_entry entry;
    int result = tether_offload_resolve_entry(prog, &entry);
    if (result != TETHER_OFFLOAD_OK) {
        return result;
    }
    return entry.fn(
        prog, argv, envp, stdin_fd, stdout_fd, stderr_fd, entry.ctx);
}

static int unregister_rule(const char *selector, rule_kind kind)
{
    size_t i;

    if (!valid_selector(selector, kind)) {
        return TETHER_OFFLOAD_EINVAL;
    }

    registry_lock();
    for (i = 0; i < g_rule_count; ++i) {
        if (g_rules[i].kind == kind && strcmp(g_rules[i].selector, selector) == 0) {
            free(g_rules[i].selector);
            --g_rule_count;
            if (i != g_rule_count) {
                g_rules[i] = g_rules[g_rule_count];
            }
            registry_unlock();
            return TETHER_OFFLOAD_OK;
        }
    }
    registry_unlock();
    return TETHER_OFFLOAD_ENOENT;
}

int tether_offload_unregister_basename(const char *name)
{
    return unregister_rule(name, RULE_BASENAME);
}

int tether_offload_unregister_guest_path(const char *guest_path)
{
    return unregister_rule(guest_path, RULE_GUEST_PATH);
}

void tether_offload_clear(void)
{
    size_t i;

    registry_lock();
    for (i = 0; i < g_rule_count; ++i) {
        free(g_rules[i].selector);
    }
    free(g_rules);
    g_rules = NULL;
    g_rule_count = 0;
    g_rule_capacity = 0;
    registry_unlock();
}
