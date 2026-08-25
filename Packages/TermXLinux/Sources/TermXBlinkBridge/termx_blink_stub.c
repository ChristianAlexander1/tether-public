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
void termx_blink_terminate(void) {}
int termx_blink_is_busy(void) { return 0; }
void termx_blink_set_host_exec(termx_host_exec_fn fn, void *ctx) {
  (void)fn;
  (void)ctx;
}
void termx_blink_dispatch_reset(void) {}
int termx_blink_dispatch_add(const char *basename) {
  (void)basename;
  return 0;
}
int termx_blink_dispatch_should_proxy(const char *prog) {
  (void)prog;
  return 0;
}

#else

/* Full implementation in termx_blink_bridge.c when linked against blink.a */

#endif
