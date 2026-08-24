#ifndef TETHER_OFFLOAD_H
#define TETHER_OFFLOAD_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Host callback used to execute a guest-requested program.
 * argv and envp follow execve(2) conventions and may be NULL where supported
 * by the host integration. File descriptors are borrowed for the duration of
 * the call. The callback's return value is returned unchanged by
 * tether_offload_execute().
 */
typedef int (*tether_host_exec_fn)(
    const char *prog,
    char *const argv[],
    char *const envp[],
    int stdin_fd,
    int stdout_fd,
    int stderr_fd,
    void *ctx);

typedef struct tether_offload_entry {
    tether_host_exec_fn fn;
    void *ctx;
} tether_offload_entry;

/* Registration returns 0 on success and a negative TETHER_OFFLOAD_* code. */
enum {
    TETHER_OFFLOAD_OK = 0,
    TETHER_OFFLOAD_EINVAL = -1,
    TETHER_OFFLOAD_ENOMEM = -2,
    TETHER_OFFLOAD_ENOENT = -3
};

/*
 * Register or replace a basename rule. name must be a non-empty basename and
 * therefore must not contain '/'. The registry copies name; ctx is borrowed.
 */
int tether_offload_register_basename(
    const char *name,
    tether_host_exec_fn fn,
    void *ctx);

/*
 * Register or replace an exact guest-path rule. guest_path must be non-empty
 * and contain '/'. The registry copies guest_path; ctx is borrowed.
 */
int tether_offload_register_guest_path(
    const char *guest_path,
    tether_host_exec_fn fn,
    void *ctx);

/*
 * Resolve prog. Exact guest-path rules take priority. If none matches, the
 * final path component is checked against basename rules.
 */
tether_host_exec_fn tether_offload_resolve(const char *prog);

/* Resolve both callback and context. out_entry is cleared on failure. */
int tether_offload_resolve_entry(
    const char *prog,
    tether_offload_entry *out_entry);

/* Resolve and invoke an offload. Returns TETHER_OFFLOAD_ENOENT if unmatched. */
int tether_offload_execute(
    const char *prog,
    char *const argv[],
    char *const envp[],
    int stdin_fd,
    int stdout_fd,
    int stderr_fd);

/* Remove one rule. The selector validation is the same as registration. */
int tether_offload_unregister_basename(const char *name);
int tether_offload_unregister_guest_path(const char *guest_path);

/* Remove all rules. Primarily useful for tests and controlled shutdown. */
void tether_offload_clear(void);

#ifdef __cplusplus
}
#endif

#endif /* TETHER_OFFLOAD_H */
