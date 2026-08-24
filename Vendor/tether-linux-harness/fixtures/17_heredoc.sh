#!/bin/sh
# FIXTURE: 17_heredoc
# CATEGORY: signals
# EXPECT_CONTAINS: line1
# EXPECT_EXIT: 0
# TAGS: offline
#
# A here-document feeds stdin to cat. Proves the shell parser and pipe/temp
# file handling for heredocs.
${BLINK_BIN:-blink} -C "$ROOTFS" /bin/sh -c 'cat <<EOF
line1
line2
EOF'
