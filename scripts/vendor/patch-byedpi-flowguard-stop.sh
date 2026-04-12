#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BYEDPI_DIR="${ROOT_DIR}/Vendor/byedpi"
TARGET_FILE="${BYEDPI_DIR}/proxy.c"

if [[ ! -f "${TARGET_FILE}" ]]; then
  echo "Missing ${TARGET_FILE}"
  exit 1
fi

if rg -n "flowguard_byedpi_stop" "${TARGET_FILE}" >/dev/null; then
  echo "flowguard_byedpi_stop already present in proxy.c"
  exit 0
fi

cat >> "${TARGET_FILE}" <<'PATCH_EOF'

void flowguard_byedpi_stop(void)
{
    if (server_fd > 0) {
        shutdown(server_fd, SHUT_RDWR);
        close(server_fd);
        server_fd = -1;
    }
}
PATCH_EOF

echo "Applied FlowGuard stop shim patch to ${TARGET_FILE}"
