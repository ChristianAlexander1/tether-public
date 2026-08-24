#!/bin/sh
# FIXTURE: 21_large_stdout
# CATEGORY: stress
# EXPECT_CONTAINS: 10000
# EXPECT_EXIT: 0
# TAGS: offline
#
# Emit 10,000 lines through a pipe and count them. Exercises large buffered
# pipe I/O and pipe throughput under Blink.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'i=0; while [ $i -lt 10000 ]; do echo line$i; i=$((i+1)); done | wc -l'
