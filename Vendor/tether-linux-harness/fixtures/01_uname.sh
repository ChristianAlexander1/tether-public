#!/bin/sh
# FIXTURE: 01_uname
# CATEGORY: basics
# EXPECT_CONTAINS: Linux
# EXPECT_EXIT: 0
# TAGS: offline
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/uname -a
