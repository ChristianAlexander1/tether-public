#!/bin/sh
# FIXTURE: 30_pipe_exit_status
# CATEGORY: signals
# EXPECT_CONTAINS: pipecode:1
# EXPECT_EXIT: 0
# TAGS: offline
#
# Pipeline exit status. By default busybox ash returns the exit status of the
# LAST command in the pipeline. `false | true` => 0; `true | false` => 1.
# We assert the latter. (ash does not implement pipefail by default; this
# documents that baseline behavior.)
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'true | false; echo "pipecode:$?"'
