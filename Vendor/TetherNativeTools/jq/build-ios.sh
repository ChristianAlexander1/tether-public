#!/usr/bin/env bash
set -euo pipefail

# Build jq for iOS as static archives with a C-callable Tether entry point.
# Requires macOS/Xcode SDKs, git, autotools, make, clang, llvm-objcopy,
# Apple libtool, and lipo. The jq CLI object _main is renamed to
# _tether_jq_main and archived with libjq/static dependencies.

DEFAULT_REPO="https://github.com/jqlang/jq.git"
DEFAULT_REF="jq-1.7.1"
ENTRY="tether_jq_main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${TETHER_JQ_SRC:-${SCRIPT_DIR}/src/jq}"
BUILD_DIR="${SCRIPT_DIR}/build/ios"
REPO="${TETHER_JQ_REPO:-${DEFAULT_REPO}}"
REF="${TETHER_JQ_REF:-${DEFAULT_REF}}"
TARGETS="${TETHER_JQ_IOS_TARGETS:-arm64-iphoneos arm64-iphonesimulator x86_64-iphonesimulator}"
MIN_IOS="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need git; need xcrun; need make; need lipo
OBJCOPY="${LLVM_OBJCOPY:-$(command -v llvm-objcopy || true)}"
[ -n "${OBJCOPY}" ] || { echo "missing llvm-objcopy (install LLVM or set LLVM_OBJCOPY=/path/to/llvm-objcopy)" >&2; exit 1; }
LIBTOOL="$(xcrun --find libtool)"

mkdir -p "${SRC_DIR%/*}" "${BUILD_DIR}"
if [ ! -d "${SRC_DIR}/.git" ]; then
  git clone --depth 1 --branch "${REF}" "${REPO}" "${SRC_DIR}"
else
  git -C "${SRC_DIR}" fetch --tags --depth 1 origin "${REF}" || true
  git -C "${SRC_DIR}" checkout "${REF}"
fi

# jq's git checkout may need generated autotools files and submodules for bundled deps.
if [ -f "${SRC_DIR}/.gitmodules" ]; then
  git -C "${SRC_DIR}" submodule update --init --recursive
fi
if [ ! -x "${SRC_DIR}/configure" ]; then
  (cd "${SRC_DIR}" && autoreconf -fi)
fi

built_archives=()
for target in ${TARGETS}; do
  case "${target}" in
    arm64-iphoneos) sdk="iphoneos"; host="arm-apple-darwin"; arch="arm64"; deploy_flag="-miphoneos-version-min=${MIN_IOS}" ;;
    arm64-iphonesimulator) sdk="iphonesimulator"; host="arm-apple-darwin"; arch="arm64"; deploy_flag="-mios-simulator-version-min=${MIN_IOS}" ;;
    x86_64-iphonesimulator) sdk="iphonesimulator"; host="x86_64-apple-darwin"; arch="x86_64"; deploy_flag="-mios-simulator-version-min=${MIN_IOS}" ;;
    *) echo "unsupported target: ${target}" >&2; exit 2 ;;
  esac

  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  cc_bin="$(xcrun --sdk "${sdk}" --find clang)"
  slice_dir="${BUILD_DIR}/${target}"
  install_dir="${slice_dir}/prefix"
  mkdir -p "${slice_dir}"

  echo "==> Building jq for ${target}"
  (
    cd "${SRC_DIR}"
    make distclean >/dev/null 2>&1 || true
    CC="${cc_bin}" \
    CFLAGS="-arch ${arch} -isysroot ${sdk_path} ${deploy_flag} -Os" \
    LDFLAGS="-arch ${arch} -isysroot ${sdk_path} ${deploy_flag}" \
    ./configure --host="${host}" --prefix="${install_dir}" --disable-shared --enable-static --with-oniguruma=builtin
    make -j"$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
    make install
  )

  main_obj="$(find "${SRC_DIR}" -path '*/src/main.o' -print | head -n 1)"
  [ -n "${main_obj}" ] || { echo "could not find jq src/main.o" >&2; exit 1; }
  renamed_obj="${slice_dir}/jq_${ENTRY}.o"
  cp "${main_obj}" "${renamed_obj}"
  "${OBJCOPY}" --redefine-sym "_main=_${ENTRY}" "${renamed_obj}"

  libs=()
  while IFS= read -r lib; do libs+=("${lib}"); done < <(find "${install_dir}/lib" -name '*.a' -print)
  [ "${#libs[@]}" -gt 0 ] || { echo "no jq static libraries found in ${install_dir}/lib" >&2; exit 1; }
  "${LIBTOOL}" -static -o "${slice_dir}/libtether_jq.a" "${renamed_obj}" "${libs[@]}"
  built_archives+=("${slice_dir}/libtether_jq.a")
done

mkdir -p "${BUILD_DIR}/universal"
if [ "${#built_archives[@]}" -gt 1 ]; then
  lipo -create "${built_archives[@]}" -output "${BUILD_DIR}/universal/libtether_jq.a"
else
  cp "${built_archives[0]}" "${BUILD_DIR}/universal/libtether_jq.a"
fi

echo "Done: ${BUILD_DIR}/universal/libtether_jq.a"
