#include "termx_node_bridge.h"

#include <pthread.h>
#include <signal.h>
#include <unistd.h>

#if TARGET_OS_IPHONE
#include <NodeMobile/NodeMobile.h>
#endif

typedef struct {
    int argc;
    char **argv;
    int result;
} termx_node_launch_args_t;

static pthread_t g_node_thread;
static termx_node_launch_args_t g_launch_args;
static volatile int g_node_thread_running = 0;

static void *termx_node_thread_entry(void *ctx) {
    termx_node_launch_args_t *args = (termx_node_launch_args_t *)ctx;
    g_node_thread_running = 1;
#if TARGET_OS_IPHONE
    args->result = node_start(args->argc, args->argv);
#else
    (void)args;
#endif
    g_node_thread_running = 0;
    return NULL;
}

int termx_node_launch(int argc, char **argv) {
#if !TARGET_OS_IPHONE
    (void)argc;
    (void)argv;
    return -1;
#else
    if (g_node_thread_running) {
        return -2;
    }
    g_launch_args.argc = argc;
    g_launch_args.argv = argv;
    g_launch_args.result = -1;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 2 * 1024 * 1024);
    const int rc = pthread_create(&g_node_thread, &attr, termx_node_thread_entry, &g_launch_args);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        return rc;
    }
    usleep(50000);
    return 0;
#endif
}

void termx_node_request_interrupt(void) {
#if TARGET_OS_IPHONE
    if (g_node_thread_running) {
        pthread_kill(g_node_thread, SIGINT);
    }
#else
    /* no-op on host builds */
#endif
}

int termx_node_engine_running(void) {
    return g_node_thread_running ? 1 : 0;
}
