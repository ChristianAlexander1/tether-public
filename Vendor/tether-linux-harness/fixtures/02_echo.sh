#!/bin/sh
# FIXTURE: 02_echo
# CATEGORY: basics
# EXPECT_CONTAINS: hello
# EXPECT_EXIT: 0
# TAGS: offline
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/busybox echo hello
