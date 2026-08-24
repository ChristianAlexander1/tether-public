#!/usr/bin/env bash
#
# build.sh — compile the sample wasm32-wasi commands
# SPDX-License-Identifier: MIT
#
# The resulting .wasm files are committed alongside the sources, so this only
# needs running when a sample changes. Requires wasi-sdk:
#
#   WASI_SDK_PATH=/opt/wasi-sdk ./build.sh
#
# Download it from https://github.com/WebAssembly/wasi-sdk/releases
#
set -euo pipefail

cd "$(dirname "$0")"

# Locate wasi-sdk: explicit path first, then a clang that can target wasi.
if [[ -n "${WASI_SDK_PATH:-}" ]]; then
    CC="$WASI_SDK_PATH/bin/clang"
    SYSROOT_FLAG="--sysroot=$WASI_SDK_PATH/share/wasi-sysroot"
elif command -v /opt/wasi-sdk/bin/clang >/dev/null 2>&1; then
    CC=/opt/wasi-sdk/bin/clang
    SYSROOT_FLAG="--sysroot=/opt/wasi-sdk/share/wasi-sysroot"
elif command -v clang >/dev/null 2>&1 && clang -print-targets 2>/dev/null | grep -q wasm32; then
    CC=clang
    SYSROOT_FLAG="${WASI_SYSROOT:+--sysroot=$WASI_SYSROOT}"
else
    echo "error: no wasi-sdk found. Set WASI_SDK_PATH=/path/to/wasi-sdk" >&2
    exit 1
fi

# -O2 keeps the modules small; the runner is an interpreter, so size matters
# more than the last few percent of guest speed.
#
# wasm3 implements the MVP plus a few post-MVP proposals, but not SIMD, bulk
# memory or reference types. Recent wasi-sdk releases enable those by default,
# so they are switched off explicitly to keep the output loadable.
CFLAGS=(
    -O2
    -Wall
    --target=wasm32-wasi
    -mno-simd128
    -mno-bulk-memory
    -mno-reference-types
    -mno-sign-ext
    -mno-nontrapping-fptoint
    -mno-multivalue
    -Wl,--strip-all
)

[[ -n "${SYSROOT_FLAG:-}" ]] && CFLAGS+=("$SYSROOT_FLAG")

build() {
    local src="$1" out="$2"
    echo "  CC  $out"
    "$CC" "${CFLAGS[@]}" -o "$out" "$src"
}

echo "building samples with $CC"
build hello.c    hello.wasm
build echo.c     echo.wasm
build exitcode.c exitcode.wasm
build envcat.c   envcat.wasm
build spin.c     spin.wasm

echo "done:"
ls -l ./*.wasm
