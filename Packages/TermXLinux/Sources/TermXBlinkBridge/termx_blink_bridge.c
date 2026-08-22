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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "blink/bus.h"
#include "blink/flag.h"
#include "blink/jit.h"
#include "blink/loader.h"
#include "blink/log.h"
#include "blink/machine.h"
#include "blink/map.h"
#include "blink/signal.h"
#include "blink/stats.h"
#include "blink/syscall.h"
#include "blink/util.h"
#include "blink/vfs.h"
#include "blink/web.h"
#include "blink/x86.h"
#include "blink/xlat.h"

static bool g_initialized;
static volatile sig_atomic_t g_interrupted;
static jmp_buf g_exit_jmp;
static int g_guest_exit;

void exit(int status) {
  g_guest_exit = status & 255;
  longjmp(g_exit_jmp, 1);
}

void TerminateSignal(struct Machine *m, int sig, int code) {
  int syssig;
  (void)code;
  KillOtherThreads(m->system);
#ifdef HAVE_JIT
  DisableJit(&m->system->jit);
#endif
  syssig = XlatSignal(sig);
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

  if ((old = g_machine)) KillOtherThreads(old->system);
  unassert((g_machine = m = NewMachine(NewSystem(XED_MACHINE_MODE_LONG), 0)));

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

  g_guest_exit = 1;
  if (setjmp(g_exit_jmp) == 0) {
    Blink(m);
  }
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

  struct sigaction sa;
  signal(SIGPIPE, SIG_IGN);
  sigfillset(&sa.sa_mask);
  sa.sa_flags = 0;
  sa.sa_sigaction = OnSignal;
  sigaction(SIGINT, &sa, 0);
  sigaction(SIGTERM, &sa, 0);

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
  rc = TermxExec(execfn, execfn, mutable_argv, (char **)envp);

cleanup:
  if (mutable_argv) {
    for (int i = 0; i < argc; ++i) {
      if (mutable_argv[i] != execfn) free(mutable_argv[i]);
    }
    free(mutable_argv);
  }
  return rc;
}

void termx_blink_interrupt(void) {
  g_interrupted = 1;
  if (g_machine) {
    raise(SIGINT);
  }
}

#endif /* TERMX_BLINK_STUB */
