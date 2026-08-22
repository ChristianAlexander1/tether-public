#!/usr/bin/env bash
# Builds Blink static libraries and Blink.xcframework for TermX (ISC license).
# Upstream: https://github.com/jart/blink @ f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
SRC="$BUILD/blink-src"
OUT_XCF="$ROOT/Blink.xcframework"
HEADERS_OUT="$ROOT/include/blink"
COMMIT="${BLINK_COMMIT:-f006a4fc6f9b8de9272504fdff0dbbe5ce5dc580}"
GMAKE="${GMAKE:-$(command -v gmake || echo /opt/homebrew/bin/gmake)}"
MIN_IOS="${TERMX_IOS_DEPLOYMENT:-16.0}"

echo "==> Blink ${COMMIT} for TermX (ISC)"

if [[ ! -x "$GMAKE" ]]; then
  echo "error: GNU make 4+ required (brew install make)" >&2
  exit 1
fi

mkdir -p "$BUILD"

if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 https://github.com/jart/blink.git "$SRC"
  git -C "$SRC" fetch --depth 1 origin "$COMMIT"
  git -C "$SRC" checkout "$COMMIT"
fi

build_host() {
  echo "==> Host macOS blink (interpreter mode, VFS enabled)"
  cd "$SRC"
  ./configure --disable-jit --enable-vfs MODE=rel
  "$GMAKE" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" o/rel/blink/blink o/rel/blink/blink.a
  install -d "$BUILD/host"
  cp o/rel/blink/blink.a "$BUILD/host/"
  cp o/rel/blink/blink "$BUILD/host/blink"
  cp config.h "$BUILD/host/"
}

install_headers() {
  install -d "$HEADERS_OUT"
  # Headers only — do not rsync .c sources into include/
  find "$SRC/blink" -maxdepth 1 -name '*.h' -exec cp {} "$HEADERS_OUT/" \;
  cp "$SRC/config.h" "$HEADERS_OUT/../config.h"
  install -d "$ROOT/include"
  cp "$SRC/config.h" "$ROOT/include/config.h"
  install -d "$ROOT/NOTICES"
  cat > "$ROOT/NOTICES/Blink-ISC.txt" <<'EOF'
ISC License

Copyright 2022 Justine Alexandra Roberts Tunney

Permission to use, copy, modify, and/or distribute this software for
any purpose with or without fee is hereby granted, provided that the
above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
EOF
}

# iOS SDK marks clock_settime unavailable; Blink still references it in SysClockSettime.
apply_ios_patches() {
  local f="$SRC/blink/syscall.c"
  if grep -q 'return clock_settime(sysclock, &ht);' "$f"; then
    echo "==> Patching blink/syscall.c for iOS (clock_settime)"
    /usr/bin/sed -i '' 's/return clock_settime(sysclock, \&ht);/errno = EPERM; return -1; \/* TermX iOS: clock_settime unavailable *\//' "$f"
  fi
}

build_ios_slice() {
  local sdk="$1" # iphoneos | iphonesimulator
  local arch="$2"
  local label="$3"
  local outdir="$BUILD/ios-$label"
  local sdkpath sysroot cc

  sdkpath="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  sysroot="$sdkpath"

  echo "==> iOS slice $label ($sdk $arch)" >&2
  rm -rf "$outdir"
  mkdir -p "$outdir/blink"

  local cflags="-target ${arch}-apple-ios${MIN_IOS}"
  if [[ "$sdk" == "iphonesimulator" ]]; then
    cflags="-target ${arch}-apple-ios${MIN_IOS}-simulator"
  fi
  cflags+=" -isysroot $sysroot -O2 -DNDEBUG -D_DARWIN_C_SOURCE"
  # iOS lacks fdatasync; map to fsync. clock_settime patched in apply_ios_patches.
  cflags+=" -Dfdatasync=fsync"
  # ios-shims/config.h overlays host flags (drops HAVE_SYS_GETENTROPY).
  cflags+=" -I$ROOT/ios-shims -I$SRC -I$BUILD/host -include config.h -iquote$SRC"

  local objfiles=()
  local base
  for base in $(cd "$SRC" && ls blink/*.c | sed 's/.c$//'); do
    local obj="$outdir/${base}.o"
    mkdir -p "$(dirname "$obj")"
    # shellcheck disable=SC2086
    if ! "$cc" $cflags -c "$SRC/${base}.c" -o "$obj"; then
      echo "error: failed compiling $base for $label" >&2
      return 1
    fi
    objfiles+=("$obj")
  done

  lib="$outdir/libblink.a"
  ar rcs "$lib" "${objfiles[@]}"
  echo "$lib"
}

create_xcframework() {
  echo "==> Creating Blink.xcframework (static library)"
  rm -rf "$OUT_XCF" "$BUILD/frameworks" "$BUILD/xc-headers"
  mkdir -p "$BUILD/xc-headers"

  # Headers expected by termx_blink_bridge.c: blink/*.h + config.h
  rsync -a "$SRC/blink/" "$BUILD/xc-headers/blink/"
  cp "$BUILD/host/config.h" "$BUILD/xc-headers/config.h"
  cp "$SRC/config.h" "$BUILD/xc-headers/config.h" 2>/dev/null || true

  local dev_lib sim_lib
  dev_lib="$(build_ios_slice iphoneos arm64 device)" || return 1
  sim_lib="$(build_ios_slice iphonesimulator arm64 simulator)" || return 1

  xcodebuild -create-xcframework \
    -library "$dev_lib" -headers "$BUILD/xc-headers" \
    -library "$sim_lib" -headers "$BUILD/xc-headers" \
    -output "$OUT_XCF"
}

build_host
install_headers
apply_ios_patches

if xcodebuild -version >/dev/null 2>&1; then
  if create_xcframework; then
    echo "==> Blink.xcframework ready at $OUT_XCF"
  else
    echo "warning: iOS xcframework build failed; host blink.a is available for macOS tests" >&2
  fi
else
  echo "warning: Xcode not available; skipping xcframework (host blink.a only)" >&2
fi

echo "==> Host static library: $BUILD/host/blink.a"
echo "==> Headers: $HEADERS_OUT"
echo "==> Upstream commit: $COMMIT"
