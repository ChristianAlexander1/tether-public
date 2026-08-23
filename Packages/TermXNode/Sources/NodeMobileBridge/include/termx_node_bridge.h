#ifndef TERMX_NODE_BRIDGE_H
#define TERMX_NODE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Start nodejs-mobile on a dedicated 8 MiB stack thread. `argv` must stay alive until
/// `node_start` returns (typically for the lifetime of the process).
int termx_node_launch(int argc, char **argv);

/// Deliver SIGINT to the Node engine thread (cooperative interrupt for the active job).
void termx_node_request_interrupt(void);

/// Non-zero while the Node engine thread is running inside `node_start`.
int termx_node_engine_running(void);

#ifdef __cplusplus
}
#endif

#endif /* TERMX_NODE_BRIDGE_H */
