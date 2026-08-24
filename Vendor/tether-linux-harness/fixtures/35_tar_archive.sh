#!/bin/sh
# FIXTURE: 35_tar_archive
# CATEGORY: compression
# EXPECT_CONTAINS: ok
# EXPECT_EXIT: 0
# TAGS: offline
#
# Create a tarball in /tmp, extract it elsewhere, and verify the contents.
# Exercises tar(1), file creation, and directory traversal.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'mkdir -p /tmp/src /tmp/dst && echo secret > /tmp/src/f.txt && tar -C /tmp/src -cf /tmp/a.tar . && tar -C /tmp/dst -xf /tmp/a.tar && grep -q secret /tmp/dst/f.txt && echo ok && rm -rf /tmp/src /tmp/dst /tmp/a.tar'
