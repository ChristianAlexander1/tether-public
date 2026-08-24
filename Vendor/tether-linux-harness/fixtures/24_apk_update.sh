#!/bin/sh
# FIXTURE: 24_apk_update
# CATEGORY: network
# EXPECT_CONTAINS: OK
# EXPECT_EXIT: 0
# TAGS: network
#
# `apk update --no-cache` fetches the package index from the Alpine CDN
# WITHOUT writing to the local cache. We use --no-cache because Blink's VFS
# returns EXDEV ("Cross-device link") when apk atomically renames a downloaded
# index file into the default cache directory across the hostfs/devfs/procfs
# mount boundary; that is a known Blink limitation documented in
# SYSCALL-GAP-LOG.md. With --no-cache the index is fetched and parsed in
# memory, proving HTTPS + DNS + tar streaming work from the guest.
#
# Requires network AND /etc/resolv.conf inside the rootfs (run-all.sh copies
# the host's in when NETWORK=1).
${BLINK_BIN:-blink} -C "$ROOTFS" /sbin/apk update --no-cache --force-refresh
