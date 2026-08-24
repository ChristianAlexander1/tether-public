#!/bin/sh
# FIXTURE: 38_command_not_found
# CATEGORY: shell
# EXPECT_CONTAINS: nf:127
# EXPECT_EXIT: 0
# TAGS: offline
#
# A nonexistent command must yield exit status 127 (POSIX "command not
# found"). This exercises Blink's execve() ENOENT path and the shell's
# reporting of it.
set -u
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'definitely_not_a_command_xyz' >/dev/null 2>&1
rc=$?
echo "nf:${rc}"
[ "$rc" -eq 127 ]
