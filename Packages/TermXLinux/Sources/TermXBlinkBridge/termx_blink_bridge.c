/* TermX Blink embedding bridge — ISC (Blink) + TermX */
#include "termx_blink_bridge.h"

#ifndef TERMX_BLINK_STUB

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "blink/bus.h"
#include "blink/fds.h"
#include "blink/flag.h"
#include "blink/jit.h"
#include "blink/loader.h"
#include "blink/log.h"
#include "blink/machine.h"
#include "blink/map.h"
#include "blink/signal.h"
#include "blink/stats.h"
#include "blink/syscall.h"
#include "blink/thread.h"
#include "blink/util.h"
#include "blink/vfs.h"
#include "blink/web.h"
#include "blink/x86.h"
#include "blink/xlat.h"

static bool g_initialized;
static volatile sig_atomic_t g_interrupted;
static jmp_buf g_exit_jmp;
static int g_guest_exit;
/* Blink is a command-line program upstream, so its main guest exits through
 * exit(3). In an embedded app that must unwind to the outer termx_blink_run
 * boundary instead. The release/acquire pair publishes that boundary before
 * the interposed exit can observe an active run. */
static _Atomic bool g_embedded_run_active;
static pthread_t g_embedded_run_thread;
static pid_t g_embedded_run_pid;
static pthread_mutex_t g_nested_mu = PTHREAD_MUTEX_INITIALIZER;
static termx_host_exec_fn g_host_exec;
static void *g_host_exec_ctx;
/* Blink's g_machine is thread-local. Publish the machine that owns the active
 * embedded run separately so UIKit/terminal callbacks on another thread can
 * safely enqueue a guest signal. Both publication and retirement use this
 * lock; a callback must never retain the pointer after unlocking. */
static pthread_mutex_t g_machine_mu = PTHREAD_MUTEX_INITIALIZER;
static struct Machine *g_active_machine;
/* Darwin cannot assign an app-owned PTY as the process controlling terminal.
 * The iOS-only Blink VFS patch calls the hooks below to keep the Linux session
 * and foreground-process-group contract inside the emulator instead.
 *
 * This state lives in a MAP_SHARED page, which is not an optimization: ash sets
 * the foreground group from inside a forked child, and the app parent — where
 * terminal keystrokes arrive — has to see that write. `children` is the live
 * set of guest processes; every fork descendant inherits this same page and
 * records itself, which is what lets teardown reap a whole guest tree the
 * sandbox gives us no other way to enumerate. */
#define TERMX_TTY_MAX_CHILDREN 256
struct TermxTtyState {
  _Atomic int session;
  _Atomic int foreground_pgrp;
  _Atomic int children[TERMX_TTY_MAX_CHILDREN];
};
static struct TermxTtyState g_tty_fallback;
static struct TermxTtyState *g_tty = &g_tty_fallback;
static _Atomic bool g_tty_trace;

/* Parent-only worker: Blink ash fork()+exec would otherwise call Swift/Node
 * inside the child process (unsafe after fork). Requests go over a socketpair. */
static int g_host_exec_req = -1; /* client end (used by TermxExec / fork child) */
static int g_host_exec_srv = -1; /* server end (worker thread) */
static pthread_t g_host_exec_thread;
static pthread_mutex_t g_host_exec_client_mu = PTHREAD_MUTEX_INITIALIZER;
static bool g_host_exec_worker_started;

/* Host-dispatch name table.
 *
 * This is not a fixed policy list: it holds every command the host can run,
 * which includes each CLI the user has installed into a runtime's global bin
 * directory (`npm install -g <anything>`). It therefore grows at runtime and
 * is rebuilt while the guest is live, so it needs both a lock and room to
 * grow — the previous fixed 64-slot array silently dropped everything past
 * the cap and raced with the exec path that reads it. */
#define TERMX_DISPATCH_NAME_MAX 64
static char (*g_dispatch_names)[TERMX_DISPATCH_NAME_MAX];
static int g_dispatch_count;
static int g_dispatch_capacity;
static pthread_mutex_t g_dispatch_mu = PTHREAD_MUTEX_INITIALIZER;

pid_t termx_blink_tty_getsid(void) {
  int sid = atomic_load_explicit(&g_tty->session, memory_order_acquire);
  return sid > 0 ? (pid_t)sid : getsid(0);
}

pid_t termx_blink_tty_getpgrp(void) {
  int pgrp = atomic_load_explicit(&g_tty->foreground_pgrp, memory_order_acquire);
  return pgrp > 0 ? (pid_t)pgrp : getpgrp();
}

int termx_blink_tty_setpgrp(pid_t pgrp) {
  if (pgrp <= 0) {
    errno = EINVAL;
    return -1;
  }
  atomic_store_explicit(&g_tty->foreground_pgrp, (int)pgrp, memory_order_release);
  if (atomic_load_explicit(&g_tty_trace, memory_order_relaxed)) {
    dprintf(STDERR_FILENO, "[tether-tty] foreground pgrp=%d self-pgrp=%d\n",
            (int)pgrp, (int)getpgrp());
  }
  return 0;
}

/* Called by the patched Blink fork() from inside every new guest process,
 * before it runs any guest code.
 *
 * A guest job is a real Darwin process, but it is forked from whatever app
 * thread is running the emulator — a libdispatch worker, which by design has
 * every asynchronous signal blocked so that signals reach the main thread
 * instead. A child inheriting that mask silently defers SIGINT, SIGTERM and
 * SIGTSTP forever, so Ctrl-C could not stop a foreground job no matter which
 * signal the terminal sent; only SIGKILL and SIGSTOP, which cannot be
 * blocked, had any effect. A forked guest process is not part of the app's
 * dispatch machinery and must start from a plain, empty mask, exactly as a
 * child of a real shell would.
 *
 * The pid table lives in the shared page, so a grandchild registers itself
 * where the app parent can see it; iOS gives a sandboxed app no way to
 * enumerate its own descendants, and leaked guest jobs otherwise outlive the
 * workspace. */
void termx_blink_guest_child_started(void) {
  int i;
  int self = (int)getpid();
  sigset_t empty;

  sigemptyset(&empty);
  pthread_sigmask(SIG_SETMASK, &empty, NULL);

  for (i = 0; i < TERMX_TTY_MAX_CHILDREN; ++i) {
    int slot = atomic_load_explicit(&g_tty->children[i], memory_order_acquire);
    if (slot == self) return;
    /* Reclaim a slot whose process is fully gone. A zombie still answers
     * kill(pid, 0), so a job awaiting its parent's wait() keeps its slot. */
    if (slot > 0 && kill((pid_t)slot, 0) == -1 && errno == ESRCH) {
      if (!atomic_compare_exchange_strong_explicit(
              &g_tty->children[i], &slot, 0, memory_order_acq_rel,
              memory_order_relaxed)) {
        continue;
      }
      slot = 0;
    }
    if (slot == 0 &&
        atomic_compare_exchange_strong_explicit(&g_tty->children[i], &slot,
                                                self, memory_order_acq_rel,
                                                memory_order_relaxed)) {
      return;
    }
  }
}

void termx_blink_reap_guest_children(void) {
  int i;
  int round;
  pid_t self = getpid();
  bool traced = atomic_load_explicit(&g_tty_trace, memory_order_relaxed);
  /* SIGCONT first: a stopped job would never act on SIGTERM. Two rounds give
   * a job its own chance to exit before the uncatchable one. */
  for (round = 0; round < 2; ++round) {
    int signalled = 0;
    for (i = 0; i < TERMX_TTY_MAX_CHILDREN; ++i) {
      int pid = atomic_load_explicit(&g_tty->children[i], memory_order_acquire);
      if (pid <= 0 || (pid_t)pid == self) continue;
      if (kill((pid_t)pid, 0) == -1 && errno == ESRCH) {
        atomic_store_explicit(&g_tty->children[i], 0, memory_order_release);
        continue;
      }
      if (round == 0) {
        kill((pid_t)pid, SIGCONT);
        kill((pid_t)pid, SIGTERM);
      } else {
        kill((pid_t)pid, SIGKILL);
      }
      ++signalled;
      if (traced) {
        dprintf(STDERR_FILENO, "[tether-tty] reap pid=%d round=%d\n", pid,
                round);
      }
    }
    if (!signalled) break;
    if (round == 0) {
      /* The jobs exiting raise SIGCHLD, which cuts the wait short; resume it
       * so round 1 really does give them the grace period it promises. */
      struct timespec grace = {0, 150 * 1000 * 1000};
      struct timespec left = grace;
      while (nanosleep(&left, &left) == -1 && errno == EINTR) continue;
    }
  }
  /* Reap by pid, never waitpid(-1): Node and Foundation also spawn children
   * from this process and a wildcard wait would consume their exit statuses.
   * Only direct children are collectable here — deeper descendants were
   * reparented when their own parent exited and belong to init now. */
  for (i = 0; i < TERMX_TTY_MAX_CHILDREN; ++i) {
    int pid = atomic_load_explicit(&g_tty->children[i], memory_order_acquire);
    if (pid <= 0 || (pid_t)pid == self) continue;
    while (waitpid((pid_t)pid, NULL, WNOHANG) == -1 && errno == EINTR) continue;
    if (kill((pid_t)pid, 0) == -1 && errno == ESRCH) {
      atomic_store_explicit(&g_tty->children[i], 0, memory_order_release);
    }
  }
}

static const char *prog_basename(const char *prog) {
  const char *base;
  if (!prog) return NULL;
  base = strrchr(prog, '/');
  return base ? base + 1 : prog;
}

void termx_blink_dispatch_reset(void) {
  pthread_mutex_lock(&g_dispatch_mu);
  g_dispatch_count = 0;
  pthread_mutex_unlock(&g_dispatch_mu);
}

int termx_blink_dispatch_add(const char *basename) {
  int i;
  int rc = 0;
  if (!basename || !basename[0]) return -1;
  if (strlen(basename) >= TERMX_DISPATCH_NAME_MAX) return -1;

  pthread_mutex_lock(&g_dispatch_mu);
  for (i = 0; i < g_dispatch_count; ++i) {
    if (strcmp(g_dispatch_names[i], basename) == 0) {
      pthread_mutex_unlock(&g_dispatch_mu);
      return 0;
    }
  }
  if (g_dispatch_count >= g_dispatch_capacity) {
    int next = g_dispatch_capacity ? g_dispatch_capacity * 2 : 64;
    void *grown = realloc(g_dispatch_names,
                          (size_t)next * TERMX_DISPATCH_NAME_MAX);
    if (!grown) {
      pthread_mutex_unlock(&g_dispatch_mu);
      return -1;
    }
    g_dispatch_names = grown;
    g_dispatch_capacity = next;
  }
  strcpy(g_dispatch_names[g_dispatch_count++], basename);
  rc = 0;
  pthread_mutex_unlock(&g_dispatch_mu);
  return rc;
}

int termx_blink_dispatch_should_proxy(const char *prog) {
  const char *base = prog_basename(prog);
  int i;
  int found = 0;
  if (!base) return 0;
  pthread_mutex_lock(&g_dispatch_mu);
  for (i = 0; i < g_dispatch_count; ++i) {
    if (strcmp(g_dispatch_names[i], base) == 0) { found = 1; break; }
  }
  pthread_mutex_unlock(&g_dispatch_mu);
  return found;
}

#define TERMX_HOST_EXEC_MAGIC 0x54584D48u /* TXMH */

struct HostExecHeader {
  uint32_t magic;
  uint32_t argc;
  uint32_t envc;
  uint32_t prog_len;
  uint32_t argv_bytes;
  uint32_t env_bytes;
};

static int guest_stdio_host_fd(int guest_fd) {
  struct Fd *fd;
  int host = guest_fd;
  if (!g_machine) return guest_fd;
  LOCK(&g_machine->system->fds.lock);
  fd = GetFd(&g_machine->system->fds, guest_fd);
  if (fd) host = fd->fildes;
  UNLOCK(&g_machine->system->fds.lock);
  return host;
}

static ssize_t write_full(int fd, const void *buf, size_t len) {
  const char *p = buf;
  size_t off = 0;
  while (off < len) {
    ssize_t n = write(fd, p + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    off += (size_t)n;
  }
  return (ssize_t)off;
}

static ssize_t read_full(int fd, void *buf, size_t len) {
  char *p = buf;
  size_t off = 0;
  while (off < len) {
    ssize_t n = read(fd, p + off, len - off);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    off += (size_t)n;
  }
  return (ssize_t)off;
}

static int send_header_and_fds(int sock, const struct HostExecHeader *hdr,
                               const int stdio_fds[3]) {
  struct msghdr msg;
  struct iovec iov;
  char cmsgbuf[CMSG_SPACE(sizeof(int) * 3)];
  struct cmsghdr *cmsg;

  memset(&msg, 0, sizeof(msg));
  iov.iov_base = (void *)hdr;
  iov.iov_len = sizeof(*hdr);
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = cmsgbuf;
  msg.msg_controllen = sizeof(cmsgbuf);
  cmsg = CMSG_FIRSTHDR(&msg);
  cmsg->cmsg_level = SOL_SOCKET;
  cmsg->cmsg_type = SCM_RIGHTS;
  cmsg->cmsg_len = CMSG_LEN(sizeof(int) * 3);
  memcpy(CMSG_DATA(cmsg), stdio_fds, sizeof(int) * 3);
  for (;;) {
    ssize_t n = sendmsg(sock, &msg, 0);
    if (n == (ssize_t)sizeof(*hdr)) return 0;
    if (n < 0 && errno == EINTR) continue;
    return -1;
  }
}

static int recv_header_and_fds(int sock, struct HostExecHeader *hdr,
                               int stdio_fds[3]) {
  struct msghdr msg;
  struct iovec iov;
  char cmsgbuf[CMSG_SPACE(sizeof(int) * 3)];
  struct cmsghdr *cmsg;
  ssize_t n;

  memset(&msg, 0, sizeof(msg));
  iov.iov_base = hdr;
  iov.iov_len = sizeof(*hdr);
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = cmsgbuf;
  msg.msg_controllen = sizeof(cmsgbuf);
  for (;;) {
    n = recvmsg(sock, &msg, 0);
    if (n < 0 && errno == EINTR) continue;
    break;
  }
  if (n != (ssize_t)sizeof(*hdr)) return -1;
  cmsg = CMSG_FIRSTHDR(&msg);
  if (!cmsg || cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS ||
      cmsg->cmsg_len < CMSG_LEN(sizeof(int) * 3)) {
    return -1;
  }
  memcpy(stdio_fds, CMSG_DATA(cmsg), sizeof(int) * 3);
  return 0;
}

static char **unpack_strvec(char *blob, uint32_t bytes, uint32_t count) {
  char **vec;
  uint32_t i;
  char *p;
  char *end;

  vec = calloc((size_t)count + 1, sizeof(char *));
  if (!vec) return NULL;
  p = blob;
  end = blob + bytes;
  for (i = 0; i < count; ++i) {
    if (p >= end) {
      free(vec);
      return NULL;
    }
    vec[i] = p;
    p += strlen(p) + 1;
  }
  return vec;
}

static int pack_strvec(char *const *vec, char **out_blob, uint32_t *out_bytes,
                       uint32_t *out_count) {
  size_t total = 0;
  uint32_t count = 0;
  char *blob;
  char *p;
  uint32_t i;

  if (vec) {
    for (count = 0; vec[count]; ++count) {
      total += strlen(vec[count]) + 1;
    }
  }
  blob = malloc(total ? total : 1);
  if (!blob) return -1;
  p = blob;
  for (i = 0; i < count; ++i) {
    size_t n = strlen(vec[i]) + 1;
    memcpy(p, vec[i], n);
    p += n;
  }
  *out_blob = blob;
  *out_bytes = (uint32_t)total;
  *out_count = count;
  return 0;
}

static void *host_exec_worker_main(void *arg) {
  (void)arg;
  for (;;) {
    struct HostExecHeader hdr;
    int stdio_fds[3] = {-1, -1, -1};
    char *prog = NULL;
    char *argv_blob = NULL;
    char *env_blob = NULL;
    char **argv = NULL;
    char **envp = NULL;
    int exit_code = 127;
    int32_t reply;
    size_t payload;

    if (recv_header_and_fds(g_host_exec_srv, &hdr, stdio_fds) != 0) break;
    if (hdr.magic != TERMX_HOST_EXEC_MAGIC) break;

    payload = (size_t)hdr.prog_len + hdr.argv_bytes + hdr.env_bytes;
    prog = malloc(hdr.prog_len ? hdr.prog_len : 1);
    argv_blob = malloc(hdr.argv_bytes ? hdr.argv_bytes : 1);
    env_blob = malloc(hdr.env_bytes ? hdr.env_bytes : 1);
    if (!prog || !argv_blob || !env_blob) goto reply;

    if (read_full(g_host_exec_srv, prog, hdr.prog_len) < 0) goto reply;
    if (hdr.argv_bytes &&
        read_full(g_host_exec_srv, argv_blob, hdr.argv_bytes) < 0) {
      goto reply;
    }
    if (hdr.env_bytes &&
        read_full(g_host_exec_srv, env_blob, hdr.env_bytes) < 0) {
      goto reply;
    }
    (void)payload;

    argv = unpack_strvec(argv_blob, hdr.argv_bytes, hdr.argc);
    envp = unpack_strvec(env_blob, hdr.env_bytes, hdr.envc);
    if (!argv || !envp) goto reply;

    if (g_host_exec) {
      int rc = g_host_exec(prog, argv, envp, stdio_fds[0], stdio_fds[1],
                           stdio_fds[2], &exit_code, g_host_exec_ctx);
      if (rc != 0) exit_code = 127;
    }

  reply:
    reply = (int32_t)(exit_code & 255);
    (void)write_full(g_host_exec_srv, &reply, sizeof(reply));
    if (stdio_fds[0] >= 0) close(stdio_fds[0]);
    if (stdio_fds[1] >= 0 && stdio_fds[1] != stdio_fds[0]) close(stdio_fds[1]);
    if (stdio_fds[2] >= 0 && stdio_fds[2] != stdio_fds[0] &&
        stdio_fds[2] != stdio_fds[1]) {
      close(stdio_fds[2]);
    }
    free(argv);
    free(envp);
    free(prog);
    free(argv_blob);
    free(env_blob);
  }
  return NULL;
}

static int ensure_host_exec_worker(void) {
  int sv[2];
  if (g_host_exec_worker_started) return 0;
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) return -1;
  g_host_exec_srv = sv[0];
  g_host_exec_req = sv[1];
  if (pthread_create(&g_host_exec_thread, NULL, host_exec_worker_main, NULL) !=
      0) {
    close(sv[0]);
    close(sv[1]);
    g_host_exec_srv = g_host_exec_req = -1;
    return -1;
  }
  g_host_exec_worker_started = true;
  return 0;
}

static int proxy_host_exec(const char *prog, char **argv, char **envp,
                           int *exit_code_out) {
  struct HostExecHeader hdr;
  char *argv_blob = NULL;
  char *env_blob = NULL;
  uint32_t argv_bytes = 0, env_bytes = 0, argc = 0, envc = 0;
  int stdio_fds[3] = {-1, -1, -1};
  int32_t reply = 127;
  int rc = -1;
  size_t prog_len;
  bool in_fork_child = g_machine && g_machine->system->isfork;

  if (ensure_host_exec_worker() != 0) return -1;
  if (pack_strvec(argv, &argv_blob, &argv_bytes, &argc) != 0) return -1;
  if (pack_strvec(envp, &env_blob, &env_bytes, &envc) != 0) {
    free(argv_blob);
    return -1;
  }

  prog_len = strlen(prog) + 1;
  memset(&hdr, 0, sizeof(hdr));
  hdr.magic = TERMX_HOST_EXEC_MAGIC;
  hdr.argc = argc;
  hdr.envc = envc;
  hdr.prog_len = (uint32_t)prog_len;
  hdr.argv_bytes = argv_bytes;
  hdr.env_bytes = env_bytes;

  /* Dup so the worker can close its copies without touching guest stdio. */
  stdio_fds[0] = dup(guest_stdio_host_fd(STDIN_FILENO));
  stdio_fds[1] = dup(guest_stdio_host_fd(STDOUT_FILENO));
  stdio_fds[2] = dup(guest_stdio_host_fd(STDERR_FILENO));
  if (stdio_fds[0] < 0 || stdio_fds[1] < 0 || stdio_fds[2] < 0) {
    goto out;
  }

  /* Avoid holding a mutex across fork-child IPC (mutex state after fork). */
  if (!in_fork_child) pthread_mutex_lock(&g_host_exec_client_mu);

  if (send_header_and_fds(g_host_exec_req, &hdr, stdio_fds) != 0) goto unlock;
  if (write_full(g_host_exec_req, prog, prog_len) < 0) goto unlock;
  if (argv_bytes && write_full(g_host_exec_req, argv_blob, argv_bytes) < 0) {
    goto unlock;
  }
  if (env_bytes && write_full(g_host_exec_req, env_blob, env_bytes) < 0) {
    goto unlock;
  }
  if (read_full(g_host_exec_req, &reply, sizeof(reply)) < 0) goto unlock;
  *exit_code_out = (int)reply;
  rc = 0;

unlock:
  if (!in_fork_child) pthread_mutex_unlock(&g_host_exec_client_mu);

out:
  if (stdio_fds[0] >= 0) close(stdio_fds[0]);
  if (stdio_fds[1] >= 0) close(stdio_fds[1]);
  if (stdio_fds[2] >= 0) close(stdio_fds[2]);
  free(argv_blob);
  free(env_blob);
  return rc;
}

void termx_blink_set_host_exec(termx_host_exec_fn fn, void *ctx) {
  g_host_exec = fn;
  g_host_exec_ctx = ctx;
  if (fn) (void)ensure_host_exec_worker();
}

static _Noreturn void termx_blink_finish_guest(int status) {
  bool active = atomic_load_explicit(&g_embedded_run_active, memory_order_acquire);
  bool same_proc = (g_embedded_run_pid != 0 && getpid() == g_embedded_run_pid);
  bool runner = active && same_proc &&
                pthread_equal(pthread_self(), g_embedded_run_thread);
  /* Runtime-gated so it needs no rebuild: SIMCTL_CHILD_TETHER_EXIT_TRACE=1
   * (simulator) or TETHER_EXIT_TRACE=1 turns it on. Silent app termination is
   * invisible to crash reporters, so this is the only way to see which branch
   * ran. */
  if (getenv("TETHER_EXIT_TRACE")) {
    char trace[192];
    int n = snprintf(trace, sizeof trace,
                     "[tether-exit] status=%d active=%d same_proc=%d runner=%d "
                     "-> %s\n",
                     status, (int)active, (int)same_proc, (int)runner,
                     (active && runner)  ? "longjmp(guest)"
                     : (!same_proc)      ? "_exit(fork child)"
                     : active            ? "pthread_exit(thread)"
                                         : "_exit(HOST — KILLS APP)");
    if (n > 0) { ssize_t w = write(2, trace, (size_t)n); (void)w; }
  }
  if (active && runner) {
    pthread_mutex_lock(&g_machine_mu);
    /* SysExitGroup has already freed the machine before calling exit. */
    g_active_machine = NULL;
    g_machine = NULL;
    pthread_mutex_unlock(&g_machine_mu);
    g_guest_exit = status & 255;
    longjmp(g_exit_jmp, 1);
  }

  /* Blink fork() is a real POSIX fork. After fork, pthread_equal still
   * matches the copied embedder thread id, so a longjmp here would jump
   * into the parent's jmp_buf from the child — the pipeline segfault.
   * _exit the child process only. */
  if (!same_proc) {
    _exit(status);
  }

  /* Same iOS process, not the embedder thread: a Blink clone-thread or a
   * fork-child that somehow shares a pid. Never _exit the app. */
  if (active) {
    pthread_exit(NULL);
  }

  /* A host-side exit outside the active guest retains normal libc behavior. */
  _exit(status);
}

_Noreturn void exit(int status) {
  termx_blink_finish_guest(status);
}

void TerminateSignal(struct Machine *m, int sig, int code) {
  int syssig;
  (void)code;
  KillOtherThreads(m->system);
#ifdef HAVE_JIT
  DisableJit(&m->system->jit);
#endif
  syssig = XlatSignal(sig);
  /* A foreground command is a real fork child. Returning through the copied
   * parent checkpoint would re-enter app-side Swift in that child; report the
   * conventional 128+signal status and terminate the child process instead. */
  if (g_embedded_run_pid != 0 && getpid() != g_embedded_run_pid) {
    _exit(128 + (syssig > 0 ? syssig : sig));
  }
  pthread_mutex_lock(&g_machine_mu);
  if (g_active_machine == m) g_active_machine = NULL;
  if (g_machine == m) g_machine = NULL;  /* runner-thread TLS */
  pthread_mutex_unlock(&g_machine_mu);
  FreeMachine(m);
#ifdef HAVE_JIT
  ShutdownJit();
#endif
  g_guest_exit = 128 + (syssig > 0 ? syssig : sig);
  longjmp(g_exit_jmp, 1);
}

static int DupStdio(int stdin_fd, int stdout_fd, int stderr_fd) {
  if (stdin_fd >= 0 && stdin_fd != STDIN_FILENO) {
    if (dup2(stdin_fd, STDIN_FILENO) == -1) return -errno;
  }
  if (stdout_fd >= 0 && stdout_fd != STDOUT_FILENO) {
    if (dup2(stdout_fd, STDOUT_FILENO) == -1) return -errno;
  }
  if (stderr_fd >= 0 && stderr_fd != STDERR_FILENO) {
    if (dup2(stderr_fd, STDERR_FILENO) == -1) return -errno;
  }
  return 0;
}

/* One-shot guest runs dup the caller's pipes onto process 0/1/2. Nested
 * exec already saved/restored those FDs; the outer termx_blink_run did
 * not. C6 then closed its write ends and blocked forever in read()
 * because STDOUT still held the pipe — and apk-to-/dev/null during
 * bootstrap left XCTest output on /dev/null. */
static void blink_restore_stdio(int saved[3]) {
  if (saved[0] >= 0) {
    (void)dup2(saved[0], STDIN_FILENO);
    close(saved[0]);
    saved[0] = -1;
  }
  if (saved[1] >= 0) {
    (void)dup2(saved[1], STDOUT_FILENO);
    close(saved[1]);
    saved[1] = -1;
  }
  if (saved[2] >= 0) {
    (void)dup2(saved[2], STDERR_FILENO);
    close(saved[2]);
    saved[2] = -1;
  }
}

static int blink_save_stdio(int saved[3]) {
  saved[0] = dup(STDIN_FILENO);
  saved[1] = dup(STDOUT_FILENO);
  saved[2] = dup(STDERR_FILENO);
  if (saved[0] < 0 || saved[1] < 0 || saved[2] < 0) {
    blink_restore_stdio(saved);
    return -1;
  }
  return 0;
}

static int TermxExec(char *execfn, char *prog, char **argv, char **envp) {
  int i;
  sigset_t oldmask;
  struct Machine *m, *old;
  bool fork_child;

  if (g_interrupted) return 130;

  /* Manifest-declared platform runtimes are proxied to the parent worker so
   * Swift and embedded engines never execute inside a Blink fork child. */
  if (g_host_exec && termx_blink_dispatch_should_proxy(prog)) {
    int host_code = 127;
    if (proxy_host_exec(prog, argv, envp, &host_code) == 0) {
      return host_code & 255;
    }
  }

  pthread_mutex_lock(&g_machine_mu);
  old = g_machine;
  fork_child = old && old->system->isfork;
  /* A pipeline stage is a real fork child. Killing threads / freeing the
   * machine would UAF the login shell if we were still in the parent;
   * after fork it is the child's private copy, but KillOtherThreads is
   * still the wrong tool — RemoveOtherThreads already ran. */
  if (old && !fork_child) KillOtherThreads(old->system);
  g_machine = m = NewMachine(NewSystem(XED_MACHINE_MODE_LONG), 0);
  g_active_machine = m;
  if (fork_child) m->system->isfork = true;
  pthread_mutex_unlock(&g_machine_mu);
  unassert(m);

#ifdef HAVE_JIT
  DisableJit(&m->system->jit);
#endif

  m->system->exec = TermxExec;
  if (!old) {
    LoadProgram(m, execfn, prog, argv, envp, NULL);
    SetupCod(m);
    for (i = 0; i < 10; ++i) {
      AddStdFd(&m->system->fds, i);
    }
  } else {
#ifdef HAVE_JIT
    DisableJit(&old->system->jit);
#endif
    unassert(!m->sysdepth);
    unassert(!m->pagelocks.i);
    unassert(!FreeVirtual(old->system, -0x800000000000, 0x1000000000000));
    for (i = 1; i <= 64; ++i) {
      if (Read64(old->system->hands[i - 1].handler) == SIG_IGN_LINUX) {
        Write64(m->system->hands[i - 1].handler, SIG_IGN_LINUX);
      }
    }
    memcpy(m->system->rlim, old->system->rlim, sizeof(old->system->rlim));
    LoadProgram(m, execfn, prog, argv, envp, NULL);
    m->system->fds.list = old->system->fds.list;
    old->system->fds.list = 0;
    memcpy(&oldmask, &old->system->exec_sigmask, sizeof(oldmask));
    UNLOCK(&old->system->exec_lock);
    FreeMachine(old);
    unassert(!pthread_sigmask(SIG_SETMASK, &oldmask, 0));
  }

  if (g_interrupted) return 130;

  Blink(m);
  return g_guest_exit;
}

int termx_blink_is_available(void) {
  return 1;
}

int termx_blink_init(const char *rootfs_prefix) {
  struct TermxTtyState *shared_tty;
  if (g_initialized) return 0;
  if (!rootfs_prefix || !*rootfs_prefix) return -EINVAL;

  g_interrupted = 0;
  SetupWeb();
  GetStartDir();
  WriteErrorInit();
  InitMap();

  FLAG_nolinear = true;
  FLAG_prefix = rootfs_prefix;

  if (VfsInit(FLAG_prefix) != 0) {
    return -EIO;
  }

  signal(SIGPIPE, SIG_IGN);

  /* BusyBox ash performs job-control setup from both sides of a real fork.
   * Keep the virtual controlling-terminal state visible to the app parent so
   * terminal keystrokes can target the child foreground group. */
  shared_tty = mmap(NULL, sizeof(*shared_tty), PROT_READ | PROT_WRITE,
                    MAP_SHARED | MAP_ANON, -1, 0);
  if (shared_tty != MAP_FAILED) g_tty = shared_tty;
  memset(g_tty, 0, sizeof(*g_tty));
  atomic_init(&g_tty->session, (int)getsid(0));
  atomic_init(&g_tty->foreground_pgrp, (int)getpgrp());
  atomic_store_explicit(&g_tty_trace, getenv("TETHER_TTY_TRACE") != NULL,
                        memory_order_relaxed);

  InitBus();
  g_initialized = true;
  return 0;
}

int termx_blink_mount(const char *host_path, const char *guest_path) {
  char resolved[PATH_MAX];
  if (!g_initialized) return -EINVAL;
  if (!host_path || !guest_path) return -EINVAL;
  if (!realpath(host_path, resolved)) return -errno;

  if (guest_path[0] == '/' && guest_path[1] != '\0') {
    char parent[PATH_MAX];
    strncpy(parent, guest_path, sizeof(parent) - 1);
    parent[sizeof(parent) - 1] = '\0';
    char *slash = strrchr(parent, '/');
    if (slash && slash != parent) {
      *slash = '\0';
      VfsMkdir(AT_FDCWD, parent, 0755);
    }
  }
  VfsMkdir(AT_FDCWD, guest_path, 0755);

  if (VfsMount(resolved, guest_path, "hostfs", 0, NULL) != 0) {
    return -errno;
  }
  return 0;
}

static int blink_prepare_argv(const char *prog, char *const argv[],
                              char ***out_argv, int *out_argc, char **out_execfn,
                              char pathbuf[PATH_MAX]) {
  int argc = 0;
  char **mutable_argv;
  char *execfn;
  int i;

  while (argv[argc]) argc++;
  mutable_argv = calloc((size_t)argc + 1, sizeof(char *));
  if (!mutable_argv) return -ENOMEM;
  for (i = 0; i < argc; ++i) {
    mutable_argv[i] = strdup(argv[i]);
    if (!mutable_argv[i]) {
      for (int j = 0; j < i; ++j) free(mutable_argv[j]);
      free(mutable_argv);
      return -ENOMEM;
    }
  }
  execfn = Commandv(prog, pathbuf, PATH_MAX);
  if (!execfn) {
    for (i = 0; i < argc; ++i) free(mutable_argv[i]);
    free(mutable_argv);
    return -ENOENT;
  }
  mutable_argv[0] = execfn;
  *out_argv = mutable_argv;
  *out_argc = argc;
  *out_execfn = execfn;
  return 0;
}

static void blink_free_argv(char **mutable_argv, int argc, char *execfn) {
  int i;
  if (!mutable_argv) return;
  for (i = 0; i < argc; ++i) {
    if (mutable_argv[i] != execfn) free(mutable_argv[i]);
  }
  free(mutable_argv);
}

int termx_blink_run(const char *prog, char *const argv[], char *const envp[],
                    int stdin_fd, int stdout_fd, int stderr_fd) {
  char pathbuf[PATH_MAX];
  char *execfn = NULL;
  char **mutable_argv = NULL;
  int argc = 0;
  int rc;
  int saved_stdio[3] = {-1, -1, -1};

  if (!g_initialized) return -EINVAL;
  if (!prog || !argv || !argv[0]) return -EINVAL;

  g_interrupted = 0;

  if (blink_save_stdio(saved_stdio) != 0) {
    return -errno;
  }
  if (DupStdio(stdin_fd, stdout_fd, stderr_fd) != 0) {
    rc = -errno;
    blink_restore_stdio(saved_stdio);
    return rc;
  }

  rc = blink_prepare_argv(prog, argv, &mutable_argv, &argc, &execfn, pathbuf);
  if (rc != 0) {
    blink_restore_stdio(saved_stdio);
    return rc;
  }

  g_guest_exit = 1;
  g_embedded_run_thread = pthread_self();
  g_embedded_run_pid = getpid();
  atomic_store_explicit(&g_embedded_run_active, true, memory_order_release);
  /* Keep one checkpoint around the whole run. Guest execve recursively calls
   * TermxExec; putting setjmp there would unwind only the innermost exec and
   * resume execution through a machine SysExitGroup has already freed. */
  if (setjmp(g_exit_jmp) == 0) {
    rc = TermxExec(execfn, execfn, mutable_argv, (char **)envp);
  } else {
    rc = g_guest_exit;
  }
  pthread_mutex_lock(&g_machine_mu);
  if (g_active_machine == g_machine) g_active_machine = NULL;
  g_machine = NULL;
  pthread_mutex_unlock(&g_machine_mu);
  atomic_store_explicit(&g_embedded_run_active, false, memory_order_release);
  g_embedded_run_pid = 0;
  /* The login shell has returned, so nothing it started is still wanted. Its
   * background jobs would otherwise be reparented to launchd and keep running
   * with the workspace's file descriptors held open. */
  termx_blink_reap_guest_children();
  atomic_store_explicit(&g_tty->foreground_pgrp, (int)getpgrp(),
                        memory_order_release);

  blink_free_argv(mutable_argv, argc, execfn);
  blink_restore_stdio(saved_stdio);
  return rc;
}

int termx_blink_run_nested(const char *prog, char *const argv[], char *const envp[],
                           int stdin_fd, int stdout_fd, int stderr_fd) {
  char pathbuf[PATH_MAX];
  char *execfn = NULL;
  char **mutable_argv = NULL;
  int argc = 0;
  int rc;
  jmp_buf saved_jmp;
  pthread_t saved_thread;
  pid_t saved_pid;
  struct Machine *saved_machine;
  struct Machine *saved_active_machine;
  int saved_stdio[3] = {-1, -1, -1};
  bool saved_active;

  if (!g_initialized) return -EINVAL;
  if (!prog || !argv || !argv[0]) return -EINVAL;

  pthread_mutex_lock(&g_nested_mu);

  if (blink_save_stdio(saved_stdio) != 0) {
    rc = -errno;
    goto restore_stdio;
  }

  if (DupStdio(stdin_fd, stdout_fd, stderr_fd) != 0) {
    rc = -errno;
    goto restore_stdio;
  }

  rc = blink_prepare_argv(prog, argv, &mutable_argv, &argc, &execfn, pathbuf);
  if (rc != 0) goto restore_stdio;

  memcpy(&saved_jmp, &g_exit_jmp, sizeof(jmp_buf));
  saved_thread = g_embedded_run_thread;
  saved_pid = g_embedded_run_pid;
  saved_active = atomic_load_explicit(&g_embedded_run_active, memory_order_acquire);

  pthread_mutex_lock(&g_machine_mu);
  saved_machine = g_machine;
  saved_active_machine = g_active_machine;
  /* Hide the login machine so TermxExec does not KillOtherThreads / FreeMachine
   * it. Nested exec is a private machine; the login shell stays blocked in
   * host_exec until we return. */
  g_machine = NULL;
  g_active_machine = NULL;
  pthread_mutex_unlock(&g_machine_mu);

  g_interrupted = 0;
  g_guest_exit = 1;
  g_embedded_run_thread = pthread_self();
  g_embedded_run_pid = getpid();
  atomic_store_explicit(&g_embedded_run_active, true, memory_order_release);

  if (setjmp(g_exit_jmp) == 0) {
    rc = TermxExec(execfn, execfn, mutable_argv, (char **)envp);
  } else {
    rc = g_guest_exit;
  }

  pthread_mutex_lock(&g_machine_mu);
  g_machine = saved_machine;
  g_active_machine = saved_active_machine;
  pthread_mutex_unlock(&g_machine_mu);

  memcpy(&g_exit_jmp, &saved_jmp, sizeof(jmp_buf));
  g_embedded_run_thread = saved_thread;
  g_embedded_run_pid = saved_pid;
  atomic_store_explicit(&g_embedded_run_active, saved_active, memory_order_release);

  blink_free_argv(mutable_argv, argc, execfn);
  mutable_argv = NULL;

restore_stdio:
  blink_restore_stdio(saved_stdio);
  blink_free_argv(mutable_argv, argc, execfn);
  pthread_mutex_unlock(&g_nested_mu);
  return rc;
}

static void termx_blink_enqueue_signal(int sig) {
  g_interrupted = 1;
  pthread_mutex_lock(&g_machine_mu);
  if (g_active_machine) {
    /* Queue a Linux guest signal directly. Using raise() here delivered a
     * process signal on the calling (usually UIKit) thread even though Blink's
     * setjmp and machine live on its worker thread, which could terminate the
     * whole app during Close Workspace. */
    EnqueueSignal(g_active_machine, sig);
  }
  pthread_mutex_unlock(&g_machine_mu);
}

void termx_blink_terminal_signal(int signal_number) {
  int guest_signal;
  int host_signal = signal_number;
  pid_t foreground;
  pid_t app_pgrp;
  bool traced = atomic_load_explicit(&g_tty_trace, memory_order_relaxed);

  switch (signal_number) {
    case SIGINT:  guest_signal = SIGINT_LINUX; break;
    case SIGQUIT: guest_signal = SIGQUIT_LINUX; break;
    case SIGTSTP:
      guest_signal = SIGTSTP_LINUX;
      /* Ctrl-Z must use the uncatchable host stop. Blink mirrors each guest
       * disposition onto its host process, and a job-control shell ignores
       * SIGTSTP; its forked child inherits that host SIG_IGN before it gets
       * to reset its own dispositions, so a real SIGTSTP is measurably
       * swallowed and the job never stops. Nothing is lost by stopping it
       * outright: a program that wants to handle Ctrl-Z itself clears ISIG,
       * and the UI layer then passes the keystroke through as a byte instead
       * of asking for a terminal signal at all. */
      host_signal = SIGSTOP;
      break;
    default: return;
  }

  foreground = termx_blink_tty_getpgrp();
  app_pgrp = getpgrp();
  if (traced) {
    dprintf(STDERR_FILENO,
            "[tether-tty] signal=%d foreground=%d app-pgrp=%d host=%d\n",
            signal_number, (int)foreground, (int)app_pgrp, host_signal);
  }

  /* Blink runs each guest job in a real Darwin process, and SysSigaction keeps
   * that process's host disposition in sync with the guest's. Signalling the
   * foreground group with the real host signal is therefore exactly what a tty
   * line discipline does: a guest handler runs via Blink's OnSignal, and a
   * guest default action becomes the host default action on the child.
   *
   * A private wake signal cannot replace this. Blink's ExecveBlink blocks
   * every signal across the exec handoff, and any signal with no Linux
   * counterpart stays blocked or ignored in the exec'd child, so it never
   * reaches a handler. Only dispositions Blink itself maintains get through.
   *
   * Never signal the app's own group: the login shell shares this process. */
  if (foreground > 0 && foreground != app_pgrp) {
    if (kill(-foreground, host_signal) == 0) return;
    if (errno != ESRCH) return;
  }

  /* The login shell lives in the app process. Queue its Linux signal directly
   * without setting g_interrupted, which is the whole-run cancellation flag. */
  pthread_mutex_lock(&g_machine_mu);
  if (g_active_machine) EnqueueSignal(g_active_machine, guest_signal);
  pthread_mutex_unlock(&g_machine_mu);
}

void termx_blink_interrupt(void) {
  termx_blink_enqueue_signal(SIGINT_LINUX);
}

void termx_blink_terminate(void) {
  termx_blink_enqueue_signal(SIGTERM_LINUX);
}

int termx_blink_is_busy(void) {
  int busy;
  pthread_mutex_lock(&g_machine_mu);
  busy = g_active_machine != NULL ? 1 : 0;
  pthread_mutex_unlock(&g_machine_mu);
  return busy;
}

#endif /* TERMX_BLINK_STUB */
