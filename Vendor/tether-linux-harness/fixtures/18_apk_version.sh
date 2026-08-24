#!/bin/sh
# FIXTURE: 18_apk_version
# CATEGORY: signals
# EXPECT_CONTAINS: apk-tools
# EXPECT_EXIT: 0
# TAGS: offline
#
# `apk --version` makes NO network call. It proves the package manager binary
# runs under Blink (statically linked against musl) before any online test.
${BLINK_BIN:-blink} -C "$ROOTFS" /sbin/apk --version
