#!/bin/sh
# FIXTURE: 40_env_inheritance
# CATEGORY: process
# EXPECT_CONTAINS: inherited:yes
# EXPECT_EXIT: 0
# TAGS: offline
#
# An environment variable set on the host-side blink invocation must be
# inherited by the guest process. Proves Blink forwards the execve envp.
# We set TETHER_INHERIT=yes in the environment of the blink process itself.
TETHER_INHERIT=yes ${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'echo "inherited:${TETHER_INHERIT:-no}"'
