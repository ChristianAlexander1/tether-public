#!/bin/sh
# FIXTURE: 43_pipeline_clean_exit
# CATEGORY: basics
# EXPECT_CONTAINS: hello
# EXPECT_CONTAINS: status:0
# EXPECT_EXIT: 0
# TAGS: offline
#
# Two-stage pipeline must exit 0. The embedded Blink bridge used to
# longjmp from the forked child's exit() into the parent's jmp_buf,
# which printed "Segmentation fault" after correct output. Host blink
# already passed; this fixture keeps the contract visible in the harness.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'echo hello | cat; echo status:$?'
