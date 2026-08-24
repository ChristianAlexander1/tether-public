#!/bin/sh
# FIXTURE: 27_trap_sighup
# CATEGORY: signals
# EXPECT_CONTAINS: hupcaught
# EXPECT_EXIT: 0
# TAGS: offline
#
# SIGHUP trap: proves hangup signals (relevant to terminal disconnects in the
# eventual phone integration) are delivered to the guest foreground process.
set -u
BLINK="${BLINK_BIN:-blink}"
"$BLINK" -C "$ROOTFS" /bin/sh -c 'trap "echo hupcaught" HUP; sleep 2; echo slept' &
BPID=$!
sleep 0.5
kill -HUP "$BPID" 2>/dev/null
wait "$BPID"
exit $?
