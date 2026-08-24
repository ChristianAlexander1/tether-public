#!/bin/sh
# FIXTURE: 31_mkfifo_named_pipe
# CATEGORY: ipc
# EXPECT_CONTAINS: got:hi
# EXPECT_EXIT: 0
# TAGS: offline
#
# Create a FIFO with mkfifo(2), write from a background subshell, read in the
# foreground. Proves named-pipe (S_IFIFO) creation and blocking open semantics
# under Blink's VFS.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'mkfifo /tmp/tfifo; (echo hi >/tmp/tfifo) & read x </tmp/tfifo; echo "got:$x"; rm -f /tmp/tfifo'
