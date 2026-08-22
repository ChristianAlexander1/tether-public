#include "termx_core.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct termx_job { termx_pid pid; pthread_t thread; int exit_code; int finished; const termx_spawn_req *req; struct termx_job *next; } termx_job;
static termx_job *jobs = NULL; static termx_pid next_pid = 100; static pthread_mutex_t jobs_lock = PTHREAD_MUTEX_INITIALIZER;
static int (*fallback_run)(const termx_spawn_req*) = NULL; static bool (*fallback_can)(const char*) = NULL;
static void *run_job(void *arg) { termx_job *j=(termx_job*)arg; int code=127; if (fallback_run && fallback_can && fallback_can(j->req->cmdline)) code=fallback_run(j->req); pthread_mutex_lock(&jobs_lock); j->exit_code=code; j->finished=1; pthread_mutex_unlock(&jobs_lock); return NULL; }
termx_pid termx_spawn(const termx_spawn_req *req) { if(!req||!req->cmdline){errno=EINVAL;return -EINVAL;} termx_job *j=(termx_job*)calloc(1,sizeof(*j)); if(!j)return -ENOMEM; pthread_mutex_lock(&jobs_lock); j->pid=++next_pid; j->req=req; j->next=jobs; jobs=j; pthread_mutex_unlock(&jobs_lock); if(pthread_create(&j->thread,NULL,run_job,j)!=0){errno=EAGAIN;return -EAGAIN;} return j->pid; }
int termx_wait(termx_pid pid,int *exit_code){pthread_mutex_lock(&jobs_lock);termx_job *j=jobs;while(j&&j->pid!=pid)j=j->next;pthread_mutex_unlock(&jobs_lock);if(!j)return ESRCH;pthread_join(j->thread,NULL);if(exit_code)*exit_code=j->exit_code;return 0;}
int termx_signal(termx_pid pid,int sig){(void)sig;pthread_mutex_lock(&jobs_lock);termx_job *j=jobs;while(j&&j->pid!=pid)j=j->next;pthread_mutex_unlock(&jobs_lock);return j?0:ESRCH;}
int termx_run(const termx_spawn_req *req,int *exit_code){termx_pid p=termx_spawn(req);if(p<0)return (int)p;return termx_wait(p,exit_code);}
int termx_register_command(const char *name,termx_cmd_main entry){(void)name;(void)entry;return name&&entry?0:EINVAL;}
int termx_register_fallback(bool (*can_run)(const char*),int (*run)(const termx_spawn_req*)){fallback_can=can_run;fallback_run=run;return 0;}
