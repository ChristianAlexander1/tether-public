#!/bin/sh
# FIXTURE: 34_gzip_roundtrip
# CATEGORY: compression
# EXPECT_CONTAINS: hello
# EXPECT_EXIT: 0
# TAGS: offline
#
# gzip | gunzip round-trip through a pipe. Proves the gzip applet runs and
# produces/consumes a valid DEFLATE stream inside the guest.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'echo hello | gzip | gunzip'
