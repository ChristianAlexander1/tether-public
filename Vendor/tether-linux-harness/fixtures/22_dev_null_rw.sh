#!/bin/sh
# FIXTURE: 22_dev_null_rw
# CATEGORY: stress
# EXPECT_CONTAINS: nullok
# EXPECT_EXIT: 0
# TAGS: offline
#
# Write to and read from /dev/null. Requires Blink built WITH --enable-vfs so
# /dev/null is a real char device (1:3); the minirootfs ships it as a plain
# regular file which breaks job control.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'echo x >/dev/null && cat </dev/null && echo nullok'
