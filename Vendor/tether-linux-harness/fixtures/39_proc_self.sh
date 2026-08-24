#!/bin/sh
# FIXTURE: 39_proc_self
# CATEGORY: process
# EXPECT_CONTAINS: busybox
# EXPECT_EXIT: 0
# TAGS: offline
#
# /proc/self/exe must resolve to the running executable (busybox, since ash
# is a symlink to it). Proves Blink's procfs provides a functional
# /proc/self/exe symlink.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'readlink /proc/self/exe'
