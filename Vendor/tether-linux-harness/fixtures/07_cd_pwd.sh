#!/bin/sh
# FIXTURE: 07_cd_pwd
# CATEGORY: basics
# EXPECT_CONTAINS: /tmp
# EXPECT_EXIT: 0
# TAGS: offline
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'cd /tmp && pwd'
