#ifndef TERMX_BLINK_BRIDGE_H_
#define TERMX_BLINK_BRIDGE_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize Blink interpreter mode (no JIT, linear memory off) with an Alpine rootfs prefix.
/// Returns 0 on success, negative errno on failure.
int termx_blink_init(const char *rootfs_prefix);

/// Bind a host directory into the guest tree (e.g. /workspaces).
/// Both paths must be absolute. Returns 0 on success.
int termx_blink_mount(const char *host_path, const char *guest_path);

/// Run a guest ELF program to completion. argv[0] is the guest binary path inside the rootfs.
/// File descriptors are dup'd onto guest stdio when >= 0, then **restored** before return
/// so the caller process does not keep the guest pipes as fd 0/1/2.
/// Returns the guest exit code (0-255) or a negative errno.
int termx_blink_run(const char *prog, char *const argv[], char *const envp[],
                    int stdin_fd, int stdout_fd, int stderr_fd);

/// Run a guest ELF while a login shell already owns the primary machine.
/// Saves and restores `g_machine`, the embedder jmp_buf, and host stdio 0/1/2
/// so a nested spawn (`git`, `/bin/sh -c`, …) cannot replace the login session
/// or steal its PTY. Must not be used as the login-shell entry point.
int termx_blink_run_nested(const char *prog, char *const argv[], char *const envp[],
                           int stdin_fd, int stdout_fd, int stderr_fd);

/// Request cooperative interruption of the running guest (maps to SIGINT delivery).
void termx_blink_interrupt(void);

/// Request cooperative termination of the running guest (maps to SIGTERM delivery).
void termx_blink_terminate(void);

/// Non-zero while a guest program (e.g. the interactive login shell) owns g_machine.
/// Starting another termx_blink_run while busy replaces the machine and crashes the session.
int termx_blink_is_busy(void);

/// Returns non-zero when the embedded Blink static library is linked.
int termx_blink_is_available(void);

/// Optional host callout for binaries that cannot run under Blink (e.g. Claude/Bun,
/// full Node). When set, TermxExec asks the callback before loading a guest ELF;
/// return 0 to accept the callout result in *exit_code_out, or non-zero to fall
/// through to normal Blink emulation.
///
/// The callback always runs on a dedicated parent-process worker thread (never inside
/// a Blink fork child), so Swift/NodeMobile stay safe. stdin/stdout/stderr are the
/// host FDs corresponding to the guest's current stdio (redirect-aware).
typedef int (*termx_host_exec_fn)(const char *prog, char *const argv[],
                                  char *const envp[],
                                  int stdin_fd, int stdout_fd, int stderr_fd,
                                  int *exit_code_out, void *ctx);

void termx_blink_set_host_exec(termx_host_exec_fn fn, void *ctx);

/// Reset manifest-driven host proxy list (default: nothing proxied until entries added).
void termx_blink_dispatch_reset(void);

/// Register a basename (e.g. "node", "xdg-open") that should proxy to host_exec.
/// Returns 0 on success, -1 if the table is full or name is invalid.
int termx_blink_dispatch_add(const char *basename);

/// Non-zero when prog's basename is registered for host proxy (manifest-driven).
int termx_blink_dispatch_should_proxy(const char *prog);

#ifdef __cplusplus
}
#endif

#endif /* TERMX_BLINK_BRIDGE_H_ */
