#!/bin/sh
# FIXTURE: 36_file_operations
# CATEGORY: filesystem
# EXPECT_CONTAINS: fileok
# EXPECT_EXIT: 0
# TAGS: offline
#
# touch, write, cp, mv, cat, rm in sequence. Proves the core POSIX file
# syscalls (open/creat, write, read, link/rename, unlink) under Blink.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'cd /tmp && touch a.txt && echo data > a.txt && cp a.txt b.txt && mv b.txt c.txt && grep -q data c.txt && rm a.txt c.txt && echo fileok'
