#!/bin/sh
# FIXTURE: 08_export_printenv
# CATEGORY: basics
# EXPECT_CONTAINS: TETHER_VAR=42
# EXPECT_EXIT: 0
# TAGS: offline
# Export a variable inside the guest and list the environment with `printenv`
# (per spec: "export VAR=1; printenv"). With no args, printenv prints every
# exported variable as NAME=VALUE lines. Proves putenv/export and that the
# guest environment is populated and queryable.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'export TETHER_VAR=42; printenv | grep "^TETHER_VAR="'
