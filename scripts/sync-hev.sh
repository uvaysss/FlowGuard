#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/hev-socks5-tunnel"
PIN_FILE="${ROOT_DIR}/Vendor/hev-socks5-tunnel.version"

REPO_URL="${1:-https://github.com/heiher/hev-socks5-tunnel.git}"
REF="${2:-main}"

mkdir -p "${ROOT_DIR}/Vendor"

if [[ -d "${VENDOR_DIR}/.git" ]]; then
  git -C "${VENDOR_DIR}" fetch --tags origin
  git -C "${VENDOR_DIR}" checkout "${REF}"
  git -C "${VENDOR_DIR}" pull --ff-only origin "${REF}" || true
  git -C "${VENDOR_DIR}" submodule update --init --recursive
else
  git clone --recursive "${REPO_URL}" "${VENDOR_DIR}"
  git -C "${VENDOR_DIR}" checkout "${REF}"
  git -C "${VENDOR_DIR}" submodule update --init --recursive
fi

git -C "${VENDOR_DIR}" rev-parse HEAD > "${PIN_FILE}"
echo "Pinned hev-socks5-tunnel at $(cat "${PIN_FILE}")"
