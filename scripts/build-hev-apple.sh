#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/hev-socks5-tunnel"
OUT_DIR="${ROOT_DIR}/VendorArtifacts/hev-socks5-tunnel"

mkdir -p "${OUT_DIR}"

if [[ ! -d "${VENDOR_DIR}" ]]; then
  echo "Missing ${VENDOR_DIR}"
  echo "Clone https://github.com/heiher/hev-socks5-tunnel into Vendor/hev-socks5-tunnel first."
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

echo "Building hev-socks5-tunnel Apple artifact"
echo "Source: ${VENDOR_DIR}"
echo "Output: ${OUT_DIR}"

if [[ -x "${VENDOR_DIR}/build-apple.sh" ]]; then
  echo "Running upstream build-apple.sh"
  (
    cd "${VENDOR_DIR}"
    ./build-apple.sh
  )
elif [[ -x "${VENDOR_DIR}/scripts/build-apple.sh" ]]; then
  echo "Running upstream scripts/build-apple.sh"
  (
    cd "${VENDOR_DIR}"
    ./scripts/build-apple.sh
  )
else
  echo "Could not find upstream Apple build script in ${VENDOR_DIR}."
  echo "Expected one of:"
  echo "  - ${VENDOR_DIR}/build-apple.sh"
  echo "  - ${VENDOR_DIR}/scripts/build-apple.sh"
  exit 1
fi

if [[ -d "${VENDOR_DIR}/build/HevSocks5Tunnel.xcframework" ]]; then
  rm -rf "${OUT_DIR}/HevSocks5Tunnel.xcframework"
  cp -R "${VENDOR_DIR}/build/HevSocks5Tunnel.xcframework" "${OUT_DIR}/HevSocks5Tunnel.xcframework"
  echo "Copied XCFramework to ${OUT_DIR}/HevSocks5Tunnel.xcframework"
elif [[ -d "${VENDOR_DIR}/HevSocks5Tunnel.xcframework" ]]; then
  rm -rf "${OUT_DIR}/HevSocks5Tunnel.xcframework"
  cp -R "${VENDOR_DIR}/HevSocks5Tunnel.xcframework" "${OUT_DIR}/HevSocks5Tunnel.xcframework"
  echo "Copied XCFramework to ${OUT_DIR}/HevSocks5Tunnel.xcframework"
else
  echo "Build completed, but HevSocks5Tunnel.xcframework was not found under ${VENDOR_DIR}/build or ${VENDOR_DIR}."
  exit 1
fi
