#!/bin/sh
# FIXTURE: 26_trap_sigterm
# CATEGORY: signals
# EXPECT_CONTAINS: termcaught
# EXPECT_EXIT: 0
# TAGS: offline
#
# SIGTERM trap: host sends SIGTERM to blink, guest trap must fire and the
# process completes its sleep and exits 0 (SIGTERM is catchable, unlike the
# default action which would terminate).
set -u
BLINK="${BLINK_BIN:-blink}"
"$BLINK" -C "$ROOTFS" /bin/sh -c 'trap "echo termcaught" TERM; sleep 2; echo slept' &
BPID=$!
sleep 0.5
kill -TERM "$BPID" 2>/dev/null
wait "$BPID"
exit $?
