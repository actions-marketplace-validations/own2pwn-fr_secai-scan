#!/usr/bin/env bash
# Queue a SecAI scan and (optionally) wait for it to finish.
#
# Required env: SECAI_API_BASE, SECAI_API_KEY, SECAI_ACTION_REPOSITORY_ID,
#               SECAI_ACTION_KINDS, SECAI_ACTION_WAIT,
#               SECAI_ACTION_TIMEOUT_MINUTES.
# Emits: scan-id, status, findings-count to $GITHUB_OUTPUT.
#
# We deliberately *do not* pass --fail-on-severity to the CLI here:
# the action's severity gate runs as a separate composite step so the
# SARIF export still uploads on a "soft fail" run (export step keys on
# status=succeeded, not on whether the gate trips).

set -euo pipefail

: "${SECAI_API_BASE:?missing SECAI_API_BASE}"
: "${SECAI_API_KEY:?missing SECAI_API_KEY}"
: "${SECAI_ACTION_REPOSITORY_ID:?missing SECAI_ACTION_REPOSITORY_ID}"
: "${SECAI_ACTION_KINDS:?missing SECAI_ACTION_KINDS}"

WAIT_FLAG="--no-wait"
if [[ "${SECAI_ACTION_WAIT:-true}" == "true" ]]; then
  WAIT_FLAG="--wait"
fi

# Convert comma-separated `kinds` to repeated --kind flags so the CLI
# can validate each value against its Choice set.
kind_args=()
IFS=',' read -r -a kinds_arr <<< "${SECAI_ACTION_KINDS}"
for k in "${kinds_arr[@]}"; do
  k_trimmed=$(echo "$k" | tr -d '[:space:]')
  if [[ -n "${k_trimmed}" ]]; then
    kind_args+=("--kind" "${k_trimmed}")
  fi
done

timeout_seconds=$(( ${SECAI_ACTION_TIMEOUT_MINUTES:-30} * 60 ))

echo "Queueing SecAI scan against repository ${SECAI_ACTION_REPOSITORY_ID}…"
# `--json` makes the CLI emit the final scan payload — easier to parse
# than the human-readable line. On --wait=false the CLI still exits 0
# after the POST and prints the queued scan.
set +e
scan_json=$(secai scan create \
  --repo "${SECAI_ACTION_REPOSITORY_ID}" \
  "${kind_args[@]}" \
  ${WAIT_FLAG} \
  --timeout "${timeout_seconds}" \
  --json 2>scan_stderr.log)
rc=$?
set -e
cat scan_stderr.log >&2 || true

if [[ ${rc} -ne 0 && "${SECAI_ACTION_WAIT}" != "true" ]]; then
  echo "secai scan create failed (rc=${rc})" >&2
  exit ${rc}
fi

# Extract id + status. On wait mode the CLI prints the *terminal* scan
# JSON; on no-wait it prints the just-queued scan with status=queued.
scan_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"${scan_json}")
status=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","unknown"))' <<<"${scan_json}")

echo "scan-id=${scan_id}" >> "$GITHUB_OUTPUT"
echo "status=${status}" >> "$GITHUB_OUTPUT"

# Always tally findings when the scan succeeded — useful for downstream
# steps even when no severity gate is configured.
findings_count=0
if [[ "${status}" == "succeeded" ]]; then
  count_json=$(curl --fail --silent --show-error \
    -H "Authorization: Bearer ${SECAI_API_KEY}" \
    -H "Accept: application/json" \
    "${SECAI_API_BASE%/}/scans/${scan_id}/findings?limit=500&offset=0")
  findings_count=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"${count_json}")
fi
echo "findings-count=${findings_count}" >> "$GITHUB_OUTPUT"

echo "::group::Scan summary"
echo "id=${scan_id}"
echo "status=${status}"
echo "findings-count=${findings_count}"
echo "::endgroup::"

# Propagate the CLI's non-zero exit code from `--wait`: the action's
# severity gate runs in a later step, but a scan that ended in
# `failed` / `cancelled` / `budget_exceeded` should still bail here
# because the export step depends on a clean run.
if [[ ${rc} -ne 0 ]]; then
  echo "scan ended in non-succeeded status — failing the action" >&2
  exit ${rc}
fi
