#!/bin/sh
# FIXTURE: 19_ten_stage_pipeline
# CATEGORY: stress
# EXPECT_CONTAINS: 100
# EXPECT_EXIT: 0
# TAGS: offline
#
# A 10-stage pipeline. Each `cat` is a separate fork()+exec() connected by
# pipes; exercises pipe creation, fd inheritance, and process reaping at
# scale under Blink.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'seq 1 100 | cat | cat | cat | cat | cat | cat | cat | cat | wc -l'
