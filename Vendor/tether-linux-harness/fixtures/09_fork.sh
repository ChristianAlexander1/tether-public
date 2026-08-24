#!/bin/sh
# FIXTURE: 09_fork
# CATEGORY: basics
# EXPECT_CONTAINS: child
# EXPECT_EXIT: 0
# TAGS: offline
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'echo child'
