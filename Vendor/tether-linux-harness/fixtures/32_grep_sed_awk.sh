#!/bin/sh
# FIXTURE: 32_grep_sed_awk
# CATEGORY: text
# EXPECT_CONTAINS: Banana
# EXPECT_EXIT: 0
# TAGS: offline
#
# Pipeline of text-processing applets: grep -> sed -> awk. Proves several
# busybox applets in one pipeline and correct data flow through multiple
# pipe stages.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'printf "apple\nbanana\ncherry\n" | grep b | sed s/b/B/ | awk "{print \$1}"'
