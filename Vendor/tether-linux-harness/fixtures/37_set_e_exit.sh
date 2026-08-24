#!/bin/sh
# FIXTURE: 37_set_e_exit
# CATEGORY: shell
# EXPECT_CONTAINS: code:1
# EXPECT_EXIT: 0
# TAGS: offline
#
# `set -e` must abort the script on the first failing command. `false` causes
# exit 1; the trailing echo never runs. The wrapper normalizes the guest exit
# code into output so the runner can assert without itself failing.
set -u
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'set -e; false; echo should-not-print' >/dev/null 2>&1
rc=$?
echo "code:${rc}"
[ "$rc" -eq 1 ]
