#!/usr/bin/env bash

set -u
set -o pipefail

PROJECT="${PROJECT:-FlowGuard.xcodeproj}"
SCHEME="${SCHEME:-FlowGuardCoreTests}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.3.1}"
REPEAT="${REPEAT:-20}"
SENSITIVE_TESTS="${SENSITIVE_TESTS:-FlowGuardCoreTests/PacketFlowUDPRelayTests/testUpstreamDatagramCallbackIncrementsRxAndEmitsEvent}"
INFRA_RETRY_MAX="${INFRA_RETRY_MAX:-2}"
INFRA_RETRY_DELAY_SEC="${INFRA_RETRY_DELAY_SEC:-2}"

if ! [ "$REPEAT" -ge 1 ] 2>/dev/null; then
  echo "Invalid REPEAT value: $REPEAT (must be >= 1)" >&2
  exit 2
fi

if ! [ "$INFRA_RETRY_MAX" -ge 0 ] 2>/dev/null; then
  echo "Invalid INFRA_RETRY_MAX value: $INFRA_RETRY_MAX (must be >= 0)" >&2
  exit 2
fi

if ! [ "$INFRA_RETRY_DELAY_SEC" -ge 0 ] 2>/dev/null; then
  echo "Invalid INFRA_RETRY_DELAY_SEC value: $INFRA_RETRY_DELAY_SEC (must be >= 0)" >&2
  exit 2
fi

if command -v rtk >/dev/null 2>&1; then
  XCB=(rtk xcodebuild)
else
  XCB=(xcodebuild)
fi

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/core-stability-check.XXXXXX")"
LAST_LOG="$LOG_DIR/last.log"

stress_total=0
stress_passed=0
stress_failed=0
full_passed=0
infra_retries_used_total=0
infra_retried_invocations=0
stress_infra_retries=0
full_infra_retries=0

RUN_LAST_INFRA_RETRIES=0

is_infra_failure_log() {
  local log_file="$1"
  # Retry only infra/simulator instability, never regular test assertion failures.
  grep -Eiq \
    "Unable to find a destination matching the provided destination specifier|destination .* not available|No matching device|The requested device could not be found|Unable to locate device set|Failed to initialize simulator device set|startObservingSimulatorUpdates\\(\\) FAILED to register SimDeviceSet observer|defaultDeviceSetWithError\\:\\] returned nil|Failed to create promise.*simctl|CoreSimulatorService connection became invalid|Unable to lookup in current state: Shut|Connection to CoreSimulatorService was lost|Connection refused|com\\.apple\\.CoreSimulator\\.SimDiskImageManager|simdiskimaged|DVTCoreDeviceEnabledState_Disabled|xcodebuild: error: Failed to build project .* with scheme .*\\.|Failed to prepare device for development" \
    "$log_file"
}

run_xcodebuild_with_infra_retry() {
  local log_file="$1"
  shift

  local max_attempts=$((INFRA_RETRY_MAX + 1))
  local attempt=1
  RUN_LAST_INFRA_RETRIES=0

  while true; do
    if "${XCB[@]}" "$@" >"$log_file" 2>&1; then
      RUN_LAST_INFRA_RETRIES=$((attempt - 1))
      return 0
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      RUN_LAST_INFRA_RETRIES=$((attempt - 1))
      return 1
    fi

    if ! is_infra_failure_log "$log_file"; then
      RUN_LAST_INFRA_RETRIES=$((attempt - 1))
      return 1
    fi

    infra_retries_used_total=$((infra_retries_used_total + 1))
    RUN_LAST_INFRA_RETRIES=$((attempt - 1))
    attempt=$((attempt + 1))
    sleep "$INFRA_RETRY_DELAY_SEC"
  done
}

echo "Core stability check"
echo "Project: $PROJECT"
echo "Scheme: $SCHEME"
echo "Destination: $DESTINATION"
echo "Repeat per sensitive test: $REPEAT"
echo "Infra retry max: $INFRA_RETRY_MAX"
echo "Infra retry delay (sec): $INFRA_RETRY_DELAY_SEC"
echo

IFS=',' read -r -a TEST_ARRAY <<< "$SENSITIVE_TESTS"

for raw_test in "${TEST_ARRAY[@]}"; do
  test_id="$(printf '%s' "$raw_test" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$test_id" ]; then
    continue
  fi

  echo "[stress] $test_id"
  run=1
  while [ "$run" -le "$REPEAT" ]; do
    stress_total=$((stress_total + 1))
    printf "  - run %d/%d ... " "$run" "$REPEAT"
    if run_xcodebuild_with_infra_retry "$LAST_LOG" -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO test -only-testing:"$test_id" -quiet; then
      stress_passed=$((stress_passed + 1))
      if [ "$RUN_LAST_INFRA_RETRIES" -gt 0 ]; then
        stress_infra_retries=$((stress_infra_retries + RUN_LAST_INFRA_RETRIES))
        infra_retried_invocations=$((infra_retried_invocations + 1))
      fi
      echo "PASS (infra-retries: $RUN_LAST_INFRA_RETRIES)"
    else
      stress_failed=$((stress_failed + 1))
      if [ "$RUN_LAST_INFRA_RETRIES" -gt 0 ]; then
        stress_infra_retries=$((stress_infra_retries + RUN_LAST_INFRA_RETRIES))
        infra_retried_invocations=$((infra_retried_invocations + 1))
      fi
      echo "FAIL (infra-retries: $RUN_LAST_INFRA_RETRIES)"
    fi
    run=$((run + 1))
  done
done

echo
echo "[full-suite] $SCHEME"
if run_xcodebuild_with_infra_retry "$LAST_LOG" -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO test -quiet; then
  full_passed=1
  if [ "$RUN_LAST_INFRA_RETRIES" -gt 0 ]; then
    full_infra_retries=$RUN_LAST_INFRA_RETRIES
    infra_retried_invocations=$((infra_retried_invocations + 1))
  fi
  echo "  - result: PASS (infra-retries: $RUN_LAST_INFRA_RETRIES)"
else
  full_passed=0
  if [ "$RUN_LAST_INFRA_RETRIES" -gt 0 ]; then
    full_infra_retries=$RUN_LAST_INFRA_RETRIES
    infra_retried_invocations=$((infra_retried_invocations + 1))
  fi
  echo "  - result: FAIL (infra-retries: $RUN_LAST_INFRA_RETRIES)"
fi

echo
echo "Summary"
echo "  Stress runs passed: $stress_passed/$stress_total"
echo "  Stress runs failed: $stress_failed/$stress_total"
echo "  Stress infra retries used: $stress_infra_retries"
if [ "$full_passed" -eq 1 ]; then
  echo "  Full suite: PASS"
else
  echo "  Full suite: FAIL"
fi
echo "  Full suite infra retries used: $full_infra_retries"
echo "  Infra retries used (total): $infra_retries_used_total"
echo "  Invocations with infra retry: $infra_retried_invocations"

if [ "$stress_failed" -eq 0 ] && [ "$full_passed" -eq 1 ]; then
  echo "  Overall: PASS"
  rm -rf "$LOG_DIR"
  exit 0
fi

echo "  Overall: FAIL"
echo "  Last xcodebuild log: $LAST_LOG"
exit 1
