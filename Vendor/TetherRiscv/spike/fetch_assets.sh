#!/usr/bin/env bash
# Tether P8 — download test assets (not shipped inside the zip)
#  - Alpine 3.24.1 minirootfs for riscv64 (guest) and x86_64 (native comparator)
#  - rewrites absolute applet symlinks to relative (keeps host path-prefixing safe)
#  - installs bench payloads (/bench/loop.sh, /bench/payload.bin) into both rootfs
set -euo pipefail
mkdir -p "$(dirname "$0")/assets"
cd "$(dirname "$0")/assets"

VER=3.24.1
BASE=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases

for A in riscv64 x86_64; do
  T=alpine-minirootfs-$VER-$A.tar.gz
  [ -f "$T" ] || curl -fLO --max-time 120 "$BASE/$A/$T"
  mkdir -p "rootfs-$A"
  tar xzf "$T" -C "rootfs-$A"
  # absolute symlinks would escape our rootfs prefix when the host follows them:
  find "rootfs-$A" -type l -lname '/*' | while read -r f; do
    t=$(readlink "$f"); d=$(dirname "$f")
    rel=$(realpath --relative-to="$d" "rootfs-$A$t" 2>/dev/null) && ln -sf "$rel" "$f" || true
  done
  mkdir -p "rootfs-$A/bench"
done

cat > loop.sh <<'EOF'
#!/bin/sh
# Tether P8 bench: pure CPU workload (busybox sh arithmetic loop)
i=0
limit=${1:-1000000}
while [ "$i" -lt "$limit" ]; do
  i=$((i + 1))
done
echo "loop completed: $i iterations"
EOF

[ -f payload.bin ] || head -c 33554432 /dev/urandom > payload.bin
for A in riscv64 x86_64; do
  cp loop.sh "rootfs-$A/bench/loop.sh"
  cp payload.bin "rootfs-$A/bench/payload.bin"
done
echo "assets ready."
