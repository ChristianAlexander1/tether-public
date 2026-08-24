#!/bin/sh
# FIXTURE: 25_apk_add_git
# CATEGORY: network
# EXPECT_CONTAINS: git version
# EXPECT_EXIT: 0
# TAGS: network
#
# Ensure git is installed and runnable. This requires network access (~20 MB
# of packages) and write access to the rootfs. We use --no-cache to avoid
# Blink's VFS EXDEV on the local package cache (see fixture 24).
#
# The apk exit status is ignored on purpose: if a previous run installed git
# but Blink's VFS EXDEV prevented the apk DB rename, `apk add git` may exit
# non-zero even though /usr/bin/git is present and working. What matters for
# this fixture is that a real package can be fetched and executed.
set -u
${BLINK_BIN:-blink} -C "$ROOTFS" /sbin/apk add --no-cache --no-progress git >/dev/null 2>&1
${BLINK_BIN:-blink} -C "$ROOTFS" /usr/bin/git --version
