#!/bin/sh
# FIXTURE: 14_subshell_exit_code
# CATEGORY: signals
# EXPECT_CONTAINS: code=7
# EXPECT_EXIT: 0
# TAGS: offline
#
# A child subshell exits 7; the parent reads $? and prints it. Proves wait
# status propagation from a forked+exec'd child through Blink.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'sh -c "exit 7"; echo code=$?'
