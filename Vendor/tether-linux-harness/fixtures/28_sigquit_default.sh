#!/bin/sh
# FIXTURE: 28_sigquit_default
# CATEGORY: signals
# EXPECT_CONTAINS: quitcode:131
# EXPECT_EXIT: 0
# TAGS: offline
#
# SIGQUIT with the DEFAULT action terminates the process and yields wait
# status 128 + SIGQUIT(3) = 131. We invoke /bin/sleep DIRECTLY (not via
# `sh -c`) because a non-interactive POSIX shell is permitted -- and busybox
# ash does -- to set SIGQUIT to SIG_IGN for itself and its children; that is
# correct shell behavior, not an emulator bug. Running the sleep binary
# directly isolates Blink's default-signal-termination path.
set -u
BLINK="${BLINK_BIN:-blink}"
"$BLINK" -C "$ROOTFS" /bin/sleep 5 &
BPID=$!
sleep 0.5
kill -QUIT "$BPID" 2>/dev/null
wait "$BPID"
rc=$?
echo "quitcode:${rc}"
[ "$rc" -eq 131 ]
