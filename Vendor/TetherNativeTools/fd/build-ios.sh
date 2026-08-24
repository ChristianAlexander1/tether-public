#!/usr/bin/env bash
set -euo pipefail

# Build fd for iOS as static archives with a C-callable Tether entry point.
# Requires macOS/Xcode SDKs, rustup/cargo, git, llvm-objcopy, and Apple libtool.
# The upstream Rust binary is compiled to Mach-O objects; _main is renamed to
# _tether_fd_main so the host app can call:
#   int tether_fd_main(int argc, char **argv);

TOOL_NAME="fd"
BIN_NAME="fd"
ENTRY="tether_fd_main"
DEFAULT_REPO="https://github.com/sharkdp/fd.git"
DEFAULT_REF="v10.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${TETHER_FD_SRC:-${SCRIPT_DIR}/src/fd}"
BUILD_DIR="${SCRIPT_DIR}/build/ios"
REPO="${TETHER_FD_REPO:-${DEFAULT_REPO}}"
REF="${TETHER_FD_REF:-${DEFAULT_REF}}"
TARGETS="${TETHER_RUST_IOS_TARGETS:-${TETHER_IOS_TARGETS:-aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios}}"
MIN_IOS="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need git; need cargo; need rustup; need xcrun; need lipo
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

export IPHONEOS_DEPLOYMENT_TARGET="${MIN_IOS}"
built_archives=()

for target in ${TARGETS}; do
  case "${target}" in
    aarch64-apple-ios) sdk="iphoneos"; arch="arm64"; deploy_flag="-miphoneos-version-min=${MIN_IOS}" ;;
    aarch64-apple-ios-sim) sdk="iphonesimulator"; arch="arm64"; deploy_flag="-mios-simulator-version-min=${MIN_IOS}" ;;
    x86_64-apple-ios) sdk="iphonesimulator"; arch="x86_64"; deploy_flag="-mios-simulator-version-min=${MIN_IOS}" ;;
    *) echo "unsupported target: ${target}" >&2; exit 2 ;;
  esac

  echo "==> Building ${TOOL_NAME} object for ${target}"
  rustup target add "${target}"
  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  clang="$(xcrun --sdk "${sdk}" --find clang)"
  export SDKROOT="${sdk_path}"
  export CFLAGS="-arch ${arch} -isysroot ${sdk_path} ${deploy_flag}"
  linker_var="CARGO_TARGET_$(echo "${target}" | tr '[:lower:]-' '[:upper:]_')_LINKER"
  export "${linker_var}=${clang}"

  mkdir -p "${BUILD_DIR}"
  cargo rustc --manifest-path "${SRC_DIR}/Cargo.toml" --release --target "${target}" --bin "${BIN_NAME}" -- --emit=obj

  slice_dir="${BUILD_DIR}/${target}"
  mkdir -p "${slice_dir}"
  obj="$(find "${SRC_DIR}/target/${target}/release/deps" -name "${BIN_NAME}-*.o" -print | sort | tail -n 1)"
  [ -n "${obj}" ] || { echo "could not find emitted ${BIN_NAME} object" >&2; exit 1; }
  renamed_obj="${slice_dir}/${BIN_NAME}_${ENTRY}.o"
  cp "${obj}" "${renamed_obj}"
  "${OBJCOPY}" --redefine-sym "_main=_${ENTRY}" "${renamed_obj}"

  rlibs=()
  while IFS= read -r rlib; do rlibs+=("${rlib}"); done < <(find "${SRC_DIR}/target/${target}/release/deps" "$(rustc --print sysroot)/lib/rustlib/${target}/lib" -name '*.rlib' -print)
  "${LIBTOOL}" -static -o "${slice_dir}/libtether_fd.a" "${renamed_obj}" "${rlibs[@]}"
  built_archives+=("${slice_dir}/libtether_fd.a")
done

mkdir -p "${BUILD_DIR}/universal"
if [ "${#built_archives[@]}" -gt 1 ]; then
  lipo -create "${built_archives[@]}" -output "${BUILD_DIR}/universal/libtether_fd.a"
else
  cp "${built_archives[0]}" "${BUILD_DIR}/universal/libtether_fd.a"
fi

echo "Done: ${BUILD_DIR}/universal/libtether_fd.a"
