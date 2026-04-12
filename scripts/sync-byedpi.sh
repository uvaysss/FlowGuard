#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/byedpi"
PIN_FILE="${ROOT_DIR}/Vendor/byedpi.version"

REPO_URL="${1:-https://github.com/hufrea/byedpi.git}"
REF="${2:-main}"

mkdir -p "${ROOT_DIR}/Vendor"

if [[ -d "${VENDOR_DIR}/.git" ]]; then
  git -C "${VENDOR_DIR}" fetch --tags origin
  git -C "${VENDOR_DIR}" checkout "${REF}"
  git -C "${VENDOR_DIR}" pull --ff-only origin "${REF}" || true
else
  git clone "${REPO_URL}" "${VENDOR_DIR}"
  git -C "${VENDOR_DIR}" checkout "${REF}"
fi

git -C "${VENDOR_DIR}" rev-parse HEAD > "${PIN_FILE}"
echo "Pinned byedpi at $(cat "${PIN_FILE}")"

"${ROOT_DIR}/scripts/vendor/patch-byedpi-flowguard-stop.sh"
