#!/bin/sh
# FIXTURE: 16_double_fork
# CATEGORY: signals
# EXPECT_CONTAINS: nested
# EXPECT_EXIT: 0
# TAGS: offline
#
# Two levels of fork()+exec(): host blink -> sh -> sh -> echo. Proves nested
# process creation and reparenting works under the emulator.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'sh -c "echo nested"'
