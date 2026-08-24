#!/bin/sh
# FIXTURE: 12_pipeline_interrupted
# CATEGORY: signals
# EXPECT_CONTAINS: interrupted
# EXPECT_EXIT: 130
# TAGS: offline
#
# CRITICAL signal test. A pipeline (`sleep 5 | cat`) is started inside the
# guest. The host sends SIGINT to blink. Expected, documented behavior:
#   - the pipeline is terminated by SIGINT
#   - the controlling guest shell exits with 128 + SIGINT(2) = 130
#   - the echo AFTER the pipeline never runs
# The wrapper reports blink's own exit status (130) so the runner can assert
# it. If Blink ever changes how it propagates SIGINT to a foreground pipeline,
# this fixture will fail and the new behavior must be documented here.
set -u
BLINK="${BLINK_BIN:-blink}"

"$BLINK" -C "$ROOTFS" /bin/sh -c 'sleep 5 | cat; echo pipeline-done' &
BPID=$!
sleep 0.5
kill -INT "$BPID" 2>/dev/null
wait "$BPID"
rc=$?
echo "interrupted:${rc}"
exit "$rc"
