#!/bin/sh
# FIXTURE: 29_sigkill_unblockable
# CATEGORY: signals
# EXPECT_CONTAINS: killedcode:
# EXPECT_EXIT: 0
# TAGS: offline
#
# SIGKILL cannot be caught, blocked, or ignored. The guest sleep must die
# immediately and the wait status must be 128 + 9 = 137. This is the hardest
# signal-delivery guarantee for an emulator: the host must terminate the
# emulated process and report the correct status.
set -u
BLINK="${BLINK_BIN:-blink}"
"$BLINK" -C "$ROOTFS" /bin/sh -c 'trap "echo should-not-run" KILL; sleep 5' &
BPID=$!
sleep 0.5
kill -KILL "$BPID" 2>/dev/null
wait "$BPID"
rc=$?
echo "killedcode:${rc}"
[ "$rc" -eq 137 ]
