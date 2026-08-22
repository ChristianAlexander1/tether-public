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
/// File descriptors are dup'd onto guest stdio when >= 0.
/// Returns the guest exit code (0-255) or a negative errno.
int termx_blink_run(const char *prog, char *const argv[], char *const envp[],
                    int stdin_fd, int stdout_fd, int stderr_fd);

/// Request cooperative interruption of the running guest (maps to SIGINT delivery).
void termx_blink_interrupt(void);

/// Returns non-zero when the embedded Blink static library is linked.
int termx_blink_is_available(void);

#ifdef __cplusplus
}
#endif

#endif /* TERMX_BLINK_BRIDGE_H_ */
