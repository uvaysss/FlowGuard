#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="${ROOT_DIR}/scripts/core-stability-check.sh"

if [ ! -x "${CHECK_SCRIPT}" ]; then
  echo "Missing executable ${CHECK_SCRIPT}. Run: chmod +x scripts/core-stability-check.sh" >&2
  exit 2
fi

REPEAT="${REPEAT:-3}"
MODES="${MODES:-legacyTunFD,packetFlowPreferred}"

IFS=',' read -r -a MODE_ARRAY <<< "${MODES}"

echo "Runtime A/B smoke"
echo "REPEAT=${REPEAT}"
echo "MODES=${MODES}"
echo

results=()

for raw_mode in "${MODE_ARRAY[@]}"; do
  mode="$(printf '%s' "${raw_mode}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "${mode}" ]; then
    continue
  fi

  echo "[mode=${mode}] starting"
  start_ts="$(date +%s)"

  if FLOWGUARD_TUNNEL_IMPLEMENTATION_MODE="${mode}" REPEAT="${REPEAT}" "${CHECK_SCRIPT}"; then
    status="PASS"
  else
    status="FAIL"
  fi

  end_ts="$(date +%s)"
  elapsed="$((end_ts - start_ts))"

  echo "[mode=${mode}] status=${status} elapsed_sec=${elapsed}"
  echo
  results+=("${mode}|${status}|${elapsed}")
done

echo "A/B summary"
printf "%-22s %-8s %s\n" "mode" "status" "elapsed_sec"
printf "%-22s %-8s %s\n" "----------------------" "------" "----------"

all_pass=true
for row in "${results[@]}"; do
  IFS='|' read -r mode status elapsed <<< "${row}"
  printf "%-22s %-8s %s\n" "${mode}" "${status}" "${elapsed}"
  if [ "${status}" != "PASS" ]; then
    all_pass=false
  fi
done

if [ "${all_pass}" = true ]; then
  echo "Overall: PASS"
  exit 0
fi

echo "Overall: FAIL"
exit 1
