#!/bin/sh
# FIXTURE: 41_redirect_append
# CATEGORY: shell
# EXPECT_CONTAINS: onetwo
# EXPECT_EXIT: 0
# TAGS: offline
#
# Append redirect (>>) must not truncate; both lines survive. Then input
# redirect (<) reads the file back. Proves O_APPEND and O_RDONLY open flags.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'cd /tmp && echo one >f.txt && echo two >>f.txt && tr -d "\n" < f.txt; rm -f f.txt'
