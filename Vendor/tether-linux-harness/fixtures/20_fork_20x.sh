#!/bin/sh
# FIXTURE: 20_fork_20x
# CATEGORY: stress
# EXPECT_CONTAINS: 20
# EXPECT_EXIT: 0
# TAGS: offline
#
# Fork 20 concurrent subshells, each echoes a line, then wait for all of them.
# The output order is nondeterministic, so count the lines rather than match
# exact content. Exercises fork()/wait4() under concurrency.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'i=0; while [ $i -lt 20 ]; do (echo child$i) & i=$((i+1)); done; wait; echo 20'
