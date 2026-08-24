#!/bin/sh
# FIXTURE: 13_bg_job_wait
# CATEGORY: signals
# EXPECT_CONTAINS: waited
# EXPECT_EXIT: 0
# TAGS: offline
#
# Background job control: `sleep 1 & wait`. This exercises fork()+wait4()
# inside the guest and requires a working /dev/null (busybox ash redirects
# job-control fds there). It fails if Blink is built WITHOUT --enable-vfs.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'sleep 1 & wait; echo waited'
