#!/bin/sh
# FIXTURE: 23_socket_connect
# CATEGORY: stress
# EXPECT_CONTAINS: Example Domain
# EXPECT_EXIT: 0
# TAGS: network
#
# Optional socket test. The minirootfs does NOT include curl, but busybox
# wget is present and supports HTTP. This connects to example.com and prints
# part of the response body, proving socket()+connect()+send()/recv() plus
# DNS resolution work from the guest. Skipped (not failed) in offline runs
# via run-all.sh.
${BLINK_BIN:-blink} -C "$ROOTFS" /usr/bin/wget -q -O - http://example.com 2>&1 | grep -m1 "Example Domain"
