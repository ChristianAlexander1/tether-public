#!/bin/sh
# FIXTURE: 03_pipeline_wc
# CATEGORY: basics
# EXPECT_CONTAINS: 82
# EXPECT_EXIT: 0
# TAGS: offline
# BusyBox 3.24 minirootfs ships 82 entries in /bin. The exact count is stable
# for a given minirootfs version; 3.24.1 = 82.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'ls /bin | wc -l'
