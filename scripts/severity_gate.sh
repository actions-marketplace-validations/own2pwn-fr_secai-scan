#!/usr/bin/env bash
# Fail the action if any finding meets or exceeds the configured
# severity threshold. Runs *after* SARIF export so a soft-fail still
# gets uploaded to Code Scanning.
#
# Required env: SECAI_API_BASE, SECAI_API_KEY, SECAI_ACTION_SCAN_ID,
#               SECAI_ACTION_FAIL_ON_SEVERITY (critical|high|medium|low).

set -euo pipefail

: "${SECAI_API_BASE:?missing SECAI_API_BASE}"
: "${SECAI_API_KEY:?missing SECAI_API_KEY}"
: "${SECAI_ACTION_SCAN_ID:?missing SECAI_ACTION_SCAN_ID}"
: "${SECAI_ACTION_FAIL_ON_SEVERITY:?missing SECAI_ACTION_FAIL_ON_SEVERITY}"

threshold=$(echo "${SECAI_ACTION_FAIL_ON_SEVERITY}" | tr '[:upper:]' '[:lower:]')
if [[ "${threshold}" == "none" ]]; then
  echo "fail-on-severity=none — gate disabled."
  exit 0
fi

findings=$(curl --fail --silent --show-error \
  -H "Authorization: Bearer ${SECAI_API_KEY}" \
  -H "Accept: application/json" \
  "${SECAI_API_BASE%/}/scans/${SECAI_ACTION_SCAN_ID}/findings?min_severity=${threshold}&limit=500&offset=0")

count=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"${findings}")

if [[ "${count}" -gt 0 ]]; then
  echo "::error::SecAI gate: ${count} finding(s) at severity >= ${threshold}"
  exit 1
fi
echo "SecAI gate passed — no findings at severity >= ${threshold}."
