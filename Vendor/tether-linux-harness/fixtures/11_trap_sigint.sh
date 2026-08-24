#!/bin/sh
# FIXTURE: 11_trap_sigint
# CATEGORY: signals
# EXPECT_CONTAINS: caught
# EXPECT_EXIT: 0
# TAGS: offline
#
# CRITICAL signal test. The guest shell installs a SIGINT trap that echoes
# "caught", then sleeps. The HOST starts blink in the background, waits long
# enough for the guest to reach sleep(2), sends SIGINT to the blink process,
# and waits for it. Blink must forward the host signal to the guest so the
# trap runs. The guest then finishes sleep(2) normally and exits 0.
#
# How Blink is invoked (host wrapper contract):
#   $BLINK_BIN   path to blink      (default: blink on $PATH)
#   $ROOTFS      path to alpine rootfs (required)
# The fixture itself runs blink in the background and sends it SIGINT from
# the host shell; run-all.sh additionally wraps every fixture in a host
# `timeout --signal=KILL $TIMEOUT_SECS` (default 30s) so that a hung or
# unkillable guest cannot wedge the suite. The 2s guest sleep is far below
# that timeout, so the timeout never fires in normal operation — it exists
# purely as a safety net for signal-delivery regressions.
set -u
BLINK="${BLINK_BIN:-blink}"

"$BLINK" -C "$ROOTFS" /bin/sh -c 'trap "echo caught" INT; sleep 2; echo slept' &
BPID=$!
# Give the guest time to exec sh and reach the sleep() syscall.
sleep 0.5
kill -INT "$BPID" 2>/dev/null
wait "$BPID"
exit $?
