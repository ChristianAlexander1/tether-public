#!/bin/sh
# FIXTURE: 42_multiple_signals
# CATEGORY: signals
# EXPECT_CONTAINS: both:2
# EXPECT_EXIT: 0
# TAGS: offline
#
# Deliver TWO different catchable signals (USR1 then USR2) to the same guest
# process. Each trap increments a counter; after both arrive the guest prints
# "both:2" and exits. Proves repeated, distinct signal delivery to one process.
#
# NOTE: trap actions MUST be single-quoted so the shell defers $n expansion to
# trap-run time; double-quoting would expand $n once at trap-install time.
set -u
BLINK="${BLINK_BIN:-blink}"
"$BLINK" -C "$ROOTFS" /bin/sh -c '
  n=0
  trap '\''n=$((n+1)); echo usr1:$n'\'' USR1
  trap '\''n=$((n+1)); echo usr2:$n; [ $n -ge 2 ] && echo both:$n'\'' USR2
  i=0
  while [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  echo final:$n
' &
BPID=$!
sleep 0.6
kill -USR1 "$BPID" 2>/dev/null
sleep 0.3
kill -USR2 "$BPID" 2>/dev/null
wait "$BPID"
exit $?
