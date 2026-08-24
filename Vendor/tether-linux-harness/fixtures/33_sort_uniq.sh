#!/bin/sh
# FIXTURE: 33_sort_uniq
# CATEGORY: text
# EXPECT_CONTAINS: sorted:3
# EXPECT_EXIT: 0
# TAGS: offline
#
# sort | uniq -c: feed duplicate lines, count uniques. Proves sort(1) and
# uniq(1) and that the pipeline collapses 5 lines to 3 distinct values.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'printf "b\na\nc\na\nb\n" | sort | uniq | wc -l | sed "s/^/sorted:/"'
