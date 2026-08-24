#!/bin/sh
# FIXTURE: 15_kill0_self
# CATEGORY: signals
# EXPECT_CONTAINS: alive
# EXPECT_EXIT: 0
# TAGS: offline
#
# `kill -0 $$` checks that the calling process exists without sending a
# signal. Exercises getpid() and kill(pid, 0) inside the guest.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'kill -0 $$ && echo alive'
