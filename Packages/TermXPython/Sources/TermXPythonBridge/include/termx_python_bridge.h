#ifndef TERMX_PYTHON_BRIDGE_H
#define TERMX_PYTHON_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Optional override for stdlib when the xcframework `lib/` tree is not on disk (iOS app bundles).
int termx_python_set_stdlib_path(const char *stdlib_path);
/// `xcframework_root` must contain `lib/python3.14` and platform slices.
int termx_python_set_support_root(const char *xcframework_root);

/// Initialize the embedded interpreter (idempotent).
int termx_python_initialize(void);

/// Run `python3` with POSIX stdio fds and environment. Never spawns a child process.
int termx_python_run(int argc, char **argv, const char *cwd,
                     const char *const *envp, int stdin_fd, int stdout_fd, int stderr_fd,
                     int interactive);

/// Request cooperative interruption of the active run (KeyboardInterrupt).
void termx_python_interrupt(void);

int termx_python_is_initialized(void);

#ifdef __cplusplus
}
#endif

#endif /* TERMX_PYTHON_BRIDGE_H */
