#!/bin/sh
# FIXTURE: 06_alpine_release
# CATEGORY: basics
# EXPECT_CONTAINS: 3.
# EXPECT_EXIT: 0
# TAGS: offline
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/cat /etc/alpine-release
