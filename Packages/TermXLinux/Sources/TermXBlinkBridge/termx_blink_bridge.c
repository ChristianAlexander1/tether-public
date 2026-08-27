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
#include <sys/types.h>
#include <sys/uio.h>
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
static termx_host_exec_fn g_host_exec;
static void *g_host_exec_ctx;
/* Protects bridge-side publication and retirement of Blink's global machine.
 * UI teardown may request a guest signal from a different thread. */
static pthread_mutex_t g_machine_mu = PTHREAD_MUTEX_INITIALIZER;

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
  bool runner = active && pthread_equal(pthread_self(), g_embedded_run_thread);
  if (active && runner) {
    pthread_mutex_lock(&g_machine_mu);
    /* SysExitGroup has already freed the machine before calling exit. */
    g_machine = NULL;
    pthread_mutex_unlock(&g_machine_mu);
    g_guest_exit = status & 255;
    longjmp(g_exit_jmp, 1);
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
  pthread_mutex_lock(&g_machine_mu);
  if (g_machine == m) g_machine = NULL;  /* don't leave a dangling machine */
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

static int TermxExec(char *execfn, char *prog, char **argv, char **envp) {
  int i;
  sigset_t oldmask;
  struct Machine *m, *old;

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
  if ((old = g_machine)) KillOtherThreads(old->system);
  g_machine = m = NewMachine(NewSystem(XED_MACHINE_MODE_LONG), 0);
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

int termx_blink_run(const char *prog, char *const argv[], char *const envp[],
                    int stdin_fd, int stdout_fd, int stderr_fd) {
  char pathbuf[PATH_MAX];
  char *execfn = NULL;
  char **mutable_argv = NULL;
  int argc = 0;
  int rc;

  if (!g_initialized) return -EINVAL;
  if (!prog || !argv || !argv[0]) return -EINVAL;

  g_interrupted = 0;

  if (DupStdio(stdin_fd, stdout_fd, stderr_fd) != 0) {
    return -errno;
  }

  while (argv[argc]) argc++;
  mutable_argv = calloc((size_t)argc + 1, sizeof(char *));
  if (!mutable_argv) return -ENOMEM;
  for (int i = 0; i < argc; ++i) {
    mutable_argv[i] = strdup(argv[i]);
    if (!mutable_argv[i]) {
      rc = -ENOMEM;
      goto cleanup;
    }
  }

  execfn = Commandv(prog, pathbuf, sizeof(pathbuf));
  if (!execfn) {
    rc = -ENOENT;
    goto cleanup;
  }

  mutable_argv[0] = execfn;
  g_guest_exit = 1;
  g_embedded_run_thread = pthread_self();
  atomic_store_explicit(&g_embedded_run_active, true, memory_order_release);
  /* Keep one checkpoint around the whole run. Guest execve recursively calls
   * TermxExec; putting setjmp there would unwind only the innermost exec and
   * resume execution through a machine SysExitGroup has already freed. */
  if (setjmp(g_exit_jmp) == 0) {
    rc = TermxExec(execfn, execfn, mutable_argv, (char **)envp);
  } else {
    rc = g_guest_exit;
  }
  atomic_store_explicit(&g_embedded_run_active, false, memory_order_release);

cleanup:
  if (mutable_argv) {
    for (int i = 0; i < argc; ++i) {
      if (mutable_argv[i] != execfn) free(mutable_argv[i]);
    }
    free(mutable_argv);
  }
  return rc;
}

static void termx_blink_enqueue_signal(int sig) {
  g_interrupted = 1;
  pthread_mutex_lock(&g_machine_mu);
  if (g_machine) {
    /* Queue a Linux guest signal directly. Using raise() here delivered a
     * process signal on the calling (usually UIKit) thread even though Blink's
     * setjmp and machine live on its worker thread, which could terminate the
     * whole app during Close Workspace. */
    EnqueueSignal(g_machine, sig);
  }
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
  busy = g_machine != NULL ? 1 : 0;
  pthread_mutex_unlock(&g_machine_mu);
  return busy;
}

#endif /* TERMX_BLINK_STUB */
