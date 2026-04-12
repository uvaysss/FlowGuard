#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/byedpi"
OUT_DIR="${ROOT_DIR}/VendorArtifacts/byedpi"

mkdir -p "${OUT_DIR}"

if [[ ! -d "${VENDOR_DIR}" ]]; then
  echo "Missing ${VENDOR_DIR}"
  echo "Clone https://github.com/hufrea/byedpi into Vendor/byedpi first."
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

SOURCES=(
  packets.c
  main.c
  conev.c
  proxy.c
  desync.c
  mpool.c
  extend.c
)

build_sdk() {
  local sdk="$1"
  local min_version_flag="$2"
  local archs=("${@:3}")
  local build_dir="${OUT_DIR}/${sdk}"

  rm -rf "${build_dir}"
  mkdir -p "${build_dir}/obj"

  for source in "${SOURCES[@]}"; do
    for arch in "${archs[@]}"; do
      local obj_name="${source%.c}-${arch}.o"
      xcrun --sdk "${sdk}" clang \
        -arch "${arch}" \
        "${min_version_flag}" \
        -fPIC \
        -O2 \
        -Dmain=ciadpi_main \
        -I"${VENDOR_DIR}" \
        -c "${VENDOR_DIR}/${source}" \
        -o "${build_dir}/obj/${obj_name}"
    done
  done

  xcrun --sdk "${sdk}" libtool -static "${build_dir}/obj"/*.o -o "${build_dir}/libbyedpi.a"
  cp "${VENDOR_DIR}"/*.h "${build_dir}/" 2>/dev/null || true
}

build_sdk iphoneos "-miphoneos-version-min=16.0" arm64
build_sdk iphonesimulator "-mios-simulator-version-min=16.0" arm64 x86_64

echo "Built ByeDPI static libraries:"
echo "  ${OUT_DIR}/iphoneos/libbyedpi.a"
echo "  ${OUT_DIR}/iphonesimulator/libbyedpi.a"
echo "Compile flag used: -Dmain=ciadpi_main"
