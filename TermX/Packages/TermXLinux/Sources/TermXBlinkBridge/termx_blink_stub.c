#include "termx_blink_bridge.h"

#ifdef TERMX_BLINK_STUB

int termx_blink_is_available(void) { return 0; }
int termx_blink_init(const char *rootfs_prefix) { (void)rootfs_prefix; return -1; }
int termx_blink_mount(const char *host_path, const char *guest_path) {
  (void)host_path; (void)guest_path; return -1;
}
int termx_blink_run(const char *prog, char *const argv[], char *const envp[],
                    int stdin_fd, int stdout_fd, int stderr_fd) {
  (void)prog; (void)argv; (void)envp; (void)stdin_fd; (void)stdout_fd; (void)stderr_fd;
  return -1;
}
void termx_blink_interrupt(void) {}

#else

/* Full implementation in termx_blink_bridge.c when linked against blink.a */

#endif
