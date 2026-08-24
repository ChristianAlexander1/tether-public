#!/bin/sh
# FIXTURE: 04_subshell
# CATEGORY: basics
# EXPECT_CONTAINS: hi
# EXPECT_EXIT: 0
# TAGS: offline
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'x=$(echo hi); echo "$x"'
