#!/usr/bin/env bash
# Tether — Track P8 benchmark driver
# Measures wall time of the SAME Alpine busybox workloads:
#   A) riscv64 Alpine 3.24.1 emulated by libriscv (threaded / switch / bintr)
#   B) x86_64  Alpine 3.24.1 run natively on this Linux host (musl loader)
# Every run is timed with host wall clock; tetherspike additionally reports
# guest instruction counts and effective guest-MIPS.
set -u
cd "$(dirname "$0")"
OUT=${1:-results/bench-$(date +%F).txt}
mkdir -p results

LDSO64=assets/rootfs-x86_64/lib/ld-musl-x86_64.so.1
NATIVE_SH="$LDSO64 assets/rootfs-x86_64/bin/sh"
NATIVE_BB="$LDSO64 assets/rootfs-x86_64/bin/busybox"
RF=assets/rootfs-riscv64

# shell/awk loop sizes
LOOP_N=${LOOP_N:-2000000}
AWK_N=${AWK_N:-1000000}

ts() { date +%s; }
log() { echo "$*" | tee -a "$OUT"; }

run_guest() { # name engine-binary guest-arg...
  local name="$1"; shift
  local bin="$1"; shift
  local t0 t1 wall
  t0=$(ts)
  "$bin" --quiet --fuel 300000000000 --rootfs "$RF" "$@" 2>>"$OUT.stderr" | tee -a "$OUT"
  t1=$(ts)
  wall=$((t1 - t0))
  grep "TETHERSPIKE_RESULT" "$OUT.stderr" | tail -1 >> "$OUT"
  log "=> $name : ${wall}s wall"
  : > "$OUT.stderr"
}
run_native() { # name cmd...
  local name="$1"; shift
  local t0 t1 wall
  t0=$(ts)
  "$@" | tee -a "$OUT"
  t1=$(ts)
  wall=$((t1 - t0))
  log "=> $name : ${wall}s wall"
}

log "# Tether P8 bench $(date -u +'%F %T UTC')"
log "# host: $(uname -srm), $(nproc) CPUs"
log "# guest payloads: LOOP_N=$LOOP_N AWK_N=$AWK_N sha256(32MiB)"
log ""

log "== 0. startup /bin/uname -a"
run_guest "guest/threaded uname" ./build/tetherspike /bin/uname -a
run_guest "guest/switch   uname" ./build/tetherspike-switch /bin/uname -a
run_guest "guest/bintr    uname" ./build/tetherspike-bintr /bin/uname -a
run_native "native x86_64  uname" $NATIVE_BB uname -a

log ""
log "== 1. busybox sh arithmetic loop (N=$LOOP_N)"
run_guest "guest/threaded shloop" ./build/tetherspike /bin/sh /bench/loop.sh "$LOOP_N"
run_guest "guest/switch   shloop" ./build/tetherspike-switch /bin/sh /bench/loop.sh "$LOOP_N"
run_guest "guest/bintr    shloop" ./build/tetherspike-bintr /bin/sh /bench/loop.sh "$LOOP_N"
run_native "native x86_64  shloop" $NATIVE_SH assets/rootfs-x86_64/bench/loop.sh "$LOOP_N"

log ""
log "== 2. busybox awk numeric loop (N=$AWK_N)"
run_guest "guest/threaded awkloop" ./build/tetherspike /bin/busybox awk "BEGIN{s=0; for(i=0;i<$AWK_N;i++){s+=i*i}; print s}"
run_guest "guest/switch   awkloop" ./build/tetherspike-switch /bin/busybox awk "BEGIN{s=0; for(i=0;i<$AWK_N;i++){s+=i*i}; print s}"
run_guest "guest/bintr    awkloop" ./build/tetherspike-bintr /bin/busybox awk "BEGIN{s=0; for(i=0;i<$AWK_N;i++){s+=i*i}; print s}"
run_native "native x86_64  awkloop" $NATIVE_BB awk "BEGIN{s=0; for(i=0;i<$AWK_N;i++){s+=i*i}; print s}"

log ""
log "== 3. busybox sha256sum of 32 MiB payload"
run_guest "guest/threaded sha256" ./build/tetherspike /bin/busybox sha256sum /bench/payload.bin
run_guest "guest/switch   sha256" ./build/tetherspike-switch /bin/busybox sha256sum /bench/payload.bin
run_guest "guest/bintr    sha256" ./build/tetherspike-bintr /bin/busybox sha256sum /bench/payload.bin
run_native "native x86_64  sha256" $NATIVE_BB sha256sum assets/rootfs-x86_64/bench/payload.bin

log ""
log "# done $(date -u +'%T')"
