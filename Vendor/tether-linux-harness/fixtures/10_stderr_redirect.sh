#!/bin/sh
# FIXTURE: 10_stderr_redirect
# CATEGORY: basics
# EXPECT_CONTAINS: captured:
# EXPECT_EXIT: 0
# TAGS: offline
# A failed ls writes to stderr; redirect it to a file inside the guest and
# read it back. Proves fd 2 works under Blink.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'ls /no/such/path 2>/tmp/e; echo "captured:$(cat /tmp/e)"'
