#!/bin/sh
# FIXTURE: 05_repositories
# CATEGORY: basics
# EXPECT_CONTAINS: alpine
# EXPECT_EXIT: 0
# TAGS: offline
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/cat /etc/apk/repositories
